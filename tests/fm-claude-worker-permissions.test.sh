#!/usr/bin/env bash
# Behavior tests for the worker permission grant bin/fm-spawn.sh installs on a
# claude crewmate or scout launch.
#
# The fault being pinned: an operator `permissions.ask` rule in the launching
# user's own Claude settings parks an unattended pane on a confirmation dialog
# firstmate cannot answer, and two of the captain's rules gate git operations
# every generated ship brief runs. No grant overrides an ask rule, so the spawn
# drops the USER settings source with --setting-sources project,local and
# re-supplies a derived copy of it through --settings instead
# (docs/verification/runtime-backends.md, "Claude permission-rule precedence").
#
# These tests run the REAL fm-spawn against a fake tmux pane, an isolated git
# worktree, and an isolated Claude config directory holding a real operator-shaped
# settings file, then read the launch command and the derived settings file the
# worker would actually load. Claude's own precedence is a vendor behavior and is
# NOT asserted here; tests/fm-claude-permission-precedence-live-e2e.test.sh is the
# guard that re-proves it against a real harness.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-worker-permissions)

# The captain's real rule set, in his own spelling: two rules gate operations a
# ship brief must run, three guard operations a worker has no business doing.
CAPTAIN_ASK_JSON='["Bash(git push --force *)","Bash(git push -f *)","Bash(git reset --hard *)","Bash(git clean -f *)","Bash(git rebase *)"]'

WORKER_REQUIRED_ASK=('Bash(git reset --hard *)' 'Bash(git rebase *)')
WORKER_DENIED_ASK=('Bash(git push --force *)' 'Bash(git push -f *)' 'Bash(git clean -f *)')

# make_case <name> [ask-json]: a firstmate home, a linked worktree, a fake tmux,
# and an isolated Claude config directory whose settings.json carries <ask-json>
# plus unrelated operator configuration. Omit <ask-json> for no settings file at
# all. Echoes "<case>|<home>|<proj>|<wt>|<config>|<fakebin>|<launch-log>".
make_case() {
  local name=$1 ask=${2-} case_dir home proj wt config fakebin launch_log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  launch_log="$case_dir/launch.log"
  mkdir -p "$config"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name"
  if [ -n "$ask" ]; then
    cat > "$config/settings.json" <<JSON
{"permissions":{"ask":$ask,"allow":["Bash(ls *)"],"deny":["Bash(curl *)"]},
 "statusLine":{"type":"command","command":"echo captain"},
 "env":{"CAPTAIN_MARKER":"kept"},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"true"}]}]}}
JSON
  fi
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$case_dir" "$home" "$proj" "$wt" "$config" "$fakebin" "$launch_log"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ WT CONFIG FAKEBIN LAUNCH_LOG <<EOF
$1
EOF
}

# run_case <record> <id> [extra fm-spawn args...]
run_case() {
  local record=$1 id=$2
  shift 2
  read_case "$record"
  FM_TEST_CLAUDE_CONFIG_DIR="$CONFIG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" claude \
    --mode no-mistakes --yolo off "$@"
}

# The derived file is the vendor's own settings format, so it is read as parsed
# JSON at a key path rather than asserted against serialized bytes.
derived_value() {  # <file> <key...> -> the JSON value at that key path
  local file=$1
  shift
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));let v=j;for(const k of process.argv.slice(2)){v=(v===undefined||v===null)?undefined:v[k];}console.log(JSON.stringify(v));' \
    "$file" "$@"
}

derived_ask() {  # <file> -> one ask rule per line
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));for(const r of ((j.permissions||{}).ask||[]))console.log(r);' "$1"
}

test_worker_launch_excludes_the_user_settings_source() {
  local record out
  record=$(make_case usersource "$CAPTAIN_ASK_JSON")
  out=$(run_case "$record" usersource)
  expect_code 0 $? "the claude spawn must succeed: $out"
  read_case "$record"
  assert_present "$LAUNCH_LOG" "the claude spawn sent no launch command"
  # The exclusion IS the grant: an ask rule that never enters the rule set
  # cannot gate the worker, and no other mechanism overrides one.
  assert_grep '--setting-sources project,local' "$LAUNCH_LOG" \
    "the worker launch did not drop the user settings source, so a user-level ask rule still gates it"
  assert_grep "--settings '$HOME_DIR/state/usersource.claude-settings.json'" "$LAUNCH_LOG" \
    "the worker launch did not load the derived settings that re-supply the captain's configuration"
  assert_grep 'claude --dangerously-skip-permissions' "$LAUNCH_LOG" \
    "the launch command was not the claude worker launch"
  pass "fm-spawn.sh: a claude worker launch loads project and local settings plus a derived copy, never the user file"
}

test_derived_settings_drop_only_the_git_rules_the_brief_requires() {
  local record out rule
  record=$(make_case granted "$CAPTAIN_ASK_JSON")
  out=$(run_case "$record" granted)
  expect_code 0 $? "the claude spawn must succeed: $out"
  read_case "$record"
  local derived="$HOME_DIR/state/granted.claude-settings.json"
  assert_present "$derived" "the spawn wrote no derived worker settings"
  # Both halves matter and they fail for different reasons: a kept rule freezes
  # the worker on every ticket, and a dropped one silently removes a guard the
  # captain wrote for himself.
  for rule in "${WORKER_REQUIRED_ASK[@]}"; do
    derived_ask "$derived" | grep -Fqx "$rule" &&
      fail "the derived worker settings still carry '$rule', so the worker freezes on the operation its brief requires"
  done
  for rule in "${WORKER_DENIED_ASK[@]}"; do
    derived_ask "$derived" | grep -Fqx "$rule" ||
      fail "the derived worker settings dropped '$rule', which is outside the grant and must keep gating a worker"
  done
  pass "fm-spawn.sh: the derived worker settings drop the brief's two git rules and keep every other ask rule"
}

test_derived_settings_preserve_the_captains_other_configuration() {
  local record out
  record=$(make_case preserved "$CAPTAIN_ASK_JSON")
  out=$(run_case "$record" preserved)
  expect_code 0 $? "the claude spawn must succeed: $out"
  read_case "$record"
  local derived="$HOME_DIR/state/preserved.claude-settings.json"
  # Dropping the user source drops EVERYTHING in it, so the derived copy is what
  # keeps the captain's own configuration reaching the worker.
  assert_contains "$(derived_value "$derived" statusLine command)" 'echo captain' \
    "the derived worker settings lost the captain's statusLine"
  assert_contains "$(derived_value "$derived" env CAPTAIN_MARKER)" 'kept' \
    "the derived worker settings lost the captain's env"
  assert_contains "$(derived_value "$derived" permissions allow)" 'Bash(ls *)' \
    "the derived worker settings lost the captain's allow rules"
  assert_contains "$(derived_value "$derived" permissions deny)" 'Bash(curl *)' \
    "the derived worker settings lost the captain's deny rules"
  assert_contains "$(derived_value "$derived" hooks PreToolUse)" '"command":"true"' \
    "the derived worker settings lost the captain's hooks"
  # The feedback-draft control the inline payload used to carry must survive the
  # move into the derived file, or a worker could draft a bug report as the captain.
  assert_contains "$(derived_value "$derived" feedbackDrafts)" 'off' \
    "the derived worker settings lost the feedback-draft control"
  pass "fm-spawn.sh: the derived worker settings preserve the captain's own configuration and the feedback-draft control"
}

test_absent_user_settings_still_produce_a_launchable_worker() {
  local record out
  record=$(make_case nosettings)
  out=$(run_case "$record" nosettings)
  expect_code 0 $? "the claude spawn must succeed with no user settings file: $out"
  read_case "$record"
  local derived="$HOME_DIR/state/nosettings.claude-settings.json"
  # No file means no rules to lose, so this is not the refusal case.
  assert_present "$derived" "the spawn wrote no derived worker settings when the user file was absent"
  assert_contains "$(derived_value "$derived" feedbackDrafts)" 'off' \
    "the derived worker settings lost the feedback-draft control when the user file was absent"
  assert_grep '--setting-sources project,local' "$LAUNCH_LOG" \
    "the worker launch dropped the source exclusion when the user file was absent"
  pass "fm-spawn.sh: an absent user settings file yields a launchable worker rather than a refusal"
}

test_unparseable_user_settings_refuse_the_spawn() {
  local record out
  record=$(make_case malformed "$CAPTAIN_ASK_JSON")
  read_case "$record"
  printf '%s\n' '{"permissions":{"ask":[' > "$CONFIG/settings.json"
  out=$(run_case "$record" malformed)
  expect_code 1 $? "the claude spawn must refuse unreadable user settings: $out"
  # Launching anyway would drop the whole user layer and leave the worker with
  # NO ask rules, which is wider than the grant and silent.
  assert_contains "$out" 'not valid JSON' \
    "the refusal did not name the malformed settings file: $out"
  assert_absent "$HOME_DIR/state/malformed.claude-settings.json" \
    "a refused spawn left derived worker settings behind"
  pass "fm-spawn.sh: malformed user settings refuse the spawn rather than dropping the captain's guards"
}

test_ask_rule_broader_than_the_grant_refuses_the_spawn() {
  local record out
  record=$(make_case broader '["Bash(git *)"]')
  out=$(run_case "$record" broader)
  expect_code 1 $? "the claude spawn must refuse an ask rule broader than the grant: $out"
  # Dropping Bash(git *) would remove the force-push and clean guards with it;
  # keeping it leaves a worker that still freezes. Neither is acceptable
  # silently, so the spawn refuses naming the rule.
  assert_contains "$out" 'Bash(git *)' \
    "the refusal did not name the rule that is broader than the grant: $out"
  assert_contains "$out" 'git rebase' \
    "the refusal did not name the operation the rule still gates: $out"
  assert_absent "$HOME_DIR/state/broader.claude-settings.json" \
    "a refused spawn left derived worker settings behind"
  pass "fm-spawn.sh: an ask rule broader than the grant refuses the spawn naming what it still gates"
}

test_narrower_git_ask_rule_is_kept() {
  local record out
  record=$(make_case narrower '["Bash(git rebase --onto *)","Bash(git rebase *)"]')
  out=$(run_case "$record" narrower)
  expect_code 0 $? "the claude spawn must succeed: $out"
  read_case "$record"
  local derived="$HOME_DIR/state/narrower.claude-settings.json"
  # The grant is the operation the brief runs, not every rule that mentions it:
  # a rule for a rebase flavour no brief uses is outside the grant.
  derived_ask "$derived" | grep -Fqx 'Bash(git rebase --onto *)' ||
    fail "the derived worker settings dropped 'Bash(git rebase --onto *)', which is narrower than the grant"
  derived_ask "$derived" | grep -Fqx 'Bash(git rebase *)' &&
    fail "the derived worker settings kept 'Bash(git rebase *)', so the worker still freezes on its own rebase"
  pass "fm-spawn.sh: an ask rule narrower than the grant is kept while the grant's own rule is dropped"
}

test_ask_rule_spellings_are_all_recognised() {
  local record out derived
  # Claude accepts several spellings of one command prefix, and a matcher that
  # only knew the captain's current spelling would silently stop granting if he
  # reformatted a rule.
  record=$(make_case spellings '["Bash(git rebase:*)","Bash(git reset --hard)"]')
  out=$(run_case "$record" spellings)
  expect_code 0 $? "the claude spawn must succeed: $out"
  read_case "$record"
  derived="$HOME_DIR/state/spellings.claude-settings.json"
  assert_contains "$(derived_value "$derived" permissions ask)" '[]' \
    "the colon and bare spellings of the granted rules were not recognised: $(derived_ask "$derived")"
  pass "fm-spawn.sh: the colon-wildcard and bare spellings of a granted rule are recognised"
}

test_non_bash_ask_rules_are_untouched() {
  local record out derived
  record=$(make_case nonbash '["WebFetch","Bash(git rebase *)"]')
  out=$(run_case "$record" nonbash)
  expect_code 0 $? "the claude spawn must succeed: $out"
  read_case "$record"
  derived="$HOME_DIR/state/nonbash.claude-settings.json"
  derived_ask "$derived" | grep -Fqx 'WebFetch' ||
    fail "the derived worker settings dropped a non-Bash ask rule, which is outside the grant entirely"
  pass "fm-spawn.sh: a non-Bash ask rule is outside the grant and survives the derivation"
}

test_secondmate_launch_keeps_the_user_settings_source() {
  local record out sub
  record=$(make_case secondmate "$CAPTAIN_ASK_JSON")
  read_case "$record"
  sub="$CASE_DIR/subhome"
  # make_case scaffolds a ship brief under this id; a secondmate needs its own
  # charter brief instead, so the seed writes that one from scratch.
  rm -rf "$HOME_DIR/data/secondmate"
  FM_HOME="$HOME_DIR" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" secondmate "$sub" --no-projects >/dev/null \
    || fail "seeding the secondmate home failed"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CONFIG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" secondmate "$sub" claude --secondmate)
  expect_code 0 $? "the claude secondmate spawn must succeed: $out"
  # A secondmate is a firstmate instance operating its own home, not a briefed
  # worker, so the grant deliberately does not reach it and its launch is unchanged.
  assert_no_grep '--setting-sources' "$LAUNCH_LOG" \
    "a secondmate launch dropped the user settings source, which is outside this grant"
  assert_grep '{"feedbackDrafts":"off"}' "$LAUNCH_LOG" \
    "a secondmate launch lost the inline feedback-draft control"
  assert_absent "$HOME_DIR/state/secondmate.claude-settings.json" \
    "a secondmate launch wrote derived worker settings"
  pass "fm-spawn.sh: a claude secondmate launch keeps the user settings source and mints no derived copy"
}

test_worker_launch_excludes_the_user_settings_source
test_derived_settings_drop_only_the_git_rules_the_brief_requires
test_derived_settings_preserve_the_captains_other_configuration
test_absent_user_settings_still_produce_a_launchable_worker
test_unparseable_user_settings_refuse_the_spawn
test_ask_rule_broader_than_the_grant_refuses_the_spawn
test_narrower_git_ask_rule_is_kept
test_ask_rule_spellings_are_all_recognised
test_non_bash_ask_rules_are_untouched
test_secondmate_launch_keeps_the_user_settings_source
