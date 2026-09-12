# Native updater fixture tree cleanup

## Scope and method

Measured on the Windows development PC on 2026-09-12 using native AutoHotkey
v2 and the generated PowerShell swap worker. Baseline: `8f47ccc24`.
Only one native verification ran at a time. The resident driver and UIA helper
remained running; other machine workload was not controlled. All fixtures were
synthetic, hidden, and stored in the campaign scratch directory on D:.

Reproduce with AutoHotkey64.exe `/ErrorStdOut`,
`static/ergopti_plus/windows/tests/run_all.ahk`, and
`--only=updater-sibling-cleanup`. Launch hidden and redirect stdout/stderr.
Set TEMP and TMP to an owned scratch directory. Durations below are the test
runner's QPC wall times, not CPU time or complete suite launch time.

Local receipts are in `D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08`.
They contain synthetic fixture results, not typing history.

## Evidence and change

The full baseline receipt `cache-target-stage-gate-01.out` measured 4822.742 ms
for refused swap cleanup and 4854.394 ms for primary swap failure cleanup.
Temporary phase instrumentation (`updater-phases-01.out`) measured 1406 ms in
the unconditional settle sleep in each case. Temporary Job Object observation
(`updater-job-observation-01.out`) counted three active descendants after worker
exit and zero after that sleep. Worker exit alone cannot authorize deletion.
Both temporary probes were removed before the final implementation.

The fixture now assigns its suspended worker to an owned unnamed Job Object
before resuming it. After releasing worker handles, cleanup waits for native
active-process accounting to reach zero. Query failure is an error, not an
empty tree. A bounded timeout attempts termination of the owned tree and retains
the failure even if termination succeeds. The job handle is closed on both
successful and failed waits. The original settle fallback remains for failure
before a tracking job exists. Production driver code is unchanged.

## Candidate measurements

| Test | Baseline | Candidate 01 | Candidate 02 |
| --- | ---: | ---: | ---: |
| Refused swap cleanup | 4822.742 | 3643.271 | 3676.039 |
| Primary swap failure cleanup | 4854.394 | 3605.677 | 3558.072 |
| Parent cleanup control | Not extracted | 2160.274 | 2161.059 |

All values are milliseconds. Candidate receipts are
`updater-job-candidate-01.out` and `updater-job-candidate-02.out`; each passed
all three selected tests. Relative to the single uninstrumented baseline,
observed reductions are 1146.703-1296.322 ms. Candidate maximums are 3676.039 ms
and 3605.677 ms respectively. Two candidate samples do not establish a latency
distribution. No RAM, CPU, driver responsiveness, or dashboard opening claim
follows from these measurements.

## Regression coverage

Native controls distinguish a suspended live tree, an empty tree, a missing
job handle, and an invalid native handle. The first control run exposed that a
null handle can query the current job; an explicit ownership guard fixes that
false success (`updater-job-controls-01.out`, then passing `-02.out`). Further
controls require cleanup failures to remain visible alongside a primary error
and prevent deletion when quiescence is unproved. Existing swap, rollback,
child-exit and deliberate deletion-refusal assertions remain enabled.

The first full gate caught an incorrect new test assumption: CloseHandle can
accept the `-1` pseudo-handle, so that value cannot prove release refusal.
The final control uses null for the release-refusal assertion and retains
`-1` separately for native job-query refusal. The failed receipt is
`updater-job-gate-01.out` (6223 passed, one new control failed).

Final `verify-change` receipt `updater-job-gate-02.out`, session 59919, exited
0: 6224 AHK tests, AHK encoding, and 225 JS checks passed. Three interactive
AHK cases remain excluded by the normal runner policy. No production AHK
changed, so this selected gate did not require the E2E runner.
