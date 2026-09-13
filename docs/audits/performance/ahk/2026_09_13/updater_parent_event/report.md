<!-- docs/audits/performance/ahk/2026_09_13/updater_parent_event/report.md -->

# Native updater fixture parent wait

## Scope and provenance

Measured on Windows on 2026-09-13, around 12:02 Europe/Paris, with
`C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe`. Baseline: `30941b3e4`.
The candidate changes test fixtures only. The resident driver remained running;
no visible typing, driver restart or real metrics data was used. Other work on
the host was not controlled. Only one native test run was active at a time.

Existing per-case timings identified updater transactions among the slow cases.
The synthetic parent used a batch loop with `ping -n 2` before checking its exit
file again. It now waits on a named manual-reset Windows event in a hidden AHK
child. The real PowerShell swap worker, readiness handshake, exact parent handle,
replacement probation and rollback assertions remain exercised. An additional
native handle assertion requires the parent to be alive immediately before its
exit event is signaled.

## Method and results

Run the following selection three times per version, sequentially, with TEMP
and TMP pointing to the campaign scratch on D:. Launch hidden and wait for each
exact process to terminate before starting the next sample:

```text
AutoHotkey64.exe /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --only="updater swap transaction:"
```

All six runs passed all seven selected cases, with identical names and order.
Times below are sums of the runner's per-case durations, excluding harness
startup. Baseline samples: 10187.156, 10309.478, 10320.242 ms.
Candidate samples: 8183.642, 7538.996, 7984.343 ms.

| Case | Before median / max (ms) | After median / max (ms) |
| --- | ---: | ---: |
| Successful replacement | 2913.598 / 2921.282 | 2367.610 / 2431.942 |
| Missing replacement rollback | 2849.347 / 2865.976 | 2294.442 / 2447.764 |
| Interrupted backup recovery | 2870.475 / 2877.338 | 2259.917 / 2353.164 |
| Parent exit before FinalExit | 1216.817 / 1231.538 | 473.520 / 477.560 |
| All seven cases combined | 10309.478 / 10320.242 | 7984.343 / 8183.642 |

The combined median decreased by 2325.135 ms (22.6%). Three other cases in the
selection do not use this parent helper; no speedup is attributed to them.
Three samples cannot establish a p99 or a general machine-independent bound.

Receipts live in the campaign scratch:
`updater-parent-event-before-{1,2,3}.out`,
`updater-parent-event-after-{1,2,3}.out` and
`updater-parent-event-timings.cjs`. The parser requires seven passing cases in
every sample and rejects changed execution order or missing timings.

## Limits and regression risks

No whole-suite duration, CPU, RAM, driver latency or metrics-opening improvement
is claimed. This pass removes periodic child-process creation from the parent
fixture; it does not measure the memory tradeoff of using an AHK process.
The replacement fixture still uses its existing probation wait. Reducing that
wait without preserving the updater's survival check was not attempted.

The event is created before launch and held by the test owner, allowing an
early signal to remain observable. Parent cleanup keeps its exact process
handle. Success and cancellation cases close their event handles explicitly.
The change-scoped gate also covers cleanup-refusal and diagnostic fixtures
that reuse the changed parent helper.
