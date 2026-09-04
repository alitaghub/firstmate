#!/usr/bin/env bash
# Opt-in credentialed live guard for the claude worker permission grant that
# bin/fm-spawn.sh installs (--setting-sources project,local plus a derived
# --settings copy of the launching user's own Claude settings).
#
# The verdict this guard owns is a VENDOR one and cannot be proven without the
# real harness: whether a user-level `permissions.ask` rule still gates a
# --dangerously-skip-permissions launch, whether excluding the user source
# releases it, and whether --settings is still loaded alongside that exclusion.
# tests/fm-claude-worker-permissions.test.sh pins the derivation itself with no
# harness; this re-proves the three facts that derivation depends on and fails
# naming the harness and version when any of them changes.
#
# The derived settings under test are produced by a REAL fm-spawn against a fake
# tmux pane and an isolated firstmate home, from a COPY of this machine's own
# Claude settings, so the artifact exercised here is the one a worker loads.
# Claude keeps using its existing authentication, since an isolated
# CLAUDE_CONFIG_DIR has no credentials. Nothing outside the lab is written: this
# guard never modifies the user's Claude settings, and both probes are chosen to
# change nothing even if they run.
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude worker permission-grant guard"
  exit 0
fi

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v claude >/dev/null 2>&1 || fail "claude not found; this guard cannot report a pass it did not check"
command -v node >/dev/null 2>&1 || fail "node not found; the derived settings cannot be read"
CLAUDE_VERSION=$(claude --version)
HARNESS_ID="claude $CLAUDE_VERSION"

TMP_ROOT=$(fm_test_tmproot fm-claude-worker-permissions-live)

USER_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && USER_SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"

# The granted operations, each with a probe that MATCHES its ask pattern while
# provably changing nothing: no rebase is in progress, and the ref does not
# exist, so git refuses before touching the worktree.
GRANTED_OPS=('Bash(git rebase *)' 'Bash(git reset --hard *)')
GRANTED_PROBES=('git rebase --quit' 'git reset --hard refs/fm-live-guard-nosuchref')
# A retained rule with a dry-run probe, used to prove --settings was loaded at
# all rather than silently ignored (print mode ignores an invalid settings file
# without an error, so a positive load signal is required).
RETAINED_OP='Bash(git clean -f *)'
RETAINED_PROBE='git clean -f -n'

has_ask_rule() {  # <rule>
  node -e '
const fs=require("node:fs");
let j={};
try { j=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); } catch (e) { process.exit(2); }
const ask=((j.permissions||{}).ask)||[];
process.exit(ask.includes(process.argv[2])?0:1);' "$USER_SETTINGS" "$1"
}

# Build the derived settings a real worker launch would load, and echo
# "<derived-file>|<setting-sources value>".
build_worker_settings() {
  local case_dir home proj wt cfg fakebin log out sources derived
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  cfg="$case_dir/claude-config"
  log="$case_dir/launch.log"
  mkdir -p "$cfg"
  cp "$USER_SETTINGS" "$cfg/settings.json" || fail "$HARNESS_ID: could not copy $USER_SETTINGS into the lab"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-live
  fm_test_spawn_brief "$home" liveperm
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$cfg" FM_FAKE_LAUNCH_LOG="$log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" liveperm "$proj" claude \
    --mode no-mistakes --yolo off) ||
    fail "$HARNESS_ID: the worker spawn that mints the derived settings failed: $out"
  sources=$(grep -o -- '--setting-sources [a-z,]*' "$log" | head -1 | awk '{print $2}')
  [ -n "$sources" ] ||
    fail "$HARNESS_ID: the worker launch carried no --setting-sources, so this guard has nothing to exercise"
  derived="$home/state/liveperm.claude-settings.json"
  assert_present "$derived" "$HARNESS_ID: the worker spawn wrote no derived settings"
  printf '%s|%s\n' "$derived" "$sources"
}

# arm <label> <probe> <flags...> -> prints "gated" or "ran"
arm() {
  local label=$1 probe=$2 out
  shift 2
  out="$TMP_ROOT/$label.json"
  claude -p --dangerously-skip-permissions --model haiku --output-format json "$@" \
    "Run exactly this bash command and then report the tool result verbatim: $probe" \
    < /dev/null > "$out" 2>"$TMP_ROOT/$label.err" || true
  node -e '
const fs=require("node:fs");
let j;
try { j=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); }
catch (e) { console.log("unreadable"); process.exit(0); }
const denials=(j.permission_denials||[]).map((d)=>(d.tool_input||{}).command).filter(Boolean);
console.log(denials.includes(process.argv[2])?"gated":"ran");' "$out" "$probe"
}

scratch_repo() {
  local repo="$TMP_ROOT/scratch"
  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init -q .
  fm_git_identity
  printf 'x\n' > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" commit -qm init
  printf '%s\n' "$repo"
}

main() {
  local record derived sources i granted_op granted_probe repo verdict checked=0
  granted_op=
  granted_probe=
  for i in "${!GRANTED_OPS[@]}"; do
    if has_ask_rule "${GRANTED_OPS[$i]}"; then
      granted_op=${GRANTED_OPS[$i]}
      granted_probe=${GRANTED_PROBES[$i]}
      break
    fi
    case $? in
      2) fail "$HARNESS_ID: $USER_SETTINGS could not be parsed, so this guard cannot establish its precondition" ;;
    esac
  done
  if [ -z "$granted_op" ]; then
    # Reported explicitly rather than passed over: with no granted rule present
    # there is no gate to release, so the release facts are simply unchecked here.
    echo "skip: $HARNESS_ID: this machine's Claude settings carry no ask rule for a granted git operation (${GRANTED_OPS[*]}), so the grant has nothing to release; add one and re-run to refresh the record"
    exit 0
  fi

  record=$(build_worker_settings)
  IFS='|' read -r derived sources <<EOF
$record
EOF
  repo=$(scratch_repo)
  cd "$repo" || fail "$HARNESS_ID: could not enter the scratch repository"

  # Fact 1: the fault is real. With the user ask rule in force, even a settings
  # `allow` for the same pattern is gated, which is why the grant has to exclude
  # the source rather than out-rank it.
  verdict=$(arm fault "$granted_probe" --settings "{\"permissions\":{\"allow\":[\"$granted_op\"]}}")
  [ "$verdict" = gated ] || fail "$HARNESS_ID: a user-level ask rule no longer gates a launch that grants the same pattern (got '$verdict' for '$granted_probe'); permission precedence changed, so revisit docs/verification/runtime-backends.md before trusting the worker grant"
  checked=$((checked + 1))

  # Fact 2: excluding the user source releases the operation the brief requires.
  verdict=$(arm grant "$granted_probe" --setting-sources "$sources" --settings "$derived")
  [ "$verdict" = ran ] || fail "$HARNESS_ID: the worker launch flags no longer release '$granted_probe' (got '$verdict'); a worker would freeze on the operation its brief requires"
  checked=$((checked + 1))

  # Fact 3: --settings is still loaded alongside that exclusion, so the rules the
  # derivation KEPT still reach the worker. Skipped, and said so, when this
  # machine has no retained rule with a non-mutating probe.
  if has_ask_rule "$RETAINED_OP"; then
    verdict=$(arm retained "$RETAINED_PROBE" --setting-sources "$sources" --settings "$derived")
    [ "$verdict" = gated ] || fail "$HARNESS_ID: the derived settings no longer gate the retained rule $RETAINED_OP (got '$verdict' for '$RETAINED_PROBE'); the captain's own guards are not reaching the worker"
    checked=$((checked + 1))
    pass "$HARNESS_ID: a user-level ask rule gates a granted launch, the worker flags release '$granted_probe', and the retained rule $RETAINED_OP still gates through the derived settings"
  else
    pass "$HARNESS_ID: a user-level ask rule gates a granted launch and the worker flags release '$granted_probe'; the retained-rule load check was NOT run because this machine has no $RETAINED_OP rule"
  fi
  [ "$checked" -ge 2 ] || fail "$HARNESS_ID: this guard checked nothing and must not report a pass"
}

main
