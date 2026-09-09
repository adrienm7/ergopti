<!-- docs/audits/performance/ahk/2026_09_09/source_scan_baseline/report.md -->

# Native source-scan baseline

## Workload and provenance

Measured commit `e5258532da16b0bfc4f1b8762e4af5e16963e2c7`, Windows,
AutoHotkey 2.0.26 x64. Three fresh hidden processes selected the six existing
`meta: windows/` cases from the real runner. Every case passed in every sample;
each process exited zero. No source or counting threshold changed.

The output files span 2026-09-09 15:08:16 to 15:10:08 UTC. Each sample ran
serially after checking for other `verify-change` or `run-js-suite` processes.
The resident driver remained running. There was no explicit warm-up or filesystem
cache reset. Background desktop load was not controlled or measured.

Receipts are `os-purity-cost-baseline-01`, `-02`, and `-03`, each with `.out`,
`.err`, and `.exit`, under
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08/`.
The measurements below are the runner's native callback durations, not process
startup, full-suite duration, or end-to-end gate time.

## Results

| Case | Sample 1 (ms) | Sample 2 (ms) | Sample 3 (ms) |
| --- | ---: | ---: | ---: |
| Direct OS calls, modules/infra/platform | 566.416 | 551.963 | 580.598 |
| Direct OS calls, UI | 231.643 | 231.852 | 225.847 |
| Direct OS calls, entry point | 9.772 | 8.876 | 8.109 |
| Platform families, modules/infra/platform | 1118.176 | 1132.827 | 1080.921 |
| Platform families, UI | 438.944 | 464.520 | 441.126 |
| Platform families, entry point | 15.564 | 14.961 | 13.555 |
| Sum of six callbacks | 2380.515 | 2404.999 | 2350.156 |

The median sample total is 2380.515 ms; the maximum is 2404.999 ms.
The largest individual callback is 1132.827 ms. Three samples do not establish
a credible p95 or p99. CPU time and peak RAM were not measured.

## Decision and remaining work

These isolated callbacks are substantially shorter than some observations
inside earlier complete suites. That difference is not an optimization result:
the execution context and background load were not held constant across those
historical runs. Do not reuse the earlier multi-second case timings as this
workload's baseline or infer a speedup from this comparison.

No scanner optimization is proposed for implementation from these measurements
alone. The category loops repeat string checks, but operation counts are not
latency evidence for a replacement. A future candidate must preserve each
category's exact counts, case-insensitive matching, comment handling, and the
new failure behavior for unreadable files and missing trees. Passing the frozen
upper bounds alone cannot prove equivalent counts.

Prioritize investigation of updater fixtures with longer recorded callbacks,
while preserving real descendant-process lifetime and recovery evidence. The
[canceled-cleanup experiment](../test_runtime/canceled_cleanup.md) applies only
to its suspended child and explicitly does not authorize removal of waits from
the other transaction fixtures. Bounded incremental metrics profiling remains
a separate higher-priority user-facing latency investigation.

No budget verdict is asserted for typing hooks, Critical spans, startup,
tooltips, idle behavior, or dashboard opening; none were measured here.

## Reproduction

Run from the dedicated worktree, one process at a time, with the pinned native
runtime and no other heavy verification active. Keep a new receipt prefix for
each sample. The actual samples used the prefixes recorded above.

```powershell
$env:TEMP = 'D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08'
$env:TMP = $env:TEMP
$prefix = Join-Path $env:TEMP ('source-scan-' + [guid]::NewGuid().ToString('N'))
$process = Start-Process 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe' `
    -ArgumentList '/ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --only "meta: windows/"' `
    -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput ($prefix + '.out') -RedirectStandardError ($prefix + '.err')
$null = $process.Handle
$process.WaitForExit()
if ($null -eq $process.ExitCode) { throw 'Missing native exit code' }
if ($process.ExitCode -ne 0) { throw ('Native failure: ' + $process.ExitCode) }
```
