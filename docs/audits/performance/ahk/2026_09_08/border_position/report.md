<!-- docs/audits/performance/ahk/2026_09_08/border_position/report.md -->

# Pooled border same-position experiment

## Verdict

Do not ship the checked-RECT shortcut on this evidence. It reduces median
border-only preparation for unchanged positions, but does not establish a
complete-preparation gain and adds work to moving-position updates. The second
candidate run fails both existing 5 ms p95 budgets. This does not establish
that the shortcut caused every slow sample: desktop contention is uncontrolled.
Production is unchanged; no threshold was relaxed or failing run retried.

## Provenance and replay

Measured on Windows with AutoHotkey v2.0.26, using the existing private source
archive at `427e44588`, with the real native-coordinate oracle subsequently
committed as `fb0adfe4a`. The relevant production helper is identical between
those commits. The first 359 registered tests execute in each fresh process;
the two measured workloads each produce 100 observations per run.

Apply [probe.patch](probe.patch) to an isolated copy of `fb0adfe4a`, not an
active checkout. Patch applicability was checked with `git apply --check`.
It includes the earlier QPC wrapper and its support file: do not also apply
the previous thread-accounting patch. Set `ERGOPTI_TOOLTIP_THREAD_PROFILE=0`
for every run, and set `ERGOPTI_BORDER_POSITION_PROBE` to `0,1,1,0` in order.
Run `AutoHotkey64.exe /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk`
once per value from the isolated repository root. Do not use `/validate`.

The candidate queries the current native RECT and avoids SetWindowPos only
when both coordinates match. Both variants carry the added branch scaffold.
Query failure throws after attempting owner retirement; this experimental
failure path is not approved as production ownership handling. No position
cache is introduced. Native geometry assertions run outside measured intervals
for changing positions and complete preparation. Between-sample assertions can
affect scheduling, so older reports are not matched controls for this run.

| Run | Variant | UTC start, 2026-09-08 | PID | Exit | Prefix result |
| --- | --- | --- | ---: | ---: | --- |
| 1 | baseline | 18:07:26.3873104 | 16128 | 0 | 359/359 |
| 2 | candidate | 18:07:59.5012150 | 15896 | 0 | 359/359 |
| 3 | candidate | 18:08:33.1283630 | 17024 | 1 | 357/359 |
| 4 | baseline | 18:09:10.1902118 | 5640 | 0 | 359/359 |

TEMP/TMP used `D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08`.
Raw local receipts are `border-position-perf-run1.out` through `run4.out`, with
matching `.err` files. [samples.csv](samples.csv) retains all 400 paired rows
(800 workload observations); each row joins independent workloads by ordinal,
not simultaneous events. The parser required 100 ordered, finite, nonnegative
observations per workload and disabled CPU accounting in all runs.

No resident restart, priority adjustment, other-app trace or new source archive
was used. A process snapshot after the run showed another agent's verification
and the existing resident/UIA workers; their activity during individual samples
was not measured. The paths configuration was read and resolves runtime logs
under `D:/Documents/GitHub/config/ergopti_plus/autohotkey/logs/`; runtime logs
were not used to derive these measurements.

## Results

All values are elapsed QPC milliseconds, not exclusive CPU time. Each triplet
is median / p95 / maximum. Median averages the two middle sorted samples;
p95 is nearest-rank sample 95 of 100. Separate segment percentiles need not
belong to the same sample and must not be added.

| Run | Changing-position total | Changing-position build | Complete preparation | Complete border segment |
| --- | --- | --- | --- | --- |
| 1 baseline | 0.789 / 1.828 / 3.395 | 0.709 / 1.474 / 3.242 | 1.782 / 4.712 / 11.917 | 0.211 / 0.871 / 3.885 |
| 2 candidate | 1.073 / 3.134 / 5.470 | 0.936 / 3.044 / 5.389 | 1.690 / 4.741 / 13.729 | 0.148 / 0.259 / 3.538 |
| 3 candidate | 1.111 / 5.803 / 12.481 | 0.970 / 5.226 / 12.398 | 1.836 / 6.222 / 27.226 | 0.157 / 0.517 / 5.294 |
| 4 baseline | 0.877 / 3.354 / 13.054 | 0.770 / 3.262 / 12.817 | 1.684 / 4.954 / 10.666 | 0.192 / 0.701 / 6.351 |

Complete preparation excludes content GUI construction and retired-surface
disposal; it is not end-to-end keystroke latency. Its same-position border
segment has a lower median in both candidate runs, but the complete totals do
not consistently improve. Both moving-position candidate medians exceed both
baseline medians; their build segment includes the added allocation/query.
The experiment cannot separate that overhead from all external variation.

Run 3 fails test 358 at total p95 5.8031 ms and test 359 at 6.2224 ms. The latter
sample spends 6.003 ms in content positioning and 0.139 ms in border preparation.
Its maximum sample spends 26.992 ms in content positioning and 0.145 ms in the
border segment. Skipping redundant border movement does not explain or remove
these content-positioning stalls.

## Remaining work

Investigate content-positioning tail behavior with scoped native evidence.
Do not re-propose this shortcut without a changed mechanism or new matched
measurements that include genuinely moving positions. Keystroke end-to-end
latency, startup, idle CPU and long-session memory remain unmeasured by this
experiment. Passing these prefix tests is not a whole-driver correctness claim.
