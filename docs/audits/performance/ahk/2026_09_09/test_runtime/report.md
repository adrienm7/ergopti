# AHK test callback timing baseline

## Provenance

Measured on 2026-09-09 on Windows, starting from `d19ab2ed8` with the timing
instrumentation in this change. One complete run executed 5,848 tests, all
passing. Physical RAM was 7,274,124 KiB, with 2,256,872 KiB available before
the run. No other local test suite ran concurrently; desktop load was not
controlled. Node was 22.22.2. No private metrics store was used for profiling.

The command was `node tools/test/verify-change.cjs`. The retained native TAP
receipt is `ergopti_test_results_14932.txt` under
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08/`.
`summarize-test-timings.cjs` in the same directory parsed the complete receipt
through the repository execution-manifest validator. The validator's `--json`
option also exposes every measured callback as `executed[].duration_ms`.

## Initial measurements

QPC measures each callback, including its cleanup and exceptions, but excluding
TAP printing and framework error formatting. These are wall times, not CPU
times. The statistics below describe different tests within one run, not
repeated samples of a single operation.

| Statistic | Callback duration |
| --- | --- |
| Sum over all tests | 155,483.562 ms |
| Median across tests | 0.584 ms |
| 95th percentile across tests | 99.934 ms |
| Maximum | 4,902.502 ms |

| Largest measured cases | Duration |
| --- | --- |
| Updater native-child failure diagnosis | 4,902.502 ms |
| Updater missing replacement rollback | 3,811.829 ms |
| Updater interrupted backup recovery | 3,796.179 ms |
| Updater successful replacement | 3,777.136 ms |
| Updater parent crash before authorization | 2,565.240 ms |
| Crash worker responsiveness under delay | 2,476.104 ms |
| Crash worker large snapshot transport | 2,265.004 ms |
| Parse-time HotIf helper safety audit | 2,050.814 ms |

## Priorities and limits

This establishes a baseline; it does not claim a speedup. Driver keystroke,
startup and idle budgets were not measured in this test-runner pass. Peak RAM,
CPU consumption, total gate time and printing overhead remain unmeasured.

Inspect the updater fixtures first. Their common transaction cleanup waits a
fixed 1,400 ms before attempting directory removal. Replacement fixtures also
use a one-second `ping` wait. Replace such delays only if exact child-lifetime
receipts can preserve rollback, probation and cleanup coverage; deleting the
wait would not prove equivalent behavior. Then measure the source-audit cases
and crash-worker fixtures independently before changing their boundaries.

Do not delete slow tests or reduce safety deadlines based on this single run.
Compare candidate changes against the same selected cases with multiple fresh
processes, and retain their failure controls. Test splitting alone is not a
measured runtime improvement.

## Instrumentation checks

The native smoke executes a private copy of the real framework with a fast
callback, an 80 ms wait and a throwing callback after a 40 ms wait. It expects
the deliberate failure and verifies timing in both stdout and canonical TAP.
Before instrumentation, the test failed because all three duration records
were absent; afterward it passed. Parser tests reject partial, duplicate,
malformed and out-of-plan timings. Historical untimed receipts remain explicitly
unmeasured (`duration_ms: null`), never silently zero.
