# Lint worker residency memory verification

Audience: maintainer verification.

This record supports the active guarantee behind `bin/fm-lint.sh`'s one-resident-worker default: a single full-analysis ShellCheck worker over one logical shard fits a GitHub hosted runner's memory with a measured margin.
It also records what the two-worker arm did and did not show, because the measured two-worker peak does not on its own explain the kills that motivated the default.
[`bin/fm-lint.sh`](../../bin/fm-lint.sh)'s header and `--help` own the current lint definition, the worker-count default, and the `FM_LINT_JOBS` override.
Exact task chronology, branch names, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Measurement

The two arms were measured on 2026-09-06 on Linux 6.18.33.2-microsoft-standard-WSL2 with 22 cores and 51.0 GiB of RAM (`MemTotal` 53457028 kB), against the pinned ShellCheck 0.11.0 reported by the script itself.
Both arms covered the full canonical set that CI lints: 359 roots and 10,762,805 direct bytes, split into two shards of 5,381,363 and 5,381,442 bytes.

That byte fingerprint drifts by design, and will not match on a later reading.
`bin/fm-lint.sh` and `tests/fm-lint.test.sh` are themselves canonical roots, so any commit that edits the lint or the test guarding the behavior described here changes the byte total, moves both shard weights, and can flip which shard is the larger.
This is a permanent property of measuring a lint with the lint's own source in scope, not a stale number waiting to be corrected.

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

One limit of the sampler is worth recording, because it bounds how far the two-worker numbers can be trusted.
The sampler matched processes by name alone, so any ShellCheck belonging to something other than the arm under measurement would have been added to the same sum.
The script emits `shellcheck_processes_start` and `shellcheck_processes_end` to detect exactly that, and those two fields were not captured for these arms.

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

## What the two-worker arm shows, and what it does not

Exactly one instantaneous combined peak was sampled for the two-worker arm: 14,533,256 KiB, or 14,193 MiB.
That is about 1,066 MiB below the 15,259 MiB a nominal 16 GB runner offers, so nominal runner capacity does not explain why the job was killed.
Two two-worker runs were made, and their `worker_rss_sum_kib` readings agree to 0.01% (16,058,780 and 16,061,036 KiB), so both workers reached the same individual peaks in both runs; only one of the two runs has a sampled instantaneous peak.

A figure of 15,685 MiB also circulates for this arm.
It is `worker_rss_sum_kib` (16,061,036 KiB), the arithmetic sum of the two workers' separate maxima, and it is **not** a measurement of simultaneous residency: no measurement here shows both workers holding their own peak at the same instant.
Do not compare it against a runner's memory.

The evidence that the two-worker default is unsafe is behavioral rather than a measured peak over the limit: the canonical lint job died twice at its memory peak and emitted zero diagnostics.

A runner's true available memory - what is left after the OS, the preinstalled toolchain, and the job's own processes - was not measured.
It is lower than nominal, and it is the plausible remaining explanation for a 14,193 MiB peak being fatal there.
That is an open question this record does not settle, not a conclusion it establishes.

## Per-shard memory is sensitive to the shard split

Two one-worker runs whose trees differed by 129 bytes read `max_worker_rss_kib` as 8,089,496 and 8,492,816 KiB, a 394 MiB difference, because the byte change moved the largest-first assignment's boundary:

```text
shard_1_weight_bytes 5,381,392   shard_2_weight_bytes 5,381,313   max_worker_rss_kib 8,089,496
shard_1_weight_bytes 5,381,363   shard_2_weight_bytes 5,381,442   max_worker_rss_kib 8,492,816
```

Per-shard memory depends on which source graphs land in the same process, not smoothly on the shard's byte weight, so a small change to the canonical set can move the peak by hundreds of MiB.
Re-measure rather than interpolate when the canonical set grows.

Sensitivity of roughly 400 MiB per small canonical-set change sits against a measured margin of about 6,965 MiB, so the two quantities are an order of magnitude apart.
A few hundred bytes of the drift described above is therefore not a reason to re-measure; new roots or a materially larger set is.

## An earlier 36,714 MiB figure is not reproduced

An earlier figure of 36,714 MiB for this lint is not reproduced by anything measured here.
It is 2.34 times the measured 15,685 MiB sum of per-worker maxima, so summing maxima - the one accounting that inflates a figure well past actual residency - cannot produce it either.
That accounting is real and worth knowing: the one-worker arms show a maximum of one resident process, whose sampled peak was 8,493,580 KiB, while `worker_rss_sum_kib` for the same arm still reported 16,167,708 KiB.
It just does not reach 36,714 MiB from these numbers, and the older figure's provenance is unknown.

Nothing in the one-worker guarantee depends on resolving it.
The guarantee rests on the directly measured per-shard peak in the section above, and only the sampled instantaneous sum and `max_worker_rss_kib` describe memory that is actually resident at one time.

## Refreshing this record

Re-run both arms with the commands above and re-read the same telemetry fields, capturing `shellcheck_processes_start` and `shellcheck_processes_end` so a foreign ShellCheck cannot be mistaken for the arm's own.
`bin/fm-lint.sh --list-files` under `GITHUB_ACTIONS=true` prints the current canonical set, which is the set to measure against; expect its byte total and shard split to drift slightly from the fingerprint recorded above rather than to confirm it.
`bin/fm-lint.sh --required-version` prints the ShellCheck pin the recorded numbers were measured against.
