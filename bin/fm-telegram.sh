#!/usr/bin/env bash
# fm-telegram.sh - the operator surface of the Telegram captain channel.
#
# Usage:
#   fm-telegram.sh notify <text>...   | fm-telegram.sh notify -
#   fm-telegram.sh status
#
# notify  Push one message to the captain's phone. This is the half a status web
#         page cannot do: a page is pull, a phone buzz is push. Send only what
#         AGENTS.md section 9 already says must reach the captain immediately -
#         work ready for review with its link, a finished investigation, a
#         decision, a real blocker, anything destructive or irreversible, a
#         needed credential. Never routine progress: a channel that cries wolf
#         gets muted, and then it is worse than not having it.
#         The recipient is the one allowlisted id; there is no way to name
#         another chat, so a mistyped recipient cannot exist.
#         A bot cannot start a conversation, so the captain must have messaged
#         it at least once before this works.
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
  local chat text response
  [ "$#" -ge 1 ] || usage
  if [ "$1" = "-" ]; then
    text=$(cat)
  else
    text="$*"
  fi
  [ -n "${text//[[:space:]]/}" ] || die "refusing to send an empty message"

  require_config
  # The recipient is read from the allowlist rather than named by the caller, so
  # the captain's private fleet state can only ever go to the chat he approved.
  chat=$(allowlist_only_id) \
    || die "notify needs exactly one id on the Telegram allowlist: $(fm_telegram_allow_file)"

  response=$(fm_telegram_api sendMessage \
    --data-urlencode "chat_id=$chat" \
    --data-urlencode "text=$text" \
    --data-urlencode 'disable_web_page_preview=true') || exit 1
  fm_telegram_api_result "$response" >/dev/null || exit 1
  printf 'sent to %s\n' "$chat"
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
  status) shift; [ "$#" -eq 0 ] || usage; cmd_status ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
