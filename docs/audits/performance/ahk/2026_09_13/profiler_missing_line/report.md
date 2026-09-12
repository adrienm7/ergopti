<!-- docs/audits/performance/ahk/2026_09_13/profiler_missing_line/report.md -->

# Missing profiler line investigation

## Trigger and scope

The nested profiler test failed in `state-calendar-gate-01` because its
`HpxInner` line was absent. The subsequent focused run passed 21 hotpath tests,
and the next selected full gate passed. Neither result explains the failure.

This investigation targets that synthetic test, not user typing performance.
Baseline: `12c12f9165498d6660c13fb6b3318320455da33f`. No resident restart,
private journal access, visible typing or concurrent owned heavy suite occurred.
The resident and UIA helper remained running. External system load was not
controlled or measured.

## Native repeated probe

A temporary test repeated the existing nested sample 100 times in one hidden
AutoHotkey v2 process. Each sample called `_HPX_BurnTicks(25)`, retained the
`A_TickCount` delta and sampled QPC immediately before logging the inner segment.
It then called the actual profiler and inspected the actual logger test sink.

| Observation | Result |
| --- | --- |
| Samples | 100 |
| Missing inner lines | 0 |
| Minimum pre-log QPC duration | 17.475 ms |
| Maximum pre-log QPC duration | 43.8607 ms |
| Configured slow threshold | 5 ms |

The first probe failed because it divided by the profiler frequency before
the profiler's lazy initialization. That was a probe error, not driver evidence.
The corrected probe computes the duration after the profiler initializes the
frequency. Its receipt is `hpx-clock-diagnostic-02.out`, session 5115, exit 0.
The snippet and receipts remain in the campaign scratch directory
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08`.

No percentiles or average were collected. These values measure the synthetic
spin before logging; they do not measure keystroke latency, startup, dashboard
opening, RAM usage or CPU utilization. No performance optimization is justified
by this sample.

## Diagnosis retained for the next failure

The test now retains the pre-log QPC endpoint and includes elapsed raw ticks,
frequency, effective threshold, warning enablement and captured-line count in
its missing-line assertion. It does not dump captured messages or alter the
threshold, logger delivery or nested-time assertions. This should distinguish
an insufficient clock interval from a delivery failure on the next occurrence.

The original failure remains unexplained. In particular, the successful sample
does not rule out clock resolution changes, transient logger state, reentrancy
or message loss. The temporary repeated test was removed from the normal suite
to avoid adding a recurring CPU spin solely to search for an intermittent issue.
