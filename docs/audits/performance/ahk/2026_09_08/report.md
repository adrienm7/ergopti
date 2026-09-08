<!-- docs/audits/performance/ahk/2026_09_08/report.md -->

# Tooltip latency attribution: cause not yet captured

No production optimization is justified by this pass. The intermittent 5 ms
failures remain open. The new measurements locate costs in successful executions;
they do not explain the earlier failing executions.

## Scope and provenance

- Source: `b584ad8bb501daca31933ced8070bfd6d89424f5`.
- Windows AutoHotkey v2, native layered border, 100 measured updates after one
  real warm-up allocation per case. No fake renderer or changed assertion budget.
- Captured on 2026-09-08, approximately 05:21:58–05:29:06 UTC, from the first
  output file's creation to the prefix output's last write. These are artifact
  timestamps, not per-keystroke wall-clock timestamps.
- No running-driver files, typing database, runtime log contents or process
  priorities were changed. This pass used exclusively allocated temporary Git
  archives and one native runner at a time.
- Other machine activity was not controlled or sampled. No claim about idle,
  loaded, foreground-app or production keystroke performance follows.
- Read-only review checked the segment boundaries and CPU interpretation.
  The parent independently parsed all 1,400 rows and checked that each segment
  sum equals its own elapsed sample, before rounding for CSV storage.

[samples.csv](samples.csv) contains every measured sample, rounded to 0.0001 ms.
[probe.patch](probe.patch) preserves the final temporary instrumentation and
prefix selection. Neither is applied to the checked-in driver or test runner.

## Historical failures that motivated this pass

These are prior receipts, not new measurements of the instrumented code:

- The first logger-fixture verification passed 5690/5691: pooled border p95
  7.548 ms against the unchanged 5 ms assertion.
- Three isolated runs on the unmodified production source at `6be81f806`
  measured pooled p95 2.8333, 1.4495 and 10.953 ms. The last independently
  reproduced that failure without the logger-fixture change.
- The next complete verification passed 5689/5691: pooled border p95 23.683 ms,
  complete preparation p95 6.931 ms. Both changed logger cases passed.
- A final isolated baseline tooltip group passed 3/3; it did not independently
  reproduce the complete-preparation failure.

The receipts and limits are also recorded in commit `b584ad8bb`. Original
local outputs are named `ergopti-logger-guard-verify.log`,
`ergopti-logger-guard-verify-repeat.log`,
`ergopti-tooltip-baseline-{1,2,3}.out`, and
`ergopti-tooltip-baseline-group.out` under TEMP. A later green result does not
erase a prior measured failure.

## New measurements

All 14 instrumented border cases passed. None of their 1,400 individual samples
reached 5 ms. Runs 1–3 used separate processes. Runs 4–13 repeated the same test
ten times in one process, with the original teardown after every case. Run 14
replayed all 357 original registered cases through the complete preparation
test, in their original order; that prefix passed 357/357.

| Run | Context | Median ms | p95 ms | Maximum ms | Thread CPU ms | Loop wall ms |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | isolated | 0.5649 | 1.0732 | 1.8262 | 62.5 | 62.4569 |
| 2 | isolated | 0.5802 | 1.6318 | 3.1400 | 78.125 | 78.2646 |
| 3 | isolated | 0.4599 | 0.8655 | 1.2401 | 46.875 | 50.5296 |
| 4 | same-process repeat | 0.6433 | 1.4485 | 2.4022 | 46.875 | 78.0578 |
| 5 | same-process repeat | 0.5054 | 0.7644 | 1.8948 | 46.875 | 56.0542 |
| 6 | same-process repeat | 0.4907 | 0.8083 | 3.4649 | 46.875 | 57.2937 |
| 7 | same-process repeat | 0.5035 | 0.8922 | 1.4209 | 46.875 | 57.2605 |
| 8 | same-process repeat | 0.5155 | 0.9991 | 1.3158 | 62.5 | 59.3717 |
| 9 | same-process repeat | 0.4450 | 0.6077 | 1.5359 | 46.875 | 49.0078 |
| 10 | same-process repeat | 0.6727 | 1.1216 | 3.2612 | 46.875 | 73.0202 |
| 11 | same-process repeat | 0.5843 | 1.0714 | 2.0693 | 46.875 | 66.1654 |
| 12 | same-process repeat | 0.4794 | 0.6452 | 1.6438 | 46.875 | 52.7047 |
| 13 | same-process repeat | 0.5041 | 0.9515 | 3.1070 | 46.875 | 64.7677 |
| 14 | 357-case prefix | 0.4930 | 0.7877 | 1.2809 | 62.5 | 53.1092 |

The percentile uses nearest rank, exactly as the existing test: sorted index
`ceil(100 * 0.95)`. Median here is the lower middle observation (rank 50).
The CSV stores the unmodified sample order so components can be compared within
the same observation instead of summing unrelated marginal percentiles.

## What the segments mean

The timer still encloses build, handle-identity assertion, recycle, and its
success assertion. Timestamp storage and sample-array bookkeeping are performed
as shown in the patch; no telemetry file or logger write occurs inside the loop.

| CSV segment | Inclusive region |
| --- | --- |
| prelude | Start timestamp storage through build preparation and pool entry |
| pool | Pool lookup/removal and Critical restoration |
| validation | HWND extraction and IsWindow through the next timestamp |
| move | SetWindowPos region, including any synchronous processing it triggers |
| build_return | Reuse counter, returns and build cleanup after movement |
| assert_hwnd | Exact HWND assertion |
| recycle_prelude | Recycle validation through the hide boundary |
| hide | GR_Hide, HWND access and its wrapper |
| recycle_return | Pool insertion/eviction bookkeeping and return |
| assert_recycled | Recycle acknowledgement assertion |

These are elapsed regions, **not native CPU attribution**. Restoring Critical can
permit a timer to run; synchronous native calls can wait or dispatch messages.

## Findings and rejected explanations

1. **No slow failure captured.** The largest instrumented sample was 3.4649 ms.
   The absence of a reproduced tail does not clear the existing failing tests.
2. **The warm path is not rebuilding the bitmap.** Current source returns the
   pooled owner before DIB allocation/drawing and UpdateLayeredWindow. The
   original native assertions still require one creation and 100 reuses.
   Blaming repeated bitmap allocation for this warm-loop failure is unsupported.
3. **Movement often dominates successful slow observations.** Run 6, sample 49,
   spent 3.2572 of 3.4649 ms in the move region. But this is not universal:
   run 10, sample 12, spent 2.7004 of 3.2612 ms in build-return; run 13, sample 23,
   spent 2.2186 of 3.1070 ms in pool bookkeeping/restoration.
   The same-sample rows, not sums of segment p95 values, support these statements.
4. **A deterministic predecessor effect was not reproduced.** The instrumented
   357-case prefix passed; this does not prove that earlier tests or concurrent
   activity can never contribute under other timing.
5. **No cache or threshold change is justified.** The loop deliberately changes
   X on each iteration. Skipping movement because the size is unchanged would
   change behavior, not optimize the measured contract.

## CPU and instrumentation limits

GetThreadTimes measures current OS-thread kernel plus user CPU across the whole
loop, including bookkeeping and any callbacks on that thread. Observed increments
are quantized in 15.625 ms steps. It is not a CPU measurement per segment.
The CPU endpoint is sampled just after the loop's QPC endpoint. Quantization and
that endpoint difference can make CPU exceed measured wall time in a short run;
small differences cannot establish waiting or preemption.

Every extra QPC/NumPut call adds work and changes AHK interruption opportunities.
No uninstrumented/instrumented randomized comparison was performed. The probe
therefore cannot exclude perturbation masking a timing-dependent failure.

Complete preparation already has clamp/show/corners/border measurements, but
their existing diagnostic reports marginal percentiles. They cannot be added
together or assumed to describe one iteration. This pass instruments the pooled
border only, not every step of complete preparation.

## Reproduction

Start from a newly created private directory, not an active sibling worktree:

```powershell
$probeRoot = Join-Path $env:TEMP ('ergopti-tooltip-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeRoot | Out-Null
git -C $repoRoot archive --format=tar -o "$probeRoot/source.tar" b584ad8bb501daca31933ced8070bfd6d89424f5 static/ergopti_plus/windows static/ergopti_plus/_shared
tar -xf "$probeRoot/source.tar" -C $probeRoot
git -C $probeRoot apply "$repoRoot/docs/audits/performance/ahk/2026_09_08/probe.patch"
```

Set `$repoRoot` to the absolute source checkout first and check every command's
exit code. Launch AutoHotkey64 with `/ErrorStdOut run_all.ahk` in the archive's
Windows tests directory, hidden and with stdout/stderr captured. The patch trims
only the temporary registry at the exact complete-preparation test name; it fails
if that endpoint is absent. The checked-in full suite remains unchanged.

For an isolated border case, add `--only "100 ordinary updates reuse"`.
The ten same-process repetitions used ten temporary registrations of
`_TBP_OrdinaryUpdatesReuseOneBorder`, selected with
`--only "pooled segment repetition"`; these extra registrations are not in
the final prefix patch. Recreate that diagnostic mode explicitly if needed.
Do not run two AHK runners, alter priority, remove assertions or increase budgets.

## Next work and coverage gaps

- Capture an actually slow execution with aligned timestamps before proposing a
  renderer change. Compare the components of the same five slow observations.
- Separate native waiting/message dispatch from AHK callback work around movement
  and Critical restoration. Thread CPU totals alone cannot distinguish them.
- Improve failure diagnostics to retain aligned complete-preparation samples;
  marginal segment percentiles do not establish which phase caused the p95 case.
- Preserve exact GUI/pool ownership and visibility under any later optimization.
- Keystrokes/hooks, startup, idle CPU, UIA, crash-worker enrichment and long-session
  memory were not measured in this pass. The earlier runtime-log inventory is a
  separate artifact, not a substitute for those missing workloads.
