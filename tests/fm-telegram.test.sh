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
  assert_grep 'source=telegram' "$(find "$home/state/inbox" -name '*.note' | head -n1)" \
    "the queued note does not record that it came from Telegram"
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
assert_rejected() {
  local label=$1 updates=$2 reason=$3 why=$4 home out
  home=$(new_home)
  out=$(ingest "$home" "$(capture "$home" "$updates")")
  assert_contains "$out" 'queued=0' "$why"
  assert_contains "$out" "$reason" "$label was refused for the wrong reason"
  [ "$(note_count "$home")" = 0 ] || fail "$why"
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

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" whoami 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'whoami reported success while curl was failing'
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
test_the_token_is_never_printed
test_the_token_never_reaches_a_command_line
