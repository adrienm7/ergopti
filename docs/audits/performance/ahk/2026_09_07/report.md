<!-- docs/audits/performance/ahk/2026_09_07/report.md -->

# AHK performance evidence

This is an initial measurement inventory, not a completed performance audit.
No optimization is justified solely by these aggregate maxima.

## Provenance

The runtime `%APPDATA%/Ergopti/paths.toml` resolves `ConfigDirPath` to
`D:/Documents/GitHub/config/ergopti_plus/`. Read only the primary log
`autohotkey/logs/ErgoptiPlus_2026-09-06.log`; exclude the errors-only mirror.
The source revision and foreground workload of this historical runtime have
not been established, so these are triage data, not the worktree's benchmark.

Extract `Slow ([\w.]+): ([\d.]+) ms` from each line and aggregate count and
maximum by segment. The default profiler threshold is 5 ms; UIA.SelectionPoll
uses 60 ms. The censored log population cannot supply all-keystroke percentiles.

| Segment              | Logged samples | Maximum ms |
| -------------------- | -------------: | ---------: |
| Config.TomlWrite     |              6 |    1196.85 |
| UIA.SelectionPoll    |              1 |     218.99 |
| RemapEmit            |             23 |     113.29 |
| Metrics.FocusRefresh |             19 |      94.38 |
| Tooltip.Build        |             67 |      92.41 |
| KL.Ingest            |              3 |      51.05 |
| OnChar               |             23 |      41.32 |
| HSE.Dispatch         |             11 |      40.06 |
| Tooltip.Present      |             43 |      28.54 |
| Hook.KeyUp           |              1 |      26.09 |
| Hook.KeyDown         |             10 |      23.39 |
| HSE.FeedChar         |              3 |      13.83 |

Line timestamps establish that the 41.32 ms OnChar event occurred on September
6 at 18:16:43.937, with 1.26 ms exclusive and 40.06 ms nested. Do not sum it with
the nested dispatch. The 1196.85 ms TOML write occurred at 19:18:33.815, with
1039.22 ms exclusive and 157.63 ms nested. The 113.29 ms RemapEmit occurred at
19:18:32.915.

## Remaining work

Reproduce tail events with a known source revision and controlled workload.
Attribute the TOML write's staging, verification, flush, and publication costs
before changing its durability contract. Keyboard, tooltip, startup, and idle
budgets remain unverified. No before/after performance improvement is claimed.
