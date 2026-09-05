#!/usr/bin/env bash
# fm-telegram.sh - the operator surface of the Telegram captain channel.
#
# Usage:
#   fm-telegram.sh notify [--chat <id>] <text>...   | fm-telegram.sh notify -
#   fm-telegram.sh whoami
#   fm-telegram.sh status
#
# notify  Push one message to the captain's phone. This is the half a status web
#         page cannot do: a page is pull, a phone buzz is push. Send only what
#         AGENTS.md section 9 already says must reach the captain immediately -
#         work ready for review with its link, a finished investigation, a
#         decision, a real blocker, anything destructive or irreversible, a
#         needed credential. Never routine progress: a channel that cries wolf
#         gets muted, and then it is worse than not having it.
#         With one allowlisted id, --chat is unnecessary. With several it is
#         required, and the id must be allowlisted.
#         A bot cannot start a conversation, so the captain must have messaged
#         it at least once before this works.
# whoami  Print the numeric chat id and user id of whoever last messaged the
#         bot, so setup needs no third-party bot. It reads without an offset, so
#         it confirms nothing to Telegram and consumes no message.
#         Telegram allows exactly one active reader per token, so run this while
#         the channel is NOT armed; otherwise it reports a conflict.
# status  Say whether the channel is configured, and how many ids are
#         allowlisted. Prints no token and makes no network call.
#
# Setup and the security model live in docs/telegram.md. The allowlist check
# itself lives in bin/fm-telegram-lib.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

require_config() {
  fm_telegram_load_config || die "$FM_TELEGRAM_ERROR"
}

allowlist_only_id() {
  local count
  count=$(printf '%s' "$FM_TELEGRAM_ALLOW_IDS" | grep -c . || true)
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$FM_TELEGRAM_ALLOW_IDS" | head -n1
}

cmd_notify() {
  local chat='' text response
  if [ "${1-}" = "--chat" ]; then
    [ "$#" -ge 2 ] || die "--chat needs a numeric id"
    chat=$2
    shift 2
  fi
  [ "$#" -ge 1 ] || usage
  if [ "$1" = "-" ]; then
    text=$(cat)
  else
    text="$*"
  fi
  [ -n "${text//[[:space:]]/}" ] || die "refusing to send an empty message"

  require_config
  if [ -z "$chat" ]; then
    chat=$(allowlist_only_id) \
      || die "the allowlist holds several ids, so --chat <id> is required"
  fi
  # An outbound id must be allowlisted too. Otherwise a mistyped --chat would
  # deliver the captain's private fleet state to a stranger's chat.
  fm_telegram_id_allowed "$chat" || die "chat id is not on the Telegram allowlist: $chat"

  response=$(fm_telegram_api sendMessage \
    --data-urlencode "chat_id=$chat" \
    --data-urlencode "text=$text" \
    --data-urlencode 'disable_web_page_preview=true') || exit 1
  fm_telegram_api_result "$response" >/dev/null || exit 1
  printf 'sent to %s\n' "$chat"
}

cmd_whoami() {
  local response result count
  require_config
  response=$(fm_telegram_api getUpdates --data-urlencode 'limit=100') || exit 1
  result=$(fm_telegram_api_result "$response") || exit 1
  count=$(printf '%s' "$result" | jq -r 'length' 2>/dev/null) || count=0
  if [ "${count:-0}" -eq 0 ]; then
    printf 'no messages are waiting. Send your bot any message from Telegram, then run this again.\n'
    printf 'If the channel is already armed its poller has consumed them; check state/telegram.offset instead.\n'
    return 0
  fi
  printf '%s' "$result" | jq -r '
    [ .[] | select(has("message")) ] | last |
    if . == null then "no plain message found in the pending updates"
    else "user_id: \(.message.from.id // "?")   chat_id: \(.message.chat.id // "?")   from: \(.message.from.first_name // "?")"
    end'
  printf 'Put the numbers you recognise in %s, one per line.\n' "$(fm_telegram_allow_file)"
}

cmd_status() {
  local count
  if ! fm_telegram_load_config; then
    printf 'telegram: off (%s)\n' "$FM_TELEGRAM_ERROR"
    return 0
  fi
  count=$(printf '%s' "$FM_TELEGRAM_ALLOW_IDS" | grep -c . || true)
  printf 'telegram: configured\n'
  printf 'allowlist: %s id(s) in %s\n' "$count" "$(fm_telegram_allow_file)"
}

case "${1-}" in
  notify) shift; cmd_notify "$@" ;;
  whoami) shift; [ "$#" -eq 0 ] || usage; cmd_whoami ;;
  status) shift; [ "$#" -eq 0 ] || usage; cmd_status ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
