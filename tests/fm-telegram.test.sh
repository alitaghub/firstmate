#!/usr/bin/env bash
# Behavioral regressions for the Telegram captain channel.
#
# The allowlist is the whole safety argument for having this channel at all: a
# Telegram bot is reachable by anyone who finds its name, so anything that is
# not the captain's own typed word in his own chat must be refused. That is why
# the reject cases below outnumber the accept case, and why each one is written
# so that deleting the single check it covers turns it red.
#
# Everything here runs against committed fixture updates. No Telegram resource
# is created, configured, or called.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
CLI="$ROOT/bin/fm-telegram.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram)

# EVERY case here runs against a curl that never leaves this machine. Most
# install their own shim; this is the backstop for the ones that exercise the
# real transport, and for any future case that forgets a shim. 127.0.0.1:1
# refuses instantly, so a request that escapes a shim dies locally instead of
# reaching api.telegram.org with a fake token in its URL.
FM_TELEGRAM_API_BASE='http://127.0.0.1:1'
export FM_TELEGRAM_API_BASE

CAPTAIN_ID=987654321
STRANGER_ID=111222333
# Valid in shape, worthless in fact: no call is ever made with it.
FAKE_TOKEN='123456789:AAFakeTokenForTestsOnly_not-real'

# new_home [allowlist-body] -> path to a configured firstmate home
new_home() {
  local home allow=${1-}
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$home/state" "$home/config"
  printf 'FM_TELEGRAM_TOKEN=%s\n' "$FAKE_TOKEN" > "$home/.env"
  if [ -n "$allow" ]; then
    printf '%s\n' "$allow" > "$home/config/telegram-allow"
  else
    printf '%s   # the captain\n' "$CAPTAIN_ID" > "$home/config/telegram-allow"
  fi
  printf '%s\n' "$home"
}

# capture <home> <updates-json> -> path to a captured result document
capture() {
  local home=$1 updates=$2 file count
  file="$home/capture.$RANDOM.result"
  count=$(printf '%s' "$updates" | jq -r 'length')
  {
    printf 'telegram: telegram\n'
    printf 'status: updates\n'
    printf 'offset: 0\n'
    printf 'count: %s\n' "$count"
    printf 'detail: %s update(s) captured\n' "$count"
    printf '\n'
    printf '%s\n' "$updates"
  } > "$file"
  printf '%s\n' "$file"
}

ingest() { # <home> <result-file>; prints combined output, never fails the test
  local home=$1 file=$2
  FM_HOME="$home" "$ADAPTER" ingest "$file" 2>&1
}

note_count() { find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '; }

note_bodies() {
  local f
  for f in "$1"/state/inbox/*.note; do
    [ -f "$f" ] || continue
    sed -n '/^--$/,$p' "$f" | tail -n +2
  done
}

# A plain private message from the captain: the one shape that is accepted.
captain_message() { # [text]
  jq -cn --argjson uid "$CAPTAIN_ID" --arg text "${1:-merge the telegram PR when it is green}" '
    [{ update_id: 700, message: {
         message_id: 12, date: 1757000000,
         from: { id: $uid, is_bot: false, first_name: "Captain" },
         chat: { id: $uid, type: "private" },
         text: $text } }]'
}

# one_update <jq-program> builds a single-update list from the captain message
# with an edit applied, so every reject fixture differs from the accepted one in
# exactly the property under test.
one_update() {
  captain_message | jq -c "$1"
}

# --- accept -----------------------------------------------------------------

test_captain_message_becomes_one_note() {
  local home out
  home=$(new_home)
  out=$(ingest "$home" "$(capture "$home" "$(captain_message)")")

  assert_contains "$out" 'queued=1' "the captain's own private message was not queued"
  [ "$(note_count "$home")" = 1 ] || fail "expected exactly one captain note, found $(note_count "$home")"
  assert_contains "$(note_bodies "$home")" 'merge the telegram PR when it is green' \
    "the queued note does not carry the captain's words"
  # The message is queued and nothing else happens: no wake beyond the note's
  # own, and no merge, decision, or spawn is reachable from this path at all.
  [ "$(grep -c . "$home/state/.wake-queue" 2>/dev/null || echo 0)" = 1 ] \
    || fail "one Telegram message must produce exactly one wake"
  # The offset moves past the update so Telegram stops resending it.
  assert_grep '701' "$home/state/telegram.offset" "the offset did not advance past the handled update"
  pass "an allowlisted private message from the captain becomes exactly one queued note"
}

test_adapter_has_no_authority_beyond_the_note() {
  # The design's central boundary: this adapter must not be able to answer a
  # held captain decision. The runner feeds keyed answers to the captain-hold
  # intake only through an adapter's `answers` command, so not having one is
  # what makes that structurally impossible rather than merely unused.
  local out rc=0
  out=$(FM_HOME="$TMP_ROOT" "$ADAPTER" answers /dev/null 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the Telegram adapter exposes an answers command and can close captain decisions"
  assert_contains "$out" 'unknown command' "answers failed for some reason other than not existing"
  pass "the Telegram adapter cannot feed the captain-answer intake"
}

# --- reject -----------------------------------------------------------------

# assert_rejected <label> <updates-json> <reason> <why-it-matters>
#
# Refusing is only half the behaviour; the other half is what goes back out. A
# refused message from the captain earns one reply, and it must go to HIS chat -
# never to the chat the message arrived on, or a refusal in a group would make
# the bot post there. A refused message from anyone else earns total silence.
# Both are asserted against a curl that records every call it is handed, so each
# case proves a positive fact rather than only that nothing was queued.
assert_rejected() {
  local label=$1 updates=$2 reason=$3 why=$4 home fakebin out sender calls
  home=$(new_home)
  fakebin=$(recording_curl "$home")
  export FM_TELEGRAM_TEST_OUTBOUND="$home/outbound.log"
  out=$(PATH="$fakebin:$PATH" ingest "$home" "$(capture "$home" "$updates")")
  assert_contains "$out" 'queued=0' "$why"
  assert_contains "$out" "$reason" "$label was refused for the wrong reason"
  [ "$(note_count "$home")" = 0 ] || fail "$why"

  sender=$(printf '%s' "$updates" | jq -r '.[0].message.from.id // empty')
  calls=$(grep -c '^call$' "$FM_TELEGRAM_TEST_OUTBOUND" 2>/dev/null || true)
  if [ "$sender" = "$CAPTAIN_ID" ]; then
    [ "$calls" = 1 ] || fail "$label: the captain got $calls replies, expected one"
    assert_grep "to=$CAPTAIN_ID" "$FM_TELEGRAM_TEST_OUTBOUND" \
      "$label: the refusal reply did not go to the captain's own chat"
    assert_no_grep "to=$STRANGER_ID" "$FM_TELEGRAM_TEST_OUTBOUND" \
      "$label: the bot replied into the chat the refused message arrived on"
  else
    [ "$calls" = 0 ] || fail "$label: the bot made $calls outbound call(s) for a sender it does not know"
  fi
  unset FM_TELEGRAM_TEST_OUTBOUND
  pass "$label is refused ($reason)"
}

test_rejects_a_stranger() {
  # Anyone who finds the bot can message it. Their message arrives here.
  assert_rejected 'a message from a user id that is not allowlisted' \
    "$(one_update ".[0].message.from.id = $STRANGER_ID")" \
    sender-not-allowed \
    'a stranger who found the bot was able to queue instructions for firstmate'
}

test_rejects_another_chat() {
  # A stranger's conversation with the bot carries its own chat id, so the chat
  # check is what keeps this correct if the chat shape ever stops being 1:1.
  assert_rejected 'a message arriving on a chat that is not allowlisted' \
    "$(one_update ".[0].message.chat.id = $STRANGER_ID")" \
    chat-not-allowed \
    'a message from an unrelated conversation was queued'
}

test_rejects_a_forward() {
  # The sneakiest hole: from.id IS the captain, but the WORDS are someone
  # else's. Forwarding must not launder a stranger's text into an instruction.
  assert_rejected 'a message the captain forwarded from somebody else' \
    "$(one_update '.[0].message.forward_origin = {type: "user", sender_user: {id: 555, is_bot: false}}')" \
    forwarded \
    "a forwarded message put somebody else's words into firstmate's queue"
}

test_rejects_legacy_forward_fields() {
  assert_rejected 'a forward carrying only the older forward_from field' \
    "$(one_update '.[0].message.forward_from = {id: 555, is_bot: false}')" \
    forwarded \
    'a forward described with legacy fields was queued'
}

test_rejects_via_bot() {
  assert_rejected 'a message composed through another bot' \
    "$(one_update '.[0].message.via_bot = {id: 42, is_bot: true, username: "somebot"}')" \
    via-bot \
    "another bot's inline composition was queued as the captain's words"
}

test_rejects_a_bot_sender() {
  assert_rejected 'a message sent by a bot account' \
    "$(one_update '.[0].message.from.is_bot = true')" \
    from-bot \
    'a bot account was able to queue instructions'
}

test_rejects_a_missing_sender() {
  assert_rejected 'a message with no sender at all' \
    "$(one_update 'del(.[0].message.from)')" \
    no-sender \
    'a message with no identifiable sender was queued'
}

test_rejects_an_edit() {
  # Edits are their own update type. Accepting them would let a message be
  # rewritten after firstmate had already read it.
  assert_rejected 'an edited message rather than a new one' \
    "$(captain_message | jq -c '[{update_id: 700, edited_message: .[0].message}]')" \
    not-a-message \
    'an edited message was queued'
}

test_rejects_a_channel_post() {
  assert_rejected 'a channel post rather than a private message' \
    "$(captain_message | jq -c '[{update_id: 700, channel_post: .[0].message}]')" \
    not-a-message \
    'a channel post was queued'
}

test_rejects_an_empty_allowlist() {
  # Deleting the allowlist is the captain's fastest local kill switch, so it has
  # to actually stop the channel rather than defaulting to open.
  local home out rc=0
  home=$(new_home)
  rm -f "$home/config/telegram-allow"
  out=$(ingest "$home" "$(capture "$home" "$(captain_message)")") || rc=$?
  [ "$rc" -ne 0 ] || fail 'removing the allowlist left the channel accepting messages'
  [ "$(note_count "$home")" = 0 ] || fail 'a message was queued with no allowlist present'
  assert_contains "$out" 'allowlist' 'the refusal does not name the missing allowlist'
  pass 'removing the allowlist stops the channel rather than opening it'
}

test_rejects_an_allowlist_with_no_ids() {
  # A present-but-empty allowlist is a different code path from a missing one,
  # and "nobody is allowed" must never resolve to "everybody is".
  local home out rc=0
  home=$(new_home)
  printf '# every id commented out\n#%s\n' "$CAPTAIN_ID" > "$home/config/telegram-allow"
  out=$(ingest "$home" "$(capture "$home" "$(captain_message)")") || rc=$?
  [ "$rc" -ne 0 ] || fail 'an allowlist naming nobody accepted the channel as configured'
  [ "$(note_count "$home")" = 0 ] || fail 'a message was queued against an allowlist naming nobody'
  assert_contains "$out" 'empty' 'the refusal does not name the empty allowlist'
  pass 'an allowlist that names nobody refuses rather than allowing everybody'
}

test_rejects_a_malformed_allowlist() {
  local home out rc=0
  home=$(new_home "$(printf '%s\nnot-a-number\n' "$CAPTAIN_ID")")
  out=$(ingest "$home" "$(capture "$home" "$(captain_message)")") || rc=$?
  [ "$rc" -ne 0 ] || fail 'a malformed allowlist line was silently skipped instead of refusing'
  [ "$(note_count "$home")" = 0 ] || fail 'a message was queued against a malformed allowlist'
  pass 'a malformed allowlist refuses rather than shrinking to the lines that parsed'
}

test_one_bad_update_does_not_block_a_good_one() {
  local home out
  home=$(new_home)
  out=$(ingest "$home" "$(capture "$home" "$(
    jq -cn --argjson uid "$CAPTAIN_ID" --argjson sid "$STRANGER_ID" '
      [ { update_id: 800, message: {
            message_id: 1, date: 1757000000,
            from: { id: $sid, is_bot: false }, chat: { id: $sid, type: "private" },
            text: "delete everything" } },
        { update_id: 801, message: {
            message_id: 2, date: 1757000001,
            from: { id: $uid, is_bot: false }, chat: { id: $uid, type: "private" },
            text: "status please" } } ]')")")
  assert_contains "$out" 'queued=1' 'the captain message beside a rejected one was not queued'
  assert_contains "$out" 'rejected=1' 'the stranger message was not counted as refused'
  assert_contains "$(note_bodies "$home")" 'status please' "the captain's message was lost"
  assert_not_contains "$(note_bodies "$home")" 'delete everything' "the stranger's message was queued"
  assert_grep '802' "$home/state/telegram.offset" 'the offset did not advance past both updates'
  pass 'a refused update neither queues nor blocks the captain'
}

# --- replay -----------------------------------------------------------------

test_a_replayed_capture_is_silent() {
  # The offset is persisted only after a note is safe on disk, so a crash can
  # replay a capture. That must cost nothing, not a duplicate instruction.
  local home file first second
  home=$(new_home)
  file=$(capture "$home" "$(captain_message)")
  first=$(ingest "$home" "$file")
  second=$(ingest "$home" "$file")
  assert_contains "$first" 'queued=1' 'the first ingest did not queue the message'
  assert_contains "$second" 'queued=0' 'a replayed capture queued the message a second time'
  assert_contains "$second" 'skipped=1' 'the replayed update was not recognised as already queued'
  [ "$(note_count "$home")" = 1 ] || fail "a replay produced $(note_count "$home") notes"
  pass 'replaying a capture after a crash queues nothing a second time'
}

# --- the whole path ---------------------------------------------------------

# fake_telegram <home> <first-response-json> installs a curl that answers the
# first call with the given body and then holds each later call briefly and
# answers with an empty update list, which is what an idle chat looks like.
fake_telegram() {
  local home=$1 first=$2 fakebin
  fakebin=$(fm_fakebin "$home")
  printf '%s' "$first" > "$home/first-response.json"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
n=$(cat "$FM_TELEGRAM_TEST_CALLS" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$FM_TELEGRAM_TEST_CALLS"
if [ "$n" = 0 ]; then
  cat "$FM_TELEGRAM_TEST_FIRST"
else
  sleep 1
  printf '{"ok":true,"result":[]}\n'
fi
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

test_a_message_travels_from_the_poll_to_one_wake() {
  # The whole inbound path through the real process-event runner: arm, poll,
  # accept, queue, advance, re-arm. Everything above tests one joint of it.
  local home fakebin out
  home=$(new_home)
  fakebin=$(fake_telegram "$home" "$(jq -cn --argjson uid "$CAPTAIN_ID" '
    { ok: true, result: [ { update_id: 900, message: {
        message_id: 5, date: 1757000000,
        from: { id: $uid, is_bot: false, first_name: "Cap" },
        chat: { id: $uid, type: "private" },
        text: "ship it when CI is green" } } ] }')")
  export FM_TELEGRAM_TEST_CALLS="$home/calls" FM_TELEGRAM_TEST_FIRST="$home/first-response.json"

  FM_HOME="$home" PATH="$fakebin:$PATH" "$ADAPTER" arm >/dev/null     || fail 'arming the Telegram channel failed'
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" timeout 60 "$ROOT/bin/fm-procevent.sh" start telegram 2>&1)     || fail "the runner failed to complete one Telegram capture"$'\n'"$out"

  assert_contains "$out" 'autohandled: telegram' 'the capture was left for a handler instead of being applied'
  [ "$(note_count "$home")" = 1 ] || fail "expected one queued note, found $(note_count "$home")"
  assert_contains "$(note_bodies "$home")" 'ship it when CI is green' \
    "the captain's message did not reach the note"
  assert_grep '901' "$home/state/telegram.offset" 'the read position did not advance'
  # Exactly one wake, and it is the note's own. A second `procevent` wake here
  # would make one phone message buzz firstmate twice.
  [ "$(grep -c . "$home/state/.wake-queue")" = 1 ] \
    || fail "one Telegram message produced $(grep -c . "$home/state/.wake-queue") wakes"
  assert_grep 'captain inbox note' "$home/state/.wake-queue" 'the wake is not the note announcing itself'
  # And the channel keeps listening.
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" list 2>&1)" telegram \
    'the channel did not re-arm after handling, so the next message would never arrive'
  unset FM_TELEGRAM_TEST_CALLS FM_TELEGRAM_TEST_FIRST
  pass 'one phone message becomes one note and one wake, and the channel re-arms'
}

test_a_broken_channel_stops_and_asks() {
  # A refused token or a second reader on the same bot will not fix itself, so
  # re-polling it just burns the same failure. It must stop and be visible.
  local home fakebin out
  home=$(new_home)
  fakebin=$(fake_telegram "$home" '{"ok":false,"error_code":401,"description":"Unauthorized"}')
  export FM_TELEGRAM_TEST_CALLS="$home/calls" FM_TELEGRAM_TEST_FIRST="$home/first-response.json"

  FM_HOME="$home" PATH="$fakebin:$PATH" "$ADAPTER" arm >/dev/null || fail 'arming failed'
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" timeout 60 "$ROOT/bin/fm-procevent.sh" start telegram 2>&1) || true

  assert_contains "$out" 'not-autohandled' 'a broken channel was quietly marked handled'
  assert_grep 'procevent telegram' "$home/state/.wake-queue" \
    'a broken channel raised no wake, so it would fail silently'
  [ "$(note_count "$home")" = 0 ] || fail 'a failed poll queued a note'
  unset FM_TELEGRAM_TEST_CALLS FM_TELEGRAM_TEST_FIRST
  pass 'a channel Telegram refuses stops and raises a wake instead of retrying forever'
}

# fake_telegram_unreachable <home> installs a curl that never reaches anything -
# the shape of a wifi drop or a VPN restart - and then recovers into an idle
# chat, so the re-armed poll has something harmless to block on.
fake_telegram_unreachable() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
n=$(cat "$FM_TELEGRAM_TEST_CALLS" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$FM_TELEGRAM_TEST_CALLS"
if [ "$n" -lt 8 ]; then
  printf 'curl: (6) Could not resolve host: api.telegram.org\n' >&2
  exit 6
fi
sleep 1
printf '{"ok":true,"result":[]}\n'
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

test_an_unreachable_network_keeps_the_channel_listening() {
  # A wifi blip is the one failure that fixes itself. Disarming on it would take
  # the channel down until an agent turn puts it back - during away mode, the
  # exact window this feature exists for.
  local home fakebin out
  home=$(new_home)
  fakebin=$(fake_telegram_unreachable "$home")
  export FM_TELEGRAM_TEST_CALLS="$home/calls"

  FM_HOME="$home" PATH="$fakebin:$PATH" "$ADAPTER" arm >/dev/null || fail 'arming failed'
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" timeout 180 "$ROOT/bin/fm-procevent.sh" start telegram 2>&1) || true

  assert_contains "$out" 'autohandled: telegram' \
    'an unreachable network was left for a handler instead of being absorbed'
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" list 2>&1)" telegram \
    'the channel did not re-arm after a transport failure, so the next message would never arrive'
  [ -s "$home/state/.wake-queue" ] && fail 'a transport blip woke firstmate'
  [ "$(note_count "$home")" = 0 ] || fail 'an unreachable poll queued a note'
  unset FM_TELEGRAM_TEST_CALLS
  pass 'an unreachable network re-arms and keeps listening instead of stopping'
}

# fake_telegram_status <home> <http-status> <body> installs a curl that answers
# EVERY call with that HTTP status and body, appending the status on its own
# trailing line as `curl -w` does for the real transport. A failure that keeps
# standing is what a rate limit or an edge outage actually looks like, and it is
# the only way to see whether the poll waits between attempts or hammers.
fake_telegram_status() {
  local home=$1 status=$2 body=$3 fakebin
  fakebin=$(fm_fakebin "$home")
  printf '%s' "$body" > "$home/first-response.json"
  printf '%s' "$status" > "$home/first-status"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
n=$(cat "$FM_TELEGRAM_TEST_CALLS" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$FM_TELEGRAM_TEST_CALLS"
cat "$FM_TELEGRAM_TEST_FIRST"
printf '\n%s' "$(cat "$FM_TELEGRAM_TEST_STATUS")"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# run_one_capture <home> <fakebin> -> the runner's output for a single capture
run_one_capture() {
  local home=$1 fakebin=$2 out
  export FM_TELEGRAM_TEST_CALLS="$home/calls" FM_TELEGRAM_TEST_FIRST="$home/first-response.json" \
    FM_TELEGRAM_TEST_STATUS="$home/first-status"
  FM_HOME="$home" PATH="$fakebin:$PATH" "$ADAPTER" arm >/dev/null || fail 'arming failed'
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" timeout 180 "$ROOT/bin/fm-procevent.sh" start telegram 2>&1) || true
  unset FM_TELEGRAM_TEST_CALLS FM_TELEGRAM_TEST_FIRST FM_TELEGRAM_TEST_STATUS
  printf '%s\n' "$out"
}

assert_channel_kept_listening() {  # <home> <out> <what>
  local home=$1 out=$2 what=$3 calls
  assert_contains "$out" 'autohandled: telegram' "a $what was left for a handler instead of being absorbed"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" list 2>&1)" telegram \
    "the channel did not re-arm after a $what, so the next message would never arrive"
  [ -s "$home/state/.wake-queue" ] && fail "a $what woke firstmate"
  [ "$(note_count "$home")" = 0 ] || fail "a $what queued a note"
  # Giving up after ONE attempt would hand the registration straight back to the
  # runner, which re-polls within seconds - answering a rate limit with a
  # request storm. The poll has to spend its own retries first.
  calls=$(cat "$home/calls" 2>/dev/null || echo 0)
  [ "$calls" -gt 1 ] || fail "the poll gave up after $calls attempt(s) on a $what instead of waiting and retrying"
}

test_a_rate_limit_keeps_the_channel_listening() {
  # 429 carries its own retry-after: Telegram is telling the poller to wait, not
  # that anything is wrong with the channel.
  local home out
  home=$(new_home)
  out=$(run_one_capture "$home" "$(fake_telegram_status "$home" 429 \
    '{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 30"}')")
  assert_channel_kept_listening "$home" "$out" 'rate limit'
  pass 'a rate limit re-arms and keeps listening instead of stopping'
}

test_a_gateway_page_keeps_the_channel_listening() {
  # An edge 502 answers with HTML, not Bot API JSON. It is gone seconds later.
  local home out
  home=$(new_home)
  out=$(run_one_capture "$home" "$(fake_telegram_status "$home" 502 \
    '<html><head><title>502 Bad Gateway</title></head><body>502 Bad Gateway</body></html>')")
  assert_channel_kept_listening "$home" "$out" 'gateway page'
  pass 'an edge gateway page re-arms and keeps listening instead of stopping'
}

test_a_second_reader_stops_and_asks() {
  # 409 means another poller holds this bot. Re-arming would just trade the
  # conflict back and forth forever, so it must stop and be visible.
  local home out
  home=$(new_home)
  out=$(run_one_capture "$home" "$(fake_telegram_status "$home" 409 \
    '{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}')")
  assert_contains "$out" 'not-autohandled' 'a conflicting second reader was quietly marked handled'
  assert_grep 'procevent telegram' "$home/state/.wake-queue" \
    'a conflicting second reader raised no wake, so it would fail silently'
  [ "$(note_count "$home")" = 0 ] || fail 'a conflicting poll queued a note'
  pass 'a second reader on the same bot stops and raises a wake'
}

# --- the message limit ------------------------------------------------------

# sending_curl <home> installs a curl that records the text it was asked to send
# and answers as the Bot API does on success.
sending_curl() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
for _a in "$@"; do
  case "$_a" in text=*) printf '%s' "${_a#text=}" > "$FM_TELEGRAM_TEST_SENT" ;; esac
done
printf '{"ok":true,"result":{"message_id":1}}\n200'
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

test_an_over_limit_digest_is_cut_rather_than_dropped() {
  # Telegram refuses text over 4096 characters. The digest that follows a long
  # injection wedge is exactly the one that grows past it, and silently losing
  # that push is worse than losing its tail.
  local home fakebin long out sent
  home=$(new_home)
  fakebin=$(sending_curl "$home")
  export FM_TELEGRAM_TEST_SENT="$home/sent.txt"
  long="Supervisor escalate: $(head -c 5000 /dev/zero | tr '\0' 'x')"

  out=$(printf '%s' "$long" | PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" notify - 2>&1) \
    || fail "notify refused an over-limit digest instead of cutting it: $out"
  assert_contains "$out" 'sent to' 'the over-limit digest was not sent'
  sent=$(cat "$FM_TELEGRAM_TEST_SENT")
  [ "$(wc -c < "$FM_TELEGRAM_TEST_SENT")" -le 4096 ] \
    || fail "notify sent $(wc -c < "$FM_TELEGRAM_TEST_SENT") bytes, over Telegram's 4096 limit"
  assert_contains "$sent" 'the full text is in the terminal' \
    'the cut digest does not say it was cut'
  assert_contains "$sent" 'Supervisor escalate' \
    'the cut kept the tail instead of the front, losing the earliest items'
  unset FM_TELEGRAM_TEST_SENT
  pass 'a digest over the message limit is cut at the front and still delivered'
}

test_a_cut_never_splits_a_character() {
  # The cut is a byte slice, and bash slices bytes under a C locale - which is
  # what the daemon inherits when LANG is unset. Landing inside a multi-byte
  # character produces an orphan byte, Telegram refuses a body that is not valid
  # UTF-8, and the push the truncation exists to save is lost anyway.
  local home fakebin long out
  home=$(new_home)
  fakebin=$(sending_curl "$home")
  export FM_TELEGRAM_TEST_SENT="$home/sent.txt"
  # A two-byte character repeated across the whole digest, so wherever the cut
  # lands it lands inside one.
  long="Supervisor escalate: $(awk 'BEGIN { for (i = 0; i < 3000; i++) printf "\303\251" }')"

  out=$(printf '%s' "$long" | LC_ALL=C PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" notify - 2>&1) \
    || fail "notify refused a multi-byte digest instead of cutting it: $out"
  iconv -f UTF-8 -t UTF-8 < "$FM_TELEGRAM_TEST_SENT" > /dev/null 2>&1 \
    || fail 'the cut split a character and sent invalid UTF-8, which Telegram refuses'
  [ "$(wc -c < "$FM_TELEGRAM_TEST_SENT")" -le 4096 ] \
    || fail "notify sent $(wc -c < "$FM_TELEGRAM_TEST_SENT") bytes, over Telegram's 4096 limit"
  assert_contains "$(cat "$FM_TELEGRAM_TEST_SENT")" 'the full text is in the terminal' \
    'the cut digest does not say it was cut'
  unset FM_TELEGRAM_TEST_SENT
  pass 'a cut lands on a character boundary, whatever the locale'
}

# --- telling the captain a message was refused ------------------------------

# recording_curl <home> installs a curl that records every invocation's text
# argument, one per line, and answers as the Bot API does on success.
recording_curl() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  : > "$home/outbound.log"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf 'call\n' >> "$FM_TELEGRAM_TEST_OUTBOUND"
prev=
for _a in "$@"; do
  case "$_a" in
    text=*) printf '%s\n' "${_a#text=}" >> "$FM_TELEGRAM_TEST_OUTBOUND" ;;
    chat_id=*) printf 'to=%s\n' "${_a#chat_id=}" >> "$FM_TELEGRAM_TEST_OUTBOUND" ;;
  esac
  [ "$prev" = --max-time ] && printf 'max-time=%s\n' "$_a" >> "$FM_TELEGRAM_TEST_OUTBOUND"
  prev=$_a
done
printf '{"ok":true,"result":{"message_id":1}}\n200'
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

test_a_refused_forward_from_the_captain_is_answered() {
  # The intent expects him to try forwarding. Refusing in silence means he sees
  # nothing, firstmate learns nothing, and the offset moves on - so he waits for
  # a reply that is never coming.
  local home fakebin out
  home=$(new_home)
  fakebin=$(recording_curl "$home")
  export FM_TELEGRAM_TEST_OUTBOUND="$home/outbound.log"
  out=$(PATH="$fakebin:$PATH" ingest "$home" "$(capture "$home" "$(jq -cn --argjson uid "$CAPTAIN_ID" '
    [ { update_id: 700, message: {
        message_id: 9, date: 1757000000,
        from: { id: $uid, is_bot: false, first_name: "Cap" },
        chat: { id: $uid, type: "private" },
        forward_origin: { type: "user", date: 1756000000 },
        text: "a colleague wrote this" } } ]')")")
  assert_contains "$out" 'rejected: update 700 forwarded' 'the forward was not refused'
  [ "$(note_count "$home")" = 0 ] || fail 'a forward became a note'
  assert_grep 'forwarded message' "$FM_TELEGRAM_TEST_OUTBOUND" \
    'the captain was never told his forward was refused'
  assert_grep 'Retype it' "$FM_TELEGRAM_TEST_OUTBOUND" \
    'the reply does not say what to do instead'
  # The reply is sent serially inside the ingest loop, under the channel lock,
  # so it must carry the short bound rather than the long poll's 70 seconds -
  # otherwise a batch of refused forwards holds up the captain's next real
  # message for as long as they take to time out.
  assert_grep 'max-time=10' "$FM_TELEGRAM_TEST_OUTBOUND" \
    'the refusal reply was not bounded to its short timeout'
  unset FM_TELEGRAM_TEST_OUTBOUND
  pass 'a forward from the captain is refused and he is told why'
}

test_a_replayed_refusal_is_answered_only_once() {
  # A capture is re-ingested whenever a later update in it fails to queue, and
  # the adapter's own header invites running `ingest` by hand. Every update that
  # was acted on leaves a receipt, so the second pass must stay quiet: a phone
  # buzz costs more than a line of terminal text, and repeating one is how a
  # channel earns being muted.
  local home fakebin file calls
  home=$(new_home)
  fakebin=$(recording_curl "$home")
  export FM_TELEGRAM_TEST_OUTBOUND="$home/outbound.log"
  file=$(capture "$home" "$(jq -cn --argjson uid "$CAPTAIN_ID" '
    [ { update_id: 800, message: {
        message_id: 4, date: 1757000000,
        from: { id: $uid, is_bot: false, first_name: "Cap" },
        chat: { id: $uid, type: "private" },
        forward_origin: { type: "user", date: 1756000000 },
        text: "a colleague wrote this" } } ]')")

  PATH="$fakebin:$PATH" ingest "$home" "$file" >/dev/null
  PATH="$fakebin:$PATH" ingest "$home" "$file" >/dev/null

  calls=$(grep -c '^call$' "$FM_TELEGRAM_TEST_OUTBOUND" || true)
  [ "$calls" = 1 ] || fail "a replayed refusal sent $calls reply/replies instead of one"
  unset FM_TELEGRAM_TEST_OUTBOUND
  pass 'a replayed refusal is answered exactly once'
}

test_a_refused_stranger_gets_total_silence() {
  # A bot that answers an unknown sender confirms it exists to whoever probed
  # it. The check must not become a probe amplifier, so nothing goes out at all
  # - not a reply, not a connection.
  local home fakebin out
  home=$(new_home)
  fakebin=$(recording_curl "$home")
  export FM_TELEGRAM_TEST_OUTBOUND="$home/outbound.log"
  out=$(PATH="$fakebin:$PATH" ingest "$home" "$(capture "$home" "$(jq -cn --argjson sid "$STRANGER_ID" '
    [ { update_id: 701, message: {
        message_id: 3, date: 1757000000,
        from: { id: $sid, is_bot: false, first_name: "Nobody" },
        chat: { id: $sid, type: "private" },
        text: "hello?" } } ]')")")
  assert_contains "$out" 'rejected: update 701 sender-not-allowed' 'the stranger was not refused'
  [ "$(note_count "$home")" = 0 ] || fail "a stranger's message became a note"
  [ -s "$FM_TELEGRAM_TEST_OUTBOUND" ] \
    && fail 'the bot answered a stranger, confirming to a prober that it exists'
  unset FM_TELEGRAM_TEST_OUTBOUND
  pass 'a stranger is refused in total silence, with no outbound call at all'
}

test_a_refused_stranger_leaves_no_receipt() {
  # A receipt exists to stop a replay repeating a buzz. A stranger is never
  # buzzed, so his receipt would suppress nothing - it would only let anyone who
  # found the bot's public link drop a permanent file on the captain's disk, one
  # per message, in a directory nothing prunes.
  local home fakebin receipts
  home=$(new_home)
  fakebin=$(recording_curl "$home")
  export FM_TELEGRAM_TEST_OUTBOUND="$home/outbound.log"
  PATH="$fakebin:$PATH" ingest "$home" "$(capture "$home" "$(jq -cn --argjson sid "$STRANGER_ID" '
    [ { update_id: 702, message: {
        message_id: 6, date: 1757000000,
        from: { id: $sid, is_bot: false, first_name: "Nobody" },
        chat: { id: $sid, type: "private" },
        text: "probe" } } ]')")" >/dev/null
  receipts=$(find "$home/state/telegram.seen" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$receipts" = 0 ] \
    || fail "a stranger's refused message left $receipts receipt(s) on disk"
  # Control: the captain's own refused message DOES leave one, so the assertion
  # above is about who was answered, not about receipts never being written.
  PATH="$fakebin:$PATH" ingest "$home" "$(capture "$home" "$(jq -cn --argjson uid "$CAPTAIN_ID" '
    [ { update_id: 703, message: {
        message_id: 7, date: 1757000000,
        from: { id: $uid, is_bot: false, first_name: "Cap" },
        chat: { id: $uid, type: "private" },
        forward_origin: { type: "user", date: 1756000000 },
        text: "somebody else wrote this" } } ]')")" >/dev/null
  receipts=$(find "$home/state/telegram.seen" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$receipts" = 1 ] \
    || fail "an answered refusal left $receipts receipt(s) instead of one"
  unset FM_TELEGRAM_TEST_OUTBOUND
  pass 'only a refusal the captain was told about leaves a receipt'
}

# --- the token --------------------------------------------------------------

test_the_token_is_never_printed() {
  # Assume every string this code prints ends up in a transcript.
  local home out rc=0
  home=$(new_home)
  out=$(FM_HOME="$home" "$CLI" status 2>&1)
  assert_not_contains "$out" "$FAKE_TOKEN" 'status printed the bot token'
  assert_contains "$out" 'configured' 'status does not report a configured channel'

  # A refusal path, where a careless error message would leak it.
  printf '# nobody\n' > "$home/config/telegram-allow"
  out=$(FM_HOME="$home" "$CLI" notify hello 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'notify sent with an allowlist that names nobody'
  # The reason matters: without it this passes on any failure, including the
  # network failure a not-really-refused send would produce.
  assert_contains "$out" 'allowlist is empty' \
    'notify failed for some other reason instead of refusing an empty allowlist'
  assert_not_contains "$out" "$FAKE_TOKEN" 'a notify refusal printed the bot token'

  out=$(FM_HOME="$home" "$ADAPTER" ingest /nonexistent-result 2>&1) || true
  assert_not_contains "$out" "$FAKE_TOKEN" 'an adapter error printed the bot token'
  pass 'the bot token appears in no output, including error paths'
}

# curl_recorder <home> installs a curl that records its own argv and stdin, then
# fails with a message containing the token - the shape of diagnostic that would
# leak it into a transcript.
curl_recorder() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_TELEGRAM_TEST_ARGV"
cat > "$FM_TELEGRAM_TEST_STDIN"
printf 'curl: (7) Failed to connect while fetching %s\n' \
  "$(sed -n 's/^url = "\(.*\)"$/\1/p' "$FM_TELEGRAM_TEST_STDIN")" >&2
exit 7
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

test_the_token_never_reaches_a_command_line() {
  # Every argument of every process on this machine is readable with `ps`, so a
  # token passed as one is a token handed to anyone with a shell here.
  local home fakebin out rc=0
  home=$(new_home)
  fakebin=$(curl_recorder "$home")
  export FM_TELEGRAM_TEST_ARGV="$home/curl.argv" FM_TELEGRAM_TEST_STDIN="$home/curl.stdin"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" notify 'ready for review' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'notify reported success while curl was failing'
  assert_present "$FM_TELEGRAM_TEST_ARGV" 'curl was never invoked, so this proves nothing'
  assert_no_grep "$FAKE_TOKEN" "$FM_TELEGRAM_TEST_ARGV" \
    'the bot token was passed to curl as a command-line argument'
  # Control: it did reach curl, just not through argv. Without this the test
  # would also pass against code that never sends the token at all.
  assert_grep "$FAKE_TOKEN" "$FM_TELEGRAM_TEST_STDIN" \
    'the token never reached curl, so the argv check above is vacuous'
  # And curl echoed it back, as a real diagnostic can.
  assert_not_contains "$out" "$FAKE_TOKEN" \
    "the token leaked into output through curl's own error message"
  assert_contains "$out" '<redacted>' 'the leaked token was dropped rather than redacted in place'
  unset FM_TELEGRAM_TEST_ARGV FM_TELEGRAM_TEST_STDIN
  pass 'the token reaches curl off the command line and is redacted out of its diagnostics'
}

test_captain_message_becomes_one_note
test_adapter_has_no_authority_beyond_the_note
test_rejects_a_stranger
test_rejects_another_chat
test_rejects_a_forward
test_rejects_legacy_forward_fields
test_rejects_via_bot
test_rejects_a_bot_sender
test_rejects_a_missing_sender
test_rejects_an_edit
test_rejects_a_channel_post
test_rejects_an_empty_allowlist
test_rejects_an_allowlist_with_no_ids
test_rejects_a_malformed_allowlist
test_one_bad_update_does_not_block_a_good_one
test_a_replayed_capture_is_silent
test_a_message_travels_from_the_poll_to_one_wake
test_a_broken_channel_stops_and_asks
test_an_unreachable_network_keeps_the_channel_listening
test_a_rate_limit_keeps_the_channel_listening
test_a_gateway_page_keeps_the_channel_listening
test_a_second_reader_stops_and_asks
test_an_over_limit_digest_is_cut_rather_than_dropped
test_a_cut_never_splits_a_character
test_a_refused_forward_from_the_captain_is_answered
test_a_replayed_refusal_is_answered_only_once
test_a_refused_stranger_gets_total_silence
test_a_refused_stranger_leaves_no_receipt
test_the_token_is_never_printed
test_the_token_never_reaches_a_command_line
