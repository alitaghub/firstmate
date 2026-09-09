# Browser and browser-MCP process cleanup verification

Audience: maintainer verification.

This record supports the active guarantee that a torn-down task leaves no browser and no browser MCP server behind.
[`bin/fm-teardown.sh`](../../bin/fm-teardown.sh)'s header owns the reap contract (its "Fix 2"), and [`bin/fm-spawn.sh`](../../bin/fm-spawn.sh) owns the per-task `CHROME_DEVTOOLS_AXI_SESSION` export.
The portable regressions in [`tests/fm-teardown.test.sh`](../../tests/fm-teardown.test.sh) pin the reap logic with real processes and no harness.

Paths below are shown with the home directory replaced by `<home>`, the numeric uid by `<uid>`, treehouse pool hashes by `<hash>`, Claude Code session ids by `<session-id>`, repository and branch names by `<repo>` and `<branch>`, and Chrome's random profile suffix by `<suffix>`.
`<home-slug>` is `<home>` with the slug rule of the "Claude Code scratchpad layout" section already applied.

## Why the worktree and tasktmp roots were not enough

Measured on 2026-09-08 on Linux 6.18 (WSL2), with Claude Code 2.1.260, `chrome-devtools-mcp` 1.8.0, `@playwright/mcp` (npx `latest`), `chrome-devtools-axi` (npm global), and Google Chrome at `/opt/google/chrome/chrome`.

The enumeration read `/proc` directly, because a filtered `ps` on this host did not list the browser processes at all:

```sh
for d in /proc/[0-9]*; do
  c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
  case "$c" in *chrome-devtools-mcp*|*playwright*|*chrome-devtools-axi*|*google/chrome*) ;; *) continue ;; esac
  ppid=$(awk '{r=$0; sub(/.*\) /,"",r); split(r,a," "); print a[2]}' "$d/stat")
  printf '%s ppid=%s cwd=%s\n  %s\n' "${d#/proc/}" "$ppid" "$(readlink "$d/cwd")" "${c:0:90}"
done
```

Three distinct process shapes were present, and the pre-change reap roots (worktree and tasktmp) reached only the first.

1. Harness-level MCP servers, one `npm exec chrome-devtools-mcp@latest` chain and one `npm exec @playwright/mcp@latest` chain per agent session, children of the agent process, each with the agent's own cwd:

```
2766138  ppid=2765784  cwd=<home>/.treehouse/firstmate-<hash>/1/firstmate
           npm exec chrome-devtools-mcp@latest --executablePath <home>/.local/bin/chrome-for-mcp
2766645  ppid=2766644  cwd=<home>/.treehouse/firstmate-<hash>/1/firstmate
           node .bin/playwright-mcp
```

2. A browser launched by such a server.
   Its main process inherits the worktree cwd, but every subprocess it forks chdir's out of reach of any cwd scan.
   Observed live from `@playwright/mcp`:

```
2860266  ppid=2766645  cwd=<home>/.treehouse/firstmate-<hash>/1/firstmate
           /opt/google/chrome/chrome --disable-field-trial-config ...
2860309  ppid=2860266  cwd=/proc/2860357/fdinfo    --type=zygote
2860362  ppid=2860309  cwd=/proc/2860357/fdinfo    --type=zygote
2860417  ppid=2860362  cwd=/proc/2860357/fdinfo    --type=utility ... storage.mojom.StorageService
```

3. A `chrome-devtools-axi` bridge, surviving at ppid 1 with its cwd in the Claude Code session scratchpad rather than the worktree, holding its own `chrome-devtools-mcp` and a real headless Chrome:

```
668786   ppid=1        cwd=/tmp/claude-<uid>/<home-slug>--treehouse-firstmate-bridge-<hash>-6-firstmate-bridge/<session-id>/scratchpad
           node .../chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js
668932   ppid=668931   cwd=<same scratchpad>    chrome-devtools-mcp
669094   ppid=668932   cwd=<same scratchpad>    /opt/google/chrome/chrome --headless=new --user-data-dir=/tmp/puppeteer_dev_chrome_profile-<suffix>
669096   ppid=1        cwd=<same scratchpad>    /opt/google/chrome/chrome_crashpad_handler
```

That bridge had started two days earlier and belonged to the already-removed task worktree `<home>/.treehouse/firstmate-bridge-<hash>/6/firstmate-bridge`; no `state/*.meta` in that home still named it.
Shape 2's subprocesses and shape 3's whole chain are why the reap needs both the harness scratchpad root and the descendant expansion.

## Claude Code scratchpad layout

Claude Code places a session's scratchpad at `<tmpdir>/claude-<uid>/<slug>/<session-uuid>/scratchpad`, where `<slug>` is the session's own working directory with every non-alphanumeric byte replaced by `-`.
Confirmed against every directory present under `/tmp/claude-<uid>` on 2026-09-08, for example:

```
<home>/.treehouse/firstmate-bridge-<hash>/6/firstmate-bridge
  -> <home-slug>--treehouse-firstmate-bridge-<hash>-6-firstmate-bridge
<home>/github/<repo>/.claude/worktrees/<branch>-<hash>
  -> <home-slug>-github-<repo>--claude-worktrees-<branch>-<hash>
```

The session slugs its own working directory, which the kernel reports with every symlink already resolved, while the recorded worktree path may still carry a symlinked component.
`task_scratchpad_roots` therefore emits both spellings, canonical first.

This layout is a vendor convention, so re-verify it after a Claude Code upgrade by comparing a live session's scratchpad path against the slug rule above.
A derived root that does not exist is a silent no-op in the reap, so a layout change degrades this backstop to the pre-change behavior rather than breaking teardown.

## The bridge is a per-session singleton

`chrome-devtools-axi` keeps one bridge process per session name.
On 2026-09-08 the default session's record was `~/.chrome-devtools-axi/bridge.pid` containing `{"pid":668786,"port":9224}`, with named sessions under `~/.chrome-devtools-axi/sessions/<name>/`, and `chrome-devtools-axi --help` documents `CHROME_DEVTOOLS_AXI_SESSION` as giving each session "its own bridge process, port ... and on-disk state".
Without a per-task session name every concurrent crew shares that one bridge, so a cwd-matched reap of a finished task's bridge could stop a browser a live crew is still driving.
`fm-spawn` therefore exports `CHROME_DEVTOOLS_AXI_SESSION=<task id>` into the crew's shell; that is what makes a bridge found under a task's scratchpad the task's own.

## Cost of the leak

Measured on 2026-09-08 with the machine at 13 GiB of 52 GiB used, eight session groups of seven browser-MCP processes each were alive, 56 processes holding about 3.0 GiB of resident memory in total (RSS sums over-count shared pages), roughly 150-560 MiB per group:

```sh
for d in /proc/[0-9]*; do
  c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
  case "$c" in *chrome-devtools-mcp*|*playwright*) ;; *) continue ;; esac
  printf '%s %s\n' "$(readlink "$d/cwd")" "$(awk '/^VmRSS/{print $2}' "$d/status")"
done | awk '{rss[$1]+=$2; n[$1]++} END{for (k in rss) printf "%6d MiB %2d procs %s\n", rss[k]/1024, n[k], k}' | sort -rn
```

Most of those groups belonged to Claude Code sessions that are not Firstmate tasks, including cloud sessions under `~/.claude/remote/<agent>/`, which no Firstmate teardown owns or may touch.
