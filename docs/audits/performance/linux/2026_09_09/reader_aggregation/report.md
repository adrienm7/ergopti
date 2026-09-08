<!-- docs/audits/performance/linux/2026_09_09/reader_aggregation/report.md -->

# Native Linux metrics aggregation

## Result and remaining budget

Grouping repeated n-gram rows in SQLite before JSON transport reduces the large
synthetic range query from about 82 seconds to 8.3 seconds. This is not instant
dashboard opening. Disk snapshot presentation and asynchronous refresh remain
unimplemented by this change; WebKit painting was not measured.

The previous reader transported each date/device/app row and decoded it in Lua.
The candidate groups numeric rows by token and identical source JSON (plus app
for today's split). It multiplies source counts by group size. Anomalous numeric
text remains ungrouped because SQLite coercion differs from Lua's `tonumber`.
`TOTAL` avoids integer overflow in the grouping operation. No new cache or
invalidation protocol is introduced.

## Provenance and reproducibility

Both versions ran on GitHub-hosted Ubuntu 24.04 with native LuaJIT and SQLite
3.45.1. Each job generated an isolated synthetic database with the repository's
real schema, then executed the real reader and bridge using synthetic keylogger
composition. No private data was uploaded. The benchmark does not include the
resident daemon cache, live deltas, raw-event replay, or UI painting.

Command: `python3 tools/bench/linux-metrics-reader.py --days 365 --apps 4
--events 512 --output linux-metrics-evidence.json` (one command line).
The fixture has 6,727,680 queried n-gram rows across nine tables and occupies
1,119,236,096 bytes in both runs. The subprocess has a 600-second deadline and
the workflow a 2-GiB virtual-memory limit for this measurement.

- Baseline: commit `40f03ee3e`, successful Actions run
  [34284703067](https://github.com/adrienm7/ergopti/actions/runs/34284703067).
- Candidate: commit `86c3f0788`, successful Actions run
  [34287549069](https://github.com/adrienm7/ergopti/actions/runs/34287549069).

These are separate hosted machines, not a paired same-host experiment. The
workload and SQLite version match; OS page-cache state was uncontrolled. There
are two range samples per run, insufficient to estimate p99.

| Phase | Baseline (ms) | Candidate (ms) |
| --- | ---: | ---: |
| Range, first | 81599.835 | 8268.570 |
| Range, second | 82035.672 | 8296.066 |
| Composed ready, first | 82025.333 | 8647.766 |
| Composed ready, second | 82926.774 | 8688.705 |
| One-app filtered range | 20209.297 | 3777.418 |

Native child peak RSS: 751,648 KiB before, 75,940 KiB after. Both probes issued
108 SQLite CLI calls. The reduction comes from less row transport and Lua work,
not fewer processes. Large-range maximum improved from 82,035.672 ms to
8,296.066 ms; composed-ready maximum remains 8,688.705 ms and misses an instant
opening objective.

The small control fixture contains 3,024 rows and occupies 1,134,592 bytes.
Baseline run34284589327 ranges were 77.049/75.726 ms; candidate run34287453471
ranges were 63.707/62.255 ms. Small-run peak RSS was 17,048/16,744 KiB.
The small result alone would have understated the large-store problem.

## Regression coverage

`python3 tools/test/test-linux-metrics-aggregation-native.py` uses real SQLite
and the complete production projection envelope, comparing grouped SQL with
the previous raw-row queries through the same Lua merge implementation.
It covers all nine tables, historical/today and app/date filters, multiple
devices, malformed and equivalent JSON spellings, fractional source counts,
integer-overflow inputs, malformed numeric text, and empty ranges.

The native fixture reports 648 transported rows versus 2,808 for raw queries,
with equal envelopes (relative tolerance for floating accumulation). It requires
a nonempty semantic control and strictly fewer rows; the original ungrouped
reader cannot satisfy the row-reduction assertion. A separate original-source
RED execution was not recorded; the actual baseline benchmark is retained above.

Candidate run34287453471 passed native equivalence, 2,230 Linux unit tests,
100 pure E2E assertions, and the native macOS measurement. The large run also
completed successfully. Local Python compilation and Lua parse checks passed;
223 JavaScript checks passed before commit. Linux native gates ran remotely,
not on the Windows host. Rebasing for local integration preserved the verified
Linux source tree; the local fix commit is `b74adfcef`.

## Next work and limits

Measure and implement two-stage UI presentation with explicit stale-result and
failure ownership. Investigate the remaining SQL scan/group cost before adding
indexes or persistent view caches. This result does not establish input-device,
keyboard, startup, idle CPU, or WebKit rendering behavior on real Linux hardware.
It does not decide the shared cross-OS projection storage location.
