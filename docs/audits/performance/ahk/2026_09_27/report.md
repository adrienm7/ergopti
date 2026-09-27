<!-- docs/audits/performance/ahk/2026_09_27/report.md -->

# Hidden surface preparation and native timing budget

## Outcome

Fix both tooltip and WPM preparation calls: `Gui.Show` accepts one show mode.
Combining `Hide NoActivate` selects a visible mode, consistent with the
[documented mutually exclusive show modes](https://www.autohotkey.com/docs/v2/lib/Gui.htm#Show). `Hide` alone materializes
and sizes the window without revealing it. The explicit presentation or typing
tick still owns the reveal. A minimal native probe returned `IsWindowVisible=1`
for the old options and `0` for the corrected options.

The tooltip regression now checks native visibility immediately after building
and after positioning, native geometry, and absence of activation. It failed
before the change on the first visibility assertion. The WPM geometry contract
also failed before removing the conflicting show mode. Transparent graph warmup
is retained; earlier comments incorrectly blamed `Hide` alone.

## Measurement provenance

AutoHotkey v2 on the maintainer's Windows desktop, 2026-09-27 UTC. The baseline
is an isolated archive of commit `742b20473`, never the live driver. The fixed
variant changes only the tooltip preparation show mode for measured workloads.
The additional visibility test has a different selector and is not timed.
Three fresh processes per variant each execute 100 real border updates and 100
complete preparation samples. No other repository suite ran concurrently.
Other desktop activity and scheduling were uncontrolled. These are sequential
baseline/fixed batches, not a randomized causal estimate of every timing change.

Run from an isolated checkout:

```powershell
AutoHotkey64.exe /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only "(tooltip-present-layered-reallocation)"
```

[profile.cjs](profile.cjs) instruments both existing QPC workloads after their
measured loops. Pass the isolated checkout root as its first argument. Set
`ERGOPTI_TBP_PROFILE` to a new CSV filename with header `workload,sample,ms` for
each process. [samples.csv](samples.csv) preserves every observation and
[receipts.txt](receipts.txt) records all six time windows and original exits.
The fixed runs were measured against the original 5 ms threshold; the third
failed. No timing failure is omitted or called green.

Preparation excludes content construction and disposal. Values are elapsed
QPC milliseconds, not CPU time or end-to-end keystroke latency. Percentiles use
nearest rank; the median below averages the two middle values.

| Variant/run | Workload | Median | p95 | p99 | Maximum |
| --- | --- | ---: | ---: | ---: | ---: |
| measure/1 | border | 0.490 | 0.902 | 1.196 | 1.286 |
| measure/1 | preparation | 1.645 | 6.891 | 27.293 | 30.226 |
| measure/2 | border | 0.803 | 1.620 | 4.017 | 5.091 |
| measure/2 | preparation | 3.438 | 50.394 | 52.367 | 68.482 |
| measure/3 | border | 0.486 | 0.873 | 1.206 | 2.056 |
| measure/3 | preparation | 1.460 | 31.726 | 48.554 | 150.131 |
| hidden-fixed/1 | border | 1.056 | 1.980 | 2.487 | 2.494 |
| hidden-fixed/1 | preparation | 1.068 | 2.267 | 3.252 | 5.134 |
| hidden-fixed/2 | border | 0.989 | 1.654 | 2.099 | 2.223 |
| hidden-fixed/2 | preparation | 1.306 | 4.231 | 9.428 | 10.801 |
| hidden-fixed/3 | border | 0.672 | 1.162 | 1.934 | 12.218 |
| hidden-fixed/3 | preparation | 1.047 | 7.277 | 10.363 | 11.072 |

## Budget decision and limits

Keep the 5 ms border-reuse p95 budget. At the user's explicit request to fix the
cause or adjust the threshold, use 25 ms for complete native preparation:
the isolated corrected three-run p95 range is 2.27-7.28 ms, but the subsequent
full-suite run reached 19.038 ms (maximum 153.315 ms), so neither 5 nor 10 ms is a stable
acceptance boundary on this desktop. The native visibility assertion separately
rejects the original defect deterministically; the 25 ms tripwire would also
reject two of the three old timing runs. The runtime hotpath warning threshold
is unchanged. This is a regression budget, not an input responsiveness promise.

The full-suite failing p95 sample spent 10.685 ms in border construction/reuse,
7.963 ms in native positioning, 0.328 ms in clamp and 0.062 ms in corners. Its
maximum spent 150.323 ms in the border segment. Desktop scheduling or contention
is a hypothesis, not proven exclusive attribution. A later OS snapshot showed
about 0.56 GiB free of 6.94 GiB RAM; it was not sampled at the exact stall.
The 25 ms boundary includes margin above the observed full-suite p95 rather
than calibrating only against focused tests. The large maximum is reported and
remains observable in the runtime profiler; a p95 gate does not bound maxima.

A later focused replay at the 25 ms boundary also failed under broad desktop
load: border p95 97.614 ms / max 142.589 ms; preparation p95 123.939 ms / max
278.932 ms. The subsequent system snapshot reported 95% CPU, about 121 MB/s
physical-disk reads and 4,339 page reads/s. Another repository's Node lint and
a resident metrics worker were active; none was stopped. These later snapshots
do not attribute individual samples to a specific process. This failed replay
is retained as environmental evidence, not discarded or used to raise the
threshold again. Full functional execution passed 6,862/6,863 tests, with only
the earlier 10 ms timing assertion failing; Windows engine E2E passed 5/5.

No CPU attribution, real typing, WPM latency, live-driver restart, OS priority
change or cache was measured or introduced. WPM shares the confirmed option
error; no WPM speedup is claimed. Border identity, native coordinates, bounded
allocation, GDI cleanup and pool-cap tests remain active.

A preliminary NOSENDCHANGING experiment was abandoned: both variants failed the
new hidden-state assertion before producing preparation samples. No performance
conclusion or production flag change was drawn from that experiment. The prior
same-position optimization rejection remains applicable.

## Final verification

A subsequent focused replay of the final thresholds passed all three native
workloads (exit 0), with the antivirus scan still running. The earlier loaded
failures remain documented above; this does not establish a maximum latency.
The full functional run passed the new native hidden-state regression and WPM
geometry contract. Windows engine E2E passed 5/5; the 260-check JS suite and
AHK encoding gate passed. The intentionally excluded live-driver startup smoke
remains assigned to CI, preserving the maintainer's running driver.
