<!-- docs/audits/performance/ahk/2026_09_08/thread_accounting/report.md -->

# Tooltip own-thread accounting

## Verdict

The latency defect remains open. Two instrumented runs captured failing complete
preparations, and the final instrumentation-disabled control also failed. Thread
CPU accounting was too coarse to classify individual 5 ms budget failures.
No production optimization, threshold change, process restart or reprioritization
was made. This pass supplies evidence, not a claim that the tooltip is fixed.

Source: `427e44588`, archived Windows and shared trees in an exclusively created
directory on D:. The immediately preceding full gate reported p95 12.096 ms and
maximum 22.613 ms; those observations are a different population and are not
combined with these samples.

## Fixed protocol and results

Four runs, in the declared order disabled/enabled/enabled/disabled. Each executes
the original registry prefix through test 359, including all 100 complete
preparations, original cleanup/reuse assertions and the original 5 ms p95 limit.
No warmup sample was discarded and no favorable run was selected.

As in the original test, row construction (`_TooltipBuildGui`) and disposal are
outside the measured window. The recorded total covers clamping, positioning,
corners and border work, not end-to-end tooltip creation or keystroke latency.

| Run | CPU capture | Median ms | p95 ms | Maximum ms | Samples >= 5 ms | Prefix result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 1 | Disabled | 2.2334 | 4.8046 | 11.4384 | 5 | 359/359 |
| 2 | Enabled | 2.6486 | 6.5400 | 13.5328 | 14 | 357/359 |
| 3 | Enabled | 2.5113 | 5.5948 | 10.0180 | 7 | 357/359 |
| 4 | Disabled | 2.6206 | 5.6584 | 10.9517 | 11 | 358/359 |

All 400 observations are in [samples.csv](samples.csv). The extraction checked
100 ordered samples per run, mode labels, nonnegative finite values and segment
sums within 0.000003 ms after decimal rounding. Raw native exits were 0, 1, 1, 1.

Runs 2 and 3 also failed the preceding pooled-border case, with p95 5.037 ms and
7.138 ms. That case does not invoke the added capture function. This prevents
attributing every failure in those runs solely to the extra capture calls.
It does not isolate machine load or establish the root cause.

## What the counters actually show

At run 2's p95 sample 96, total time was 6.5400 ms, including 5.7251 ms in content
positioning. That interval used 6,072,530 raw thread cycles. At maximum sample 29,
positioning took 9.8249 ms and 6,631,956 cycles; clamping contributed 3.3884 ms.

Run 3's p95 sample 28 instead split its 5.5948 ms between positioning (2.6560 ms)
and border work (2.7592 ms). Its maximum sample 30 spent 9.2287 ms in positioning
and used 5,960,605 cycles there. Median positioning cycles were 3,584,998 and
3,548,527 in the two enabled runs. These counts are not CPU durations: Microsoft
explicitly warns against converting them to elapsed time. [QueryThreadCycleTime](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-querythreadcycletime)

Every nonzero sampled user/kernel time delta was 15.625 ms. Total user and kernel
deltas were both zero in 89/100 and 91/100 samples despite nonzero cycle counts.
Thus a zero delta cannot prove that a slow sample was entirely waiting. The
100 ns FILETIME unit is not a promise of matching measurement resolution.
[GetThreadTimes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getthreadtimes)

## Instrumentation and limitations

The [replay patch](probe.patch) modifies the private archive only. Five boundaries
record GetThreadTimes, QueryThreadCycleTime and then QPC into preallocated storage.
CSV formatting and output occur after the measured loop. Kernel/user values are
staggered relative to cycles and QPC, and capture/buffering overhead remains in
adjacent intervals. Disabled controls retain one wrapper dispatch and branch
per boundary; they are not pristine unmodified baselines. Their CPU columns are
zero placeholders, not measurements.

Only the current OS thread is queried, using its pseudo-handle. Counts include
reentrant AHK work on that thread and cannot distinguish it from synchronous
native CPU work. No stacks, other-process traces or controlled machine-load
measurements were collected. Run-order variation also prevents estimating probe
overhead by subtracting the disabled timings from the enabled timings.

## Provenance and replay

AutoHotkey v2.0.26, same workstation as the preceding pass. Before the protocol,
resident PID 11412 and six existing UIA workers were present. None was stopped,
restarted or reprioritized. The resident was launched before the recent fixes;
this protocol does not test its loaded code or establish a current UIA leak.

| Run | Test PID | Completion UTC |
| --- | ---: | --- |
| 1 | 16740 | 2026-09-08T17:18:56.8725249Z |
| 2 | 17196 | 2026-09-08T17:19:30.3375161Z |
| 3 | 17340 | 2026-09-08T17:20:03.0489824Z |
| 4 | 3300 | 2026-09-08T17:20:44.0839754Z |

Archive `static/ergopti_plus/windows` and `static/ergopti_plus/_shared` from
`427e44588` into a new private directory, then apply the replay patch there.
Run the archived `static/ergopti_plus/windows/tests/run_all.ahk` with the real
AutoHotkey64 `/ErrorStdOut`, hidden, one process at a time. Set child environment
`ERGOPTI_TOOLTIP_THREAD_PROFILE` to `0`, `1`, `1`, `0` in that order. Keep TEMP/TMP
on D: and capture each native exit, stdout and stderr. The patch rejects a prefix
endpoint other than 359. Never apply it to the resident checkout.

Actual runs used the same helper from an absolute sibling scratch path; the
attached replay patch includes that helper locally for portability. Receipts
remain under `D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08/` as
`tooltip-thread-run1.out/.err` through `tooltip-thread-run4.out/.err`.

## Next discriminating work

GetThreadTimes is not a useful per-sample attribution tool at this budget on this
machine. Finer native-call boundaries or an appropriately scoped trace are still
needed to distinguish preparation, synchronous movement and callback work.

A read-only caller audit found no second SetWindowPos during normal reveal.
Content windows generally move from their initial origin to the requested
position, so skipping that move is not justified. Pooled borders, however,
unconditionally reposition even when already at the requested coordinates.
Measure that candidate with both unchanged and genuinely changed positions,
preserving native failure reporting, ownership and physical-coordinate behavior.
No benefit from that candidate has yet been demonstrated.
