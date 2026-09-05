#!/usr/bin/env bash
# fm-telegram-lib.sh - the Telegram captain channel's credential handling, API
# transport, and the accept/reject check on one inbound update.
#
# Source this; it defines functions and runs nothing.
#
# THIS FILE IS THE SECURITY BOUNDARY OF THE TELEGRAM CHANNEL.
# A Telegram bot is a public object: its username is searchable and anyone who
# finds it can send it a message, so every update arriving at this home is
# untrusted until fm_telegram_update_verdict accepts it. Firstmate does that
# filtering itself, because unlike Relay there is no third-party service
# filtering for it. Widening a check here widens who can instruct an agent that
# runs commands on the captain's machine.
#
# Configuration, both LOCAL and gitignored, and both required:
#   .env                    FM_TELEGRAM_TOKEN=<bot token>
#   config/telegram-allow   allowed numeric Telegram ids, one per line
# With either missing the channel is inert and no Telegram call is ever made.
# An environment FM_TELEGRAM_TOKEN wins over the file, matching fm-x-lib.sh.
# FM_TELEGRAM_ENV_FILE and FM_TELEGRAM_ALLOW_FILE relocate the two files.
#
# The allowlist is one list of numeric ids checked against BOTH message.from.id
# and message.chat.id, because in the private chat this channel is built for
# they are the same number. Requiring both keeps the check correct if the chat
# shape ever changes, where every member would post into one shared chat id.
# Ids are matched numerically and never by username: a username can be released
# and reclaimed by somebody else, while a numeric id is permanent.
#
# THE TOKEN IS THE BOT. Anyone holding it can read every message queued for the
# bot and send messages as it. So it is never printed, never echoed, never
# placed in a command line where `ps` would show it, and never left in transport
# output: fm_telegram_api passes it to curl through a config file on stdin and
# redacts it out of curl's own diagnostics before they are printed.
set -u

_FM_TELEGRAM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FM_TELEGRAM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$_FM_TELEGRAM_LIB_DIR/.." && pwd)}"
_FM_TELEGRAM_HOME="${FM_HOME:-$_FM_TELEGRAM_ROOT}"

FM_TELEGRAM_API_BASE=${FM_TELEGRAM_API_BASE:-https://api.telegram.org}
FM_TELEGRAM_TIMEOUT=${FM_TELEGRAM_TIMEOUT:-70}

FM_TELEGRAM_TOKEN_VALUE=
FM_TELEGRAM_ALLOW_IDS=
# Why the channel is inert, set by the loaders and read by their callers.
# shellcheck disable=SC2034 # consumed by scripts that source this library.
FM_TELEGRAM_ERROR=

fm_telegram_env_file() {
  printf '%s\n' "${FM_TELEGRAM_ENV_FILE:-$_FM_TELEGRAM_HOME/.env}"
}

fm_telegram_allow_file() {
  printf '%s\n' "${FM_TELEGRAM_ALLOW_FILE:-$_FM_TELEGRAM_HOME/config/telegram-allow}"
}

# Read KEY from a .env-style file: last assignment wins, tolerating a leading
# "export ", surrounding whitespace, and one layer of matching quotes. Prints
# nothing when the file or key is absent, so empty output means unset.
fm_telegram_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# A bot token is "<digits>:<secret>". Shape is validated so a truncated or
# pasted-with-a-label value is refused here rather than becoming a confusing
# API error, and so nothing that is not a token ever reaches a URL.
fm_telegram_token_shape_valid() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]
}

fm_telegram_id_valid() {
  local LC_ALL=C
  [[ "${1-}" =~ ^-?[0-9]+$ ]]
}

# Load the allowlist into FM_TELEGRAM_ALLOW_IDS, one id per line. A line may
# carry a trailing "# comment". Any line that is not a numeric id fails the
# whole load rather than being skipped: a typo must disable the channel, never
# silently shrink the allowlist to the entries that happened to parse.
fm_telegram_load_allowlist() {
  local file line id count=0
  file=$(fm_telegram_allow_file)
  FM_TELEGRAM_ALLOW_IDS=
  [ -f "$file" ] || { FM_TELEGRAM_ERROR="no Telegram allowlist at $file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    id=${line%%#*}
    id=${id#"${id%%[![:space:]]*}"}
    id=${id%"${id##*[![:space:]]}"}
    [ -n "$id" ] || continue
    if ! fm_telegram_id_valid "$id"; then
      FM_TELEGRAM_ERROR="Telegram allowlist has a line that is not a numeric id: $file"
      FM_TELEGRAM_ALLOW_IDS=
      return 1
    fi
    FM_TELEGRAM_ALLOW_IDS="${FM_TELEGRAM_ALLOW_IDS}${id}"$'\n'
    count=$((count + 1))
  done < "$file"
  [ "$count" -gt 0 ] || { FM_TELEGRAM_ERROR="Telegram allowlist is empty: $file"; return 1; }
  return 0
}

fm_telegram_id_allowed() {
  local id=${1-}
  fm_telegram_id_valid "$id" || return 1
  [ -n "$FM_TELEGRAM_ALLOW_IDS" ] || return 1
  printf '%s' "$FM_TELEGRAM_ALLOW_IDS" | grep -qx -- "$id"
}

# Load token and allowlist. Returns 1 with FM_TELEGRAM_ERROR set when the
# channel is not configured, which is the ordinary inert state, not a fault.
fm_telegram_load_config() {
  local env_file
  FM_TELEGRAM_ERROR=
  env_file=$(fm_telegram_env_file)
  if [ -n "${FM_TELEGRAM_TOKEN+x}" ] && [ -n "${FM_TELEGRAM_TOKEN-}" ]; then
    FM_TELEGRAM_TOKEN_VALUE=${FM_TELEGRAM_TOKEN-}
  else
    FM_TELEGRAM_TOKEN_VALUE=$(fm_telegram_env_get FM_TELEGRAM_TOKEN "$env_file")
  fi
  if [ -z "$FM_TELEGRAM_TOKEN_VALUE" ]; then
    FM_TELEGRAM_ERROR="no FM_TELEGRAM_TOKEN in $env_file"
    return 1
  fi
  if ! fm_telegram_token_shape_valid "$FM_TELEGRAM_TOKEN_VALUE"; then
    FM_TELEGRAM_TOKEN_VALUE=
    # shellcheck disable=SC2034 # read by the scripts that source this library.
    FM_TELEGRAM_ERROR="FM_TELEGRAM_TOKEN is not a bot token of the form <digits>:<secret>"
    return 1
  fi
  fm_telegram_load_allowlist || { FM_TELEGRAM_TOKEN_VALUE=; return 1; }
  return 0
}

# Replace the loaded token wherever it appears in <text>. Every string this
# channel prints passes through here, on the assumption that anything printed
# ends up in a transcript or a log.
fm_telegram_redact() {
  local text=${1-}
  [ -n "$FM_TELEGRAM_TOKEN_VALUE" ] || { printf '%s' "$text"; return 0; }
  printf '%s' "${text//"$FM_TELEGRAM_TOKEN_VALUE"/<redacted>}"
}

# Call one Bot API method. The URL carries the token, so it is handed to curl
# through a config file on stdin: an argument would be visible to every `ps` on
# the machine. Method parameters are ordinary --data-urlencode arguments and
# carry no secret. Prints the response body, records the HTTP status in
# FM_TELEGRAM_HTTP_STATUS, and on failure prints the redacted curl diagnostic to
# stderr and returns nonzero.
fm_telegram_api() {
  local method=$1 err_file rc=0 raw err
  shift
  [ -n "$FM_TELEGRAM_TOKEN_VALUE" ] || { printf 'error: Telegram is not configured\n' >&2; return 1; }
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-err.XXXXXX") || return 1
  raw=$(printf 'url = "%s/bot%s/%s"\n' \
      "$FM_TELEGRAM_API_BASE" "$FM_TELEGRAM_TOKEN_VALUE" "$method" \
    | curl -sS --max-time "$FM_TELEGRAM_TIMEOUT" --config - -w '\n%{http_code}' "$@" 2>"$err_file") || rc=$?
  err=$(cat "$err_file" 2>/dev/null || true)
  rm -f -- "$err_file"
  if [ "$rc" -ne 0 ]; then
    printf 'error: telegram %s failed: %s\n' "$method" "$(fm_telegram_redact "$err")" >&2
    return "$rc"
  fi
  printf '%s' "$raw"
}

# The HTTP status rides back on its own trailing line, so a response survives a
# command substitution with its status still attached. Both readers below treat
# a response that arrived without one as a body of its own, which is what every
# caller saw before the status was carried at all.
fm_telegram_response_status() {  # <raw-response>
  case "${1-}" in
    *$'\n'[0-9][0-9][0-9]) printf '%s' "${1##*$'\n'}" ;;
  esac
}

fm_telegram_response_body() {  # <raw-response>
  case "${1-}" in
    *$'\n'[0-9][0-9][0-9]) printf '%s' "${1%$'\n'*}" ;;
    *) printf '%s' "${1-}" ;;
  esac
}

# Will a failed call fix itself? A 429 says in its own body how long to wait, a
# 5xx is Telegram's edge failing, and a body that is not the Bot API's JSON at
# all is an edge gateway page - every one of those is gone seconds later. A 401
# or a 409 is a rejected token or a second reader on the same bot, which nothing
# but the captain changes, so re-polling it just burns the same failure.
fm_telegram_failure_is_transient() {  # <raw-response>
  case "$(fm_telegram_response_status "${1-}")" in
    429|5[0-9][0-9]) return 0 ;;
  esac
  fm_telegram_response_body "${1-}" | jq -e 'type == "object" and has("ok")' >/dev/null 2>&1 || return 0
  return 1
}

# Print the "result" array of an API response, or fail with the API's own
# description. A Bot API error body never contains the token, but it is
# redacted anyway rather than trusting that.
fm_telegram_api_result() {
  local response ok description
  response=$(fm_telegram_response_body "$1")
  ok=$(printf '%s' "$response" | jq -r 'if type == "object" then (.ok // false) else "invalid" end' 2>/dev/null) || ok=invalid
  if [ "$ok" != true ]; then
    description=$(printf '%s' "$response" | jq -r '(.description // "unparseable response")' 2>/dev/null) \
      || description="unparseable response"
    printf 'error: telegram refused the call: %s\n' "$(fm_telegram_redact "$description")" >&2
    return 1
  fi
  printf '%s' "$response" | jq -c '.result'
}

# THE CHECK. Print "accept" or "reject:<reason>" for one update object, and
# exit 0 either way so a caller can log the reason. The allowlist must already
# be loaded. Every condition below is a reason a message that is not the
# captain's own typed word could otherwise reach firstmate:
#
#   not-an-update / bad-update-id   not a well-formed update
#   not-a-message                   an edit, a channel post, a reaction, or any
#                                   other update type. An edit is its own update
#                                   type, so accepting one would let a message be
#                                   rewritten after firstmate had read it.
#   forwarded                       message.forward_* is present: the sender is
#                                   the captain but the WORDS are somebody
#                                   else's. Retyping them makes them his.
#   via-bot                         composed through another bot's inline mode.
#   from-bot                        sent by a bot account.
#   no-sender / sender-not-allowed  message.from.id is absent or not allowlisted.
#   chat-not-allowed                message.chat.id is not allowlisted, so this
#                                   is a stranger's conversation with the bot,
#                                   which carries its own chat id.
#   no-text                         nothing to queue as the captain's words.
fm_telegram_update_verdict() {
  local update=$1 shape from_id chat_id text

  shape=$(printf '%s' "$update" | jq -r '
    if type != "object" then "not-an-update"
    elif (.update_id | type) != "number" then "bad-update-id"
    elif has("message") != true then "not-a-message"
    elif ((keys - ["update_id", "message"]) | length) != 0 then "not-a-message"
    elif (.message | type) != "object" then "not-a-message"
    elif ((.message | keys) | map(select(startswith("forward_"))) | length) != 0 then "forwarded"
    elif (.message | has("via_bot")) then "via-bot"
    elif (.message.from.is_bot // false) == true then "from-bot"
    elif (.message.from.id | type) != "number" then "no-sender"
    elif (.message.chat.id | type) != "number" then "no-chat"
    elif (.message.text | type) != "string" then "no-text"
    elif ((.message.text | length) == 0) then "no-text"
    else "ok"
    end' 2>/dev/null) || shape=not-an-update
  [ -n "$shape" ] || shape=not-an-update
  [ "$shape" = ok ] || { printf 'reject:%s\n' "$shape"; return 0; }

  from_id=$(printf '%s' "$update" | jq -r '.message.from.id | tostring' 2>/dev/null) || from_id=
  chat_id=$(printf '%s' "$update" | jq -r '.message.chat.id | tostring' 2>/dev/null) || chat_id=
  fm_telegram_id_allowed "$from_id" || { printf 'reject:sender-not-allowed\n'; return 0; }
  fm_telegram_id_allowed "$chat_id" || { printf 'reject:chat-not-allowed\n'; return 0; }

  text=$(printf '%s' "$update" | jq -r '.message.text' 2>/dev/null) || text=
  [ -n "${text//[[:space:]]/}" ] || { printf 'reject:no-text\n'; return 0; }

  printf 'accept\n'
}
