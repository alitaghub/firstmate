#!/usr/bin/env bash
# The state root is captain-private, and bin/fm-procevent.sh refuses one any
# other account can write to. Firstmate used to create it with a plain
# `mkdir -p`, so a home first created under a group-writable umask got a 775
# state root and every process-event command refused it from then on - with no
# way back except a manual chmod. These cases reproduce that under umask 002:
# the mode firstmate actually creates, the heal of an already-broken home, and
# the promise that a healthy home is left alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-private-state-root)

# Any script that creates the state root proves the contract; fm-lock.sh is the
# earliest one a session runs, and it creates the root before loading most of
# its libraries - the ordering that made this easy to get wrong.
create_state_root() {  # <home> <umask>
  local home=$1 mask=$2
  ( umask "$mask"; FM_HOME="$home" "$ROOT/bin/fm-lock.sh" acquire >/dev/null 2>&1 || true )
}

dir_mode() {  # <dir>
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# The exact condition bin/fm-procevent.sh rejects.
assert_no_shared_write() {  # <dir> <message>
  local mode
  mode=$(dir_mode "$1") || fail "$2: could not read the mode of $1"
  [ $((8#$mode & 8#022)) -eq 0 ] \
    || fail "$2: $1 is mode $mode, which any group or other account can write"
}

test_created_private_under_a_group_writable_umask() {
  local home
  home="$TMP_ROOT/fresh"
  mkdir -p "$home"
  create_state_root "$home" 002
  [ -d "$home/state" ] || fail "firstmate did not create the state root"
  assert_no_shared_write "$home/state" "a state root created under umask 002"
  # The whole point of the mode: process-event work has to be usable afterwards.
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" list >/dev/null 2>&1 \
    || fail "process-event work refused a freshly created state root"
  pass "a state root created under a group-writable umask is private and usable"
}

test_existing_group_writable_root_heals() {
  local home
  home="$TMP_ROOT/broken"
  mkdir -p "$home/state"
  chmod 775 "$home/state"
  [ "$(dir_mode "$home/state")" = 775 ] || fail "could not stage a group-writable state root"
  create_state_root "$home" 002
  assert_no_shared_write "$home/state" "an already group-writable state root"
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" list >/dev/null 2>&1 \
    || fail "process-event work still refused a healed state root"
  pass "a home left group-writable by an earlier run heals on the next one"
}

test_healthy_root_is_left_alone() {
  local home
  home="$TMP_ROOT/healthy"
  mkdir -p "$home/state"
  chmod 755 "$home/state"
  create_state_root "$home" 022
  [ "$(dir_mode "$home/state")" = 755 ] \
    || fail "an ordinary 755 state root was rewritten to $(dir_mode "$home/state")"
  pass "an ordinary state root keeps the mode its home already had"
}

test_created_private_under_a_group_writable_umask
test_existing_group_writable_root_heals
test_healthy_root_is_left_alone
