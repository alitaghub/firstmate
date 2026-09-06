# Lint worker residency memory verification

Audience: maintainer verification.

This record supports the active guarantee behind `bin/fm-lint.sh`'s one-resident-worker default: a single full-analysis ShellCheck worker over one logical shard fits a GitHub hosted runner's memory, while two concurrent workers do not reliably fit.
[`bin/fm-lint.sh`](../../bin/fm-lint.sh)'s header and `--help` own the current lint definition, the worker-count default, and the `FM_LINT_JOBS` override.
Exact task chronology, branch names, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Measurement

The two arms were measured on 2026-09-06 on Linux 6.18.33.2-microsoft-standard-WSL2 with 22 cores and 51.0 GiB of RAM (`MemTotal` 53457028 kB), against the pinned ShellCheck 0.11.0 reported by the script itself.
Both arms covered the full canonical set that CI lints: 359 roots and 10,762,805 direct bytes, split into two shards of 5,381,363 and 5,381,442 bytes.

Each arm ran the same lint definition, differing only in resident worker count:

```sh
GITHUB_ACTIONS=true FM_LINT_JOBS=2 bin/fm-lint.sh --telemetry telemetry.jobs2.tsv
GITHUB_ACTIONS=true FM_LINT_JOBS=1 bin/fm-lint.sh --telemetry telemetry.jobs1.tsv
```

Peak memory was read two independent ways, because each answers a different question.

A `/proc` sampler ran alongside each arm at 50 ms, tracking the peak of the instantaneous sum of `VmRSS` across every resident process named `shellcheck`, the peak per-process `VmHWM` high-water mark the kernel itself records, and the maximum number of resident ShellCheck processes:

```perl
next unless $comm eq 'shellcheck';
if ($l =~ /^VmRSS:\s+(\d+)/) { $sum += $1; $n++; }
if ($l =~ /^VmHWM:\s+(\d+)/) { $max_hwm = $1 if $1 > $max_hwm; }
```

The script's own `--telemetry` snapshot supplied `max_worker_rss_kib`, each worker's own maximum resident set as measured by `/usr/bin/time`, and `worker_rss_sum_kib`, the arithmetic sum of those per-worker maxima.

## Results

| measure | two workers | one worker |
| --- | --- | --- |
| sampled peak combined RSS | 14,533,256 KiB (14,193 MiB) | 8,493,580 KiB (8,295 MiB) |
| sampled peak per-process `VmHWM` | 8,491,408 KiB | 8,493,580 KiB |
| telemetry `max_worker_rss_kib` | 8,491,408 KiB | 8,492,816 KiB |
| telemetry `worker_rss_sum_kib` | 16,061,036 KiB | 16,167,708 KiB |
| maximum resident ShellCheck processes | 2 | 1 |
| wall clock | 578 s | 960 s |
| exit | 0 | 0 |

## The guarantee, and its measured margin

The guarantee rests on the per-shard maximum, which is the most reproducible quantity measured.
Three independent runs on this host read `max_worker_rss_kib` as 8,491,060, 8,491,408, and 8,492,816 KiB, a spread of 0.02%.
Taking the worst of those, one resident worker peaks at 8,294 MiB against a GitHub hosted runner's 16 GB, which is 15,259 MiB, so the guarantee holds with about 46% of the runner's memory unused.
Both one-worker arms independently confirmed a maximum of exactly one resident ShellCheck process, so the default's residency behavior is measured rather than inferred from the wait pattern.

## The two-worker peak is a range, not a point

Two runs of the two-worker arm sampled a combined peak of 15,685 MiB and 14,193 MiB, a 9.5% spread, while `worker_rss_sum_kib` agreed between them to 0.01% (16,058,780 and 16,061,036 KiB).
Both workers therefore reached the same individual peaks in both runs and simply did not reach them at the same instant in the second, so the combined peak is 14,193-15,685 MiB depending on how the two workers' peaks align in time.
Against a runner's 15,259 MiB, that range is reliably at or over the limit rather than deterministically over it, which is why the two-worker default is unsafe without being certain to fail on any single run.

## Per-shard memory is sensitive to the shard split

Two one-worker runs whose trees differed by 129 bytes read `max_worker_rss_kib` as 8,089,496 and 8,492,816 KiB, a 394 MiB difference, because the byte change moved the largest-first assignment's boundary:

```text
shard_1_weight_bytes 5,381,392   shard_2_weight_bytes 5,381,313   max_worker_rss_kib 8,089,496
shard_1_weight_bytes 5,381,363   shard_2_weight_bytes 5,381,442   max_worker_rss_kib 8,492,816
```

Per-shard memory depends on which source graphs land in the same process, not smoothly on the shard's byte weight, so a small change to the canonical set can move the peak by hundreds of MiB.
Re-measure rather than interpolate when the canonical set grows.

## Reconciling an earlier 36,714 MiB figure

An earlier figure of 36,714 MiB for this lint does not describe a simultaneous peak and must not be halved to derive a per-shard one.
`worker_rss_sum_kib` adds the maxima of workers that need never coexist, and the one-worker arms demonstrate that accounting directly: with a maximum of one resident process, whose sampled peak was 8,493,580 KiB, the same field still reported 16,167,708 KiB.
Only the sampled instantaneous sum and `max_worker_rss_kib` describe memory that is actually resident at one time.

## Refreshing this record

Re-run both arms with the commands above and re-read the same telemetry fields.
`bin/fm-lint.sh --list-files` under `GITHUB_ACTIONS=true` prints the canonical set the numbers cover, and `bin/fm-lint.sh --required-version` prints the ShellCheck pin they were measured against.
