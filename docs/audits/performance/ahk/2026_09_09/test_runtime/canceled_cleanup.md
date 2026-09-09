# Canceled updater fixture cleanup

## Measurement

Measured on Windows on 2026-09-09, baseline `abed22d1f`. Three sequential,
fresh hidden AutoHotkey processes ran `tests/run_all.ahk --only=canceled`
before and after the fixture change. No concurrent local test suite ran.
Desktop load was uncontrolled. QPC records callback wall time, not CPU time
or total suite startup. No private metrics data was used.

| Sample | Original callback (ms) | Checked cleanup (ms) |
| --- | --- | --- |
| 1 | 1518.982 | 83.887 |
| 2 | 1498.842 | 93.610 |
| 3 | 1478.315 | 82.480 |

All six baseline selected cases passed on each run. All seven candidate
selected cases passed on each run. The added locked-file regression takes
1036.177, 1044.268 and 1033.660 ms respectively: its cost offsets most of
the removed delay, so these numbers do not establish a 1.4-second net suite
speedup. Full-suite time, CPU and peak RAM are not measured here.

Receipts are `updater-cancel-{baseline,candidate}-{1,2,3}.out` in
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08/`.

## Safety and regression proof

The canceled process is created suspended and never resumed. Its exact handle
signaling exit proves completion without waiting an additional fixed 1400 ms.
The other updater fixtures can launch descendants and retain their existing
waits; this argument does not justify changing them.

The original fixture swallowed directory deletion failure. The regression
holds its own script open without delete sharing and calls the real fixture.
Before the fix it fails because cleanup incorrectly reports success; native
receipt `updater-cancel-cleanup-red.out` exits 1 with that exact assertion.
Afterward it requires the directory-specific failure and restoration of all
saved updater globals, releases its lock and removes its own directory.
Successful cleanup now checks exact child exit, handle release and directory
removal. An original test failure retains its diagnosis if cleanup also fails.
