#!/usr/bin/env bash
# Telegram captain-channel process-event adapter.
#
# Usage:
#   fm-procevent-telegram.sh arm
#   fm-procevent-telegram.sh poll --offset <n>
#   fm-procevent-telegram.sh handle <sequence> <result-file>
#   fm-procevent-telegram.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-telegram.sh ingest <result-file>
#   fm-procevent-telegram.sh classify <result-file>
#   fm-procevent-telegram.sh terminal <result-file>
#   fm-procevent-telegram.sh self-announcing
#   fm-procevent-telegram.sh source-id
#   fm-procevent-telegram.sh retire
#
# arm        Register one blocking getUpdates long poll at the stored offset.
#            The generic runner owns blocking, capture, publication, and one
#            machine-wide owner per source - which is also what keeps two
#            firstmate homes sharing a store from both polling one bot token,
#            a state Telegram answers with 409 Conflict.
# poll       The blocking child the runner executes; never run it directly in a
#            conversational turn. It holds a long poll open and returns only
#            when updates the captain could have sent arrive or the channel is
#            broken, so a quiet chat - and a chat busy only with strangers -
#            costs no captures at all.
# handle     Validate the captured updates, queue each ACCEPTED one as a captain
#            inbox note, persist the new offset, acknowledge the capture, and
#            re-arm at that offset. Idempotent: a replayed capture writes no
#            second note.
# autohandle The runner's own entry into handle, keyed by canonical source id,
#            so applying a capture never depends on a handler remembering to.
# ingest     The note-writing half of handle on its own, without re-arming or
#            acknowledging. Takes the same channel lock as handle, so running it
#            by hand next to a live runner cannot double-queue a note.
# classify   Print the captured outcome class: updates, unreachable, error, or
#            malformed. `unreachable` is a failure that fixes itself - no route,
#            a 429, a 5xx, or a body that is not Bot API JSON - and re-arms;
#            `error` is a channel nothing here can repair - Telegram refusing
#            the call (401, 409), a removed token or allowlist, or a window the
#            poll can never advance past - and stops to ask.
# terminal   Every capture ends its registration; handle re-arms the next one.
# self-announcing
#            Declares that a fully applied capture announces itself downstream:
#            each queued note appends its own `check: captain inbox note <id>`
#            wake, so one Telegram message produces exactly one firstmate wake
#            and a replayed capture that writes no note stays completely silent.
# retire     Drop the registration. Idempotent.
#
# THIS ADAPTER HAS EXACTLY ONE VERB: WRITE A NOTE.
# An inbound message never merges, never answers a held captain decision, never
# spawns, and never runs anything from its own content. It deliberately has no
# `answers` command, so it can never feed the keyed-answer intake that closes a
# captain-held task. What the captain's words MEAN is decided by firstmate,
# which has the backlog, the fleet state, and the surrounding context - the same
# judgment it applies to words typed at the terminal. Putting that judgment in a
# poller would move merge and decision authority into a text-matching script.
#
# WHO may send is bin/fm-telegram-lib.sh's fm_telegram_update_verdict, asked in
# two places for one reason. The poll asks it first and drops an update that is
# refused AND comes from a sender nobody allowlisted, so a message from whoever
# found the bot's public link never becomes a durable capture on the captain's
# disk. Everything that survives that is either his or refusable for its shape,
# and ingest asks again: the refusal is counted in its summary, its raw form
# stays in the capture file, and the sender is told only because he is already
# on the allowlist - answering anyone else would confirm the bot exists to
# whoever probed it.
#
# Duplicate suppression. Every update that was acted on leaves a receipt under
# state/telegram.seen/ - one for a queued note, one for a refusal the bot TRIED
# to answer - and a replay skips any update that already has one. A send that
# fails still leaves the receipt, because retrying a refusal reply on every
# replay is the repeat buzz the receipt exists to stop. A refusal nobody was
# told about writes nothing, so a stranger cannot fill the directory. The offset is
# persisted only AFTER a note is safely on disk, because the two crash orders are not equally bad: the other order
# confirms the message to Telegram, which then drops it, and the captain's
# instruction is gone. So this channel chooses "possibly a duplicate" over
# "possibly lost" and then kills the duplicate - every queued update_id leaves a
# receipt under state/telegram.seen/, and a replay skips an update that has one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

SOURCE_ID=telegram
OFFSET_FILE="$STATE/telegram.offset"
SEEN_DIR="$STATE/telegram.seen"
INGEST_LOCK="$STATE/.telegram-ingest.lock"

# Server-side long-poll window. Telegram returns the moment a message arrives,
# so this bounds an idle window, not the latency of a real message.
POLL_WINDOW=50
# Updates per capture. Well under the runner's output bound even at Telegram's
# 4096-character message limit; anything left over arrives on the next poll.
POLL_LIMIT=50
# Consecutive transport failures tolerated before the poll gives up and reports
# an unreachable channel. A network drop costs nothing because the offset is
# unchanged and the channel re-arms itself. The two multiply out to 35s of
# waiting (the last attempt does not sleep), which outlasts the 30s a Telegram
# 429 states; giving up sooner would re-arm straight back into the same limit.
# The count carries the increase rather than the interval so an ordinary wifi
# blip is still noticed within 5s of the network returning.
MAX_TRANSPORT_FAILURES=8
# The interval alone is overridable so the tests that drive the counter to
# exhaustion do not have to sit through the real wait; the count stays fixed so
# production keeps outlasting the 30s a 429 states.
TRANSPORT_BACKOFF=${FM_TELEGRAM_TRANSPORT_BACKOFF:-5}
# Seconds a refusal reply may spend on its one sendMessage. Stated outright, not
# as a fallback: sourcing bin/fm-telegram-lib.sh has already set
# FM_TELEGRAM_TIMEOUT to the long poll's 70, so a `:-` default would never
# apply. The reply runs serially inside the ingest loop under the channel lock,
# so a slow one delays the captain's next real message from becoming a note.
REPLY_TIMEOUT=10

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

read_offset() {
  local value
  [ -f "$OFFSET_FILE" ] && [ ! -L "$OFFSET_FILE" ] || { printf '0\n'; return 0; }
  value=$(head -n1 "$OFFSET_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$value" in
    ''|*[!0-9]*)
      printf 'error: Telegram offset file is not a number: %s\n' "$OFFSET_FILE" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$value"
}

write_offset() {
  local value=$1 tmp
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  mkdir -p "$STATE" || return 1
  [ ! -L "$OFFSET_FILE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.telegram-offset.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$OFFSET_FILE"
}

seen_path() { printf '%s/%s\n' "$SEEN_DIR" "$1"; }

update_seen() {
  local path
  path=$(seen_path "$1")
  [ -f "$path" ] && [ ! -L "$path" ]
}

mark_seen() { # <update-id> <what-happened>
  local path tmp
  mkdir -p "$SEEN_DIR" || return 1
  chmod 700 "$SEEN_DIR" 2>/dev/null || true
  path=$(seen_path "$1")
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$SEEN_DIR/.seen.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# The sender half of the verdict, asked on its own. One allowlist decides who
# the captain is, so both callers ask it the same way: the poll keeps an update
# from an unknown sender out of the capture entirely, and ingest answers a
# refusal only when the sender is him.
update_sender_allowed() { # <update>
  local from_id
  from_id=$(printf '%s' "$1" | jq -r '
    if (.message.from.id | type) == "number" then (.message.from.id | tostring) else "" end' 2>/dev/null) || return 1
  fm_telegram_id_allowed "$from_id"
}

# ---------------------------------------------------------------- poll

emit_result() { # <status> <offset> <count> <detail> [payload-file]
  printf 'telegram: %s\n' "$SOURCE_ID"
  printf 'status: %s\n' "$1"
  printf 'offset: %s\n' "$2"
  printf 'count: %s\n' "$3"
  printf 'detail: %s\n' "$4"
  printf '\n'
  if [ -n "${5-}" ] && [ -f "$5" ]; then
    cat "$5"
  else
    printf '[]\n'
  fi
}

# Keep only what is worth a durable capture. An update the verdict refuses AND
# whose sender is not on the allowlist is dropped here, before the runner writes
# anything: the bot's link opens for anybody, so a stranger's message must cost
# no file at all. A refusal for the message's SHAPE from the captain himself is
# legitimate traffic and stays, because he is owed the reply that says why.
keep_worth_capturing() { # <updates-json> -> the surviving updates as a JSON array
  local updates=$1 total i update verdict kept=
  total=$(printf '%s' "$updates" | jq -r 'length') || return 1
  i=0
  while [ "$i" -lt "$total" ]; do
    update=$(printf '%s' "$updates" | jq -c ".[$i]") || return 1
    i=$((i + 1))
    verdict=$(fm_telegram_update_verdict "$update")
    if [ "$verdict" != accept ] && ! update_sender_allowed "$update"; then
      continue
    fi
    kept="$kept$update
"
  done
  printf '%s' "$kept" | jq -sc '.'
}

cmd_poll() {
  local offset='' failures=0 response result count payload rc transient detail
  local kept kept_count batch_high
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --offset) [ "$#" -ge 2 ] || die "--offset needs a nonnegative integer"; offset=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$offset" in ''|*[!0-9]*) die "--offset needs a nonnegative integer" ;; esac

  payload=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-payload.XXXXXX") || die "cannot stage the poll payload"
  # shellcheck disable=SC2064 # expand the path now, while it is known.
  trap "rm -f -- '$payload'" EXIT

  while :; do
    # Re-read configuration every window so removing the token or the allowlist
    # takes effect within one poll rather than only at the next arm. That is the
    # captain's fastest local kill switch and it has to actually stop the poll.
    if ! fm_telegram_load_config; then
      emit_result error "$offset" 0 "$FM_TELEGRAM_ERROR"
      return 0
    fi
    rc=0
    transient=0
    detail=
    response=$(fm_telegram_api getUpdates \
      --data-urlencode "offset=$offset" \
      --data-urlencode "timeout=$POLL_WINDOW" \
      --data-urlencode "limit=$POLL_LIMIT" \
      --data-urlencode 'allowed_updates=["message"]' 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      transient=1
      detail=$(fm_telegram_redact "$response" | tr '\n' ' ')
    elif ! result=$(fm_telegram_api_result "$response" 2>&1); then
      detail=$(fm_telegram_redact "$result" | tr '\n' ' ')
      fm_telegram_failure_is_transient "$response" && transient=1
      if [ "$transient" -eq 0 ]; then
        emit_result error "$offset" 0 "$detail"
        return 0
      fi
    fi
    if [ "$transient" -eq 1 ]; then
      # Every failure that fixes itself waits here on the one counter and the
      # one backoff: no route, a 429, a 5xx, an edge gateway page. Emitting on
      # the first 429 instead would hand the registration straight back to the
      # runner, which re-polls within seconds and extends the rate limit that
      # asked us to wait.
      failures=$((failures + 1))
      if [ "$failures" -ge "$MAX_TRANSPORT_FAILURES" ]; then
        emit_result unreachable "$offset" 0 "$detail"
        return 0
      fi
      sleep "$TRANSPORT_BACKOFF"
      continue
    fi
    # NOT reset here. A request that succeeded is not the same as a poll that
    # got somewhere: an unadvanceable window is a successful transport carrying
    # nothing usable, and resetting on the request would let it repeat forever.
    # Progress means the poll moved forward - an idle window that confirms we
    # are up to date, a window whose offset advanced, or a batch we captured.
    count=$(printf '%s' "$result" | jq -r 'if type == "array" then length else "invalid" end' 2>/dev/null) || count=invalid
    case "$count" in
      invalid|''|*[!0-9]*) emit_result error "$offset" 0 "telegram returned a result that is not an update list"; return 0 ;;
    esac
    if [ "$count" -eq 0 ]; then
      # An idle window is not news. Open the next one rather than capturing a
      # result whose only content is that nothing happened. It IS progress: the
      # channel answered and we are up to date, so the budget resets.
      failures=0
      continue
    fi
    kept=$(keep_worth_capturing "$result") || { emit_result error "$offset" 0 "cannot read the captured updates"; return 0; }
    kept_count=$(printf '%s' "$kept" | jq -r 'length' 2>/dev/null) || kept_count=invalid
    case "$kept_count" in
      invalid|''|*[!0-9]*) emit_result error "$offset" 0 "cannot read the captured updates"; return 0 ;;
    esac
    if [ "$kept_count" -eq 0 ]; then
      # Nothing here is ours. Move the read position past the window in memory
      # and open the next one: without that step the very next getUpdates asks
      # for the same window again and the poll spins on it. Nothing is written
      # to disk, so a replay after a crash simply drops the same updates again.
      batch_high=$(printf '%s' "$result" | jq -r '
        [.[] | select((.update_id | type) == "number") | .update_id] | max // empty' 2>/dev/null) || batch_high=
      case "$batch_high" in
        ''|*[!0-9]*)
          # No id to advance past, so the next window is the same window.
          # Inventing an offset here would confirm updates nobody read, so this
          # waits instead, on the SAME counter and backoff as every other
          # repeating failure. What it gives up INTO is `error`, not
          # `unreachable`: a window that keeps coming back unusable does not fix
          # itself, and `unreachable` re-arms and acknowledges silently, which
          # would only move the loop from inside this process to across
          # processes. `error` stops without re-arming and reaches firstmate,
          # the same path a refused token or a second reader takes.
          failures=$((failures + 1))
          if [ "$failures" -ge "$MAX_TRANSPORT_FAILURES" ]; then
            emit_result error "$offset" 0 "telegram returned a window this poll cannot advance past"
            return 0
          fi
          sleep "$TRANSPORT_BACKOFF"
          ;;
        *)
          # The offset moved, so the poll got somewhere.
          offset=$((batch_high + 1))
          failures=0
          ;;
      esac
      continue
    fi
    printf '%s' "$kept" | jq -c '.' > "$payload" || { emit_result error "$offset" 0 "cannot stage captured updates"; return 0; }
    emit_result updates "$offset" "$kept_count" "$kept_count update(s) captured" "$payload"
    return 0
  done
}

# ---------------------------------------------------------------- classify

result_header_field() { # <result-file> <field>
  LC_ALL=C awk -v prefix="$2: " '
    $0 == "" { exit }
    index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
    END { if (count != 1) exit 1; print value }
  ' "$1"
}

result_payload() { # <result-file>
  local blank
  blank=$(LC_ALL=C awk '$0 == "" { print NR; exit }' "$1")
  case "$blank" in ''|*[!0-9]*) return 1 ;; esac
  tail -n "+$((blank + 1))" "$1"
}

classify_result() {
  local file=$1 source status
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'malformed\n'; return 0; }
  source=$(result_header_field "$file" telegram 2>/dev/null || true)
  status=$(result_header_field "$file" status 2>/dev/null || true)
  [ "$source" = "$SOURCE_ID" ] || { printf 'malformed\n'; return 0; }
  case "$status" in
    updates|unreachable|error) printf '%s\n' "$status" ;;
    *) printf 'malformed\n' ;;
  esac
}

# ---------------------------------------------------------------- arm

cmd_arm() {
  local offset
  fm_telegram_load_config || die "$FM_TELEGRAM_ERROR"
  # A bad offset must refuse here. Arming with an empty one registers a poll
  # that dies on every start, so the runner restarts a source that can never
  # capture anything while the operator was told the channel is armed.
  offset=$(read_offset) || return 1
  "$SCRIPT_DIR/fm-procevent.sh" register telegram "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-telegram.sh" poll --offset "$offset" || return 1
  printf 'armed: %s offset=%s\n' "$SOURCE_ID" "$offset"
}

# ---------------------------------------------------------------- handle

# Queue one accepted update as a captain inbox note. The note body is the
# captain's own text and nothing else, queued through the ordinary note surface,
# so it reads exactly like one he typed at the terminal - which is what it is.
queue_note() { # <text> -> prints the note id
  local text=$1 output
  output=$(printf '%s' "$text" | FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-inbox.sh" note - 2>&1) || {
    printf '%s\n' "$output" >&2
    return 1
  }
  printf '%s\n' "$output" | sed -n 's/^queued //p' | head -n1
}

refusal_sentence() { # <reason>
  case "$1" in
    forwarded) printf 'That was a forwarded message, so I did not read it - the words are somebody else%ss. Retype it and I will pick it up.' "'" ;;
    via-bot) printf 'That came through another bot, so I did not read it. Send it to me directly and I will pick it up.' ;;
    no-text) printf 'That message had no text, so there was nothing for me to read.' ;;
    *) printf 'I did not read that message (%s), so it is waiting on nothing.' "$1" ;;
  esac
}

# Tell the captain his message was refused - and ONLY the captain. The reply
# goes out only when message.from.id is already on the allowlist, because a bot
# that answers an unknown sender confirms it exists and turns the check into a
# probe amplifier. An update with no sender, or one nobody can parse, is not
# allowlisted and gets total silence. The reply is always addressed to the
# allowlisted chat `notify` resolves, never to the chat the refused message
# arrived on, so a refusal in a group cannot make the bot post into that group.
# Every failure is swallowed: a reply that cannot be sent must not stop ingest.
tell_the_captain_it_was_refused() { # <update> <reason> -> 0 when a reply was sent
  local update=$1 reason=$2
  update_sender_allowed "$update" || return 1
  refusal_sentence "$reason" | FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_TELEGRAM_TIMEOUT="$REPLY_TIMEOUT" \
    "$SCRIPT_DIR/fm-telegram.sh" notify - >/dev/null 2>&1 || true
  return 0
}

cmd_ingest() { # <result-file>
  local file=$1 class payload count i update verdict text update_id note_id
  local queued=0 skipped=0 rejected=0 highest=-1 offset
  class=$(classify_result "$file")
  case "$class" in
    malformed) die "Telegram result is malformed" ;;
    unreachable) printf 'unreachable: %s\n' "$(result_header_field "$file" detail 2>/dev/null || printf 'unknown')"; return 0 ;;
    error) printf 'error: %s\n' "$(result_header_field "$file" detail 2>/dev/null || printf 'unknown')"; return 3 ;;
  esac
  payload=$(result_payload "$file") || die "Telegram result has no payload boundary"
  count=$(printf '%s' "$payload" | jq -r 'if type == "array" then length else "invalid" end' 2>/dev/null) || count=invalid
  case "$count" in
    invalid|''|*[!0-9]*) die "Telegram result payload is not an update list" ;;
  esac

  fm_telegram_load_config || die "$FM_TELEGRAM_ERROR"

  i=0
  while [ "$i" -lt "$count" ]; do
    update=$(printf '%s' "$payload" | jq -c ".[$i]") || die "cannot read captured update $i"
    i=$((i + 1))
    update_id=$(printf '%s' "$update" | jq -r 'if (.update_id | type) == "number" then (.update_id | tostring) else "" end' 2>/dev/null) || update_id=
    case "$update_id" in ''|*[!0-9]*) rejected=$((rejected + 1)); continue ;; esac
    [ "$update_id" -le "$highest" ] || highest=$update_id

    verdict=$(fm_telegram_update_verdict "$update")
    if [ "$verdict" != accept ]; then
      # Named, counted, and never queued. A rejection is the channel working.
      printf 'rejected: update %s %s\n' "$update_id" "${verdict#reject:}"
      rejected=$((rejected + 1))
      update_seen "$update_id" && continue
      # The receipt exists to stop a replay repeating a buzz, so only a refusal
      # the bot tried to answer earns one. A stranger is answered with nothing,
      # so a receipt for him would suppress a reply that was never coming and
      # let anyone who found the bot leave a file per message here.
      if tell_the_captain_it_was_refused "$update" "${verdict#reject:}"; then
        mark_seen "$update_id" "refused=${verdict#reject:}" \
          || die "cannot record update $update_id as refused"
      fi
      continue
    fi
    if update_seen "$update_id"; then
      skipped=$((skipped + 1))
      continue
    fi
    text=$(printf '%s' "$update" | jq -r '.message.text')
    note_id=$(queue_note "$text") || die "cannot queue the captain note for update $update_id"
    [ -n "$note_id" ] || die "the captain note for update $update_id has no id"
    # The receipt lands AFTER the note is published, so the worst crash window
    # costs a duplicate note rather than a lost instruction.
    mark_seen "$update_id" "note=$note_id" || die "cannot record update $update_id as queued"
    queued=$((queued + 1))
  done

  if [ "$highest" -ge 0 ]; then
    offset=$((highest + 1))
    write_offset "$offset" || die "cannot persist the Telegram offset"
  fi
  printf 'ingested: queued=%s skipped=%s rejected=%s\n' "$queued" "$skipped" "$rejected"
}

cmd_handle_locked() { # <sequence> <result-file>
  local seq=$1 file=$2 class rc=0
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file is unavailable or unsafe: $file"
  class=$(classify_result "$file")
  [ "$class" != malformed ] || die "Telegram result is malformed"
  cmd_ingest "$file" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || return "$rc"
  if [ "$rc" -eq 0 ]; then
    # A channel Telegram REFUSED is not re-armed: re-polling a rejected token or
    # a conflicting second poller just burns the same failure in a loop, so the
    # capture stays unacknowledged and firstmate is woken to decide. A channel
    # that was merely unreachable takes this path instead and keeps listening.
    cmd_arm >/dev/null || return 1
    "$SCRIPT_DIR/fm-procevent.sh" handled "$SOURCE_ID" "$seq" >/dev/null || return 1
  fi
  return "$rc"
}

# Every entry that queues notes, writes seen receipts, or moves the offset runs
# under one channel lock, so two concurrent runs over the same capture cannot
# both find no receipt and queue the captain's message twice.
with_ingest_lock() { # <command> [args...]
  (
    mkdir -p "$STATE" || die "cannot create the state directory"
    fm_lock_acquire_wait "$INGEST_LOCK" || die "cannot lock the Telegram channel"
    trap 'fm_lock_release "$INGEST_LOCK"' EXIT
    "$@"
  )
}

cmd_handle() {
  local seq=${1:-} file=${2:-}
  with_ingest_lock cmd_handle_locked "$seq" "$file"
}

cmd_autohandle() { # <source-id> <sequence> <result-file>
  local sid=${1:-} seq=${2:-} file=${3:-}
  [ "$sid" = "$SOURCE_ID" ] || die "not a Telegram source: $sid"
  cmd_handle "$seq" "$file"
}

cmd_retire() {
  "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID"
}

case "${1-}" in
  arm)             shift; [ "$#" -eq 0 ] || usage; cmd_arm ;;
  poll)            shift; cmd_poll "$@" ;;
  handle)          shift; [ "$#" -eq 2 ] || usage; cmd_handle "$@" ;;
  autohandle)      shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  ingest)          shift; [ "$#" -eq 1 ] || usage; with_ingest_lock cmd_ingest "$@" ;;
  classify)        shift; [ "$#" -eq 1 ] || usage; classify_result "$1" ;;
  terminal)        shift; [ "$#" -eq 1 ] || usage; [ -s "$1" ] ;;
  self-announcing) shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  source-id)       shift; [ "$#" -eq 0 ] || usage; printf '%s\n' "$SOURCE_ID" ;;
  retire)          shift; [ "$#" -eq 0 ] || usage; cmd_retire ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
