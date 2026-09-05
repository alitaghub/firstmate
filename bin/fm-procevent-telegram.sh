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
#            when updates arrive or the channel is broken, so a quiet chat costs
#            no captures at all.
# handle     Validate the captured updates, queue each ACCEPTED one as a captain
#            inbox note, persist the new offset, acknowledge the capture, and
#            re-arm at that offset. Idempotent: a replayed capture writes no
#            second note.
# autohandle The runner's own entry into handle, keyed by canonical source id,
#            so applying a capture never depends on a handler remembering to.
# ingest     The note-writing half of handle on its own, without re-arming or
#            acknowledging. Takes the same channel lock as handle, so running it
#            by hand next to a live runner cannot double-queue a note.
# classify   Print the captured outcome class: updates, error, or malformed.
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
# WHO may send is bin/fm-telegram-lib.sh's fm_telegram_update_verdict, and every
# rejection is recorded on the result rather than silently dropped.
#
# Duplicate suppression. The offset is persisted only AFTER a note is safely on
# disk, because the two crash orders are not equally bad: the other order
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
POLL_WINDOW=${FM_TELEGRAM_POLL_WINDOW:-50}
# Updates per capture. Well under the runner's output bound even at Telegram's
# 4096-character message limit; anything left over arrives on the next poll.
POLL_LIMIT=${FM_TELEGRAM_POLL_LIMIT:-50}
# Consecutive transport failures tolerated before the poll gives up and reports
# a broken channel. A network drop costs nothing because the offset is unchanged.
MAX_TRANSPORT_FAILURES=${FM_TELEGRAM_MAX_TRANSPORT_FAILURES:-5}
TRANSPORT_BACKOFF=${FM_TELEGRAM_TRANSPORT_BACKOFF:-5}

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

mark_seen() { # <update-id> <note-id>
  local path tmp
  mkdir -p "$SEEN_DIR" || return 1
  chmod 700 "$SEEN_DIR" 2>/dev/null || true
  path=$(seen_path "$1")
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$SEEN_DIR/.seen.XXXXXX") || return 1
  printf 'note=%s\n' "$2" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
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

cmd_poll() {
  local offset='' failures=0 response result count payload rc
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
    response=$(fm_telegram_api getUpdates \
      --data-urlencode "offset=$offset" \
      --data-urlencode "timeout=$POLL_WINDOW" \
      --data-urlencode "limit=$POLL_LIMIT" \
      --data-urlencode 'allowed_updates=["message"]' 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      failures=$((failures + 1))
      if [ "$failures" -ge "$MAX_TRANSPORT_FAILURES" ]; then
        emit_result error "$offset" 0 "$(fm_telegram_redact "$response" | tr '\n' ' ')"
        return 0
      fi
      sleep "$TRANSPORT_BACKOFF"
      continue
    fi
    failures=0
    if ! result=$(fm_telegram_api_result "$response" 2>&1); then
      emit_result error "$offset" 0 "$(fm_telegram_redact "$result" | tr '\n' ' ')"
      return 0
    fi
    count=$(printf '%s' "$result" | jq -r 'if type == "array" then length else "invalid" end' 2>/dev/null) || count=invalid
    case "$count" in
      invalid|''|*[!0-9]*) emit_result error "$offset" 0 "telegram returned a result that is not an update list"; return 0 ;;
    esac
    if [ "$count" -eq 0 ]; then
      # An idle window is not news. Open the next one rather than capturing a
      # result whose only content is that nothing happened.
      continue
    fi
    printf '%s' "$result" | jq -c '.' > "$payload" || { emit_result error "$offset" 0 "cannot stage captured updates"; return 0; }
    emit_result updates "$offset" "$count" "$count update(s) captured" "$payload"
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
    updates|error) printf '%s\n' "$status" ;;
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
# captain's own text and nothing else; provenance rides the note's source field.
queue_note() { # <text> -> prints the note id
  local text=$1 output
  output=$(printf '%s' "$text" | FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-inbox.sh" note --source telegram - 2>&1) || {
    printf '%s\n' "$output" >&2
    return 1
  }
  printf '%s\n' "$output" | sed -n 's/^queued //p' | head -n1
}

cmd_ingest() { # <result-file>
  local file=$1 class payload count i update verdict text update_id note_id
  local queued=0 skipped=0 rejected=0 highest=-1 offset
  class=$(classify_result "$file")
  case "$class" in
    malformed) die "Telegram result is malformed" ;;
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
    mark_seen "$update_id" "$note_id" || die "cannot record update $update_id as queued"
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
    # A broken channel is NOT re-armed: re-polling a refused token or a
    # conflicting second poller just burns the same failure in a loop. The
    # capture stays unacknowledged so firstmate is woken to decide.
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
