# Snapshot composition experiment

Measured on Windows on 2026-09-09 against `c71f205a3` with the repository's
AHK parser, keylogger encoder and vendored SQLite wrapper. The input is
synthetic JSON containing unique token keys, count/error fields and escaped
quotes, backslashes and Unicode. No private metrics data was read.

One hidden native process ran three samples per size, with no concurrent local
suite. Desktop load was uncontrolled. QPC wall times include parsing/encoding
for AHK, and SQL quoting, preparation, execution and returned-text conversion
for SQLite. Input construction and result validation are excluded. Every output
was parsed afterward and required the original historical row count.

| Rows | UTF-8 bytes | AHK round-trip samples (ms) | SQLite samples (ms) |
| --- | --- | --- | --- |
| 1,000 | 64,961 | 170.882 / 170.010 / 164.815 | 1.710 / 1.518 / 1.596 |
| 10,000 | 658,962 | 1614.210 / 1693.451 / 1697.600 | 13.975 / 13.248 / 15.746 |
| 50,000 | 3,338,962 | 8776.844 / 9008.234 / 9124.138 | 70.012 / 63.287 / 70.519 |

The operation replaces `_prefetch_data.today` while retaining historical data.
AHK uses `JsonParse`, map replacement and `KL_JsonEncode`; SQLite uses
`json_set` with a JSON object replacement. This measures composition only:
disk reads/writes, history validity checks, cold ledger replay, page rendering,
CPU and peak RAM remain unmeasured. It is not an opening-latency result.

Reproduction script and terminal exit-0 receipt:
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08/metrics-snapshot-compose-bench.ahk`
and sibling `.out`. The script includes the real repository modules and owns
only an in-memory database. Isolated-wrapper warnings about absent logger
symbols did not execute; no SQL failure branch was exercised by this benchmark.

## Decision boundary

Do not introduce a full AHK decode/re-encode on each refresh. SQLite composition
is a viable candidate, not yet an implemented solution. Reusable snapshots need
store identity, day/schema provenance and invalidation when historical events
change. JSON validity alone cannot establish that old history is current.
Explicit full empty history must clear old values. Duplicate-key semantics and
corrupt-cache rejection need tests before using external cached JSON with SQLite.

An alternative is SQL-side serialization of historical aggregates directly from
the current reader database, avoiding reuse/invalidation of old history. Existing
today-only SQL serialization demonstrates the mechanism, but historical table
limits, ordering and schema must remain equivalent and its cost must be measured.
No production snapshot-retention change is included in this experiment.

## Direct historical serialization follow-up

The candidate serializes the same thirteen historical aggregate slots using
SQLite JSON aggregation instead of allocating per-token AHK maps and encoding
them afterward. The isolated script `metrics-historical-json-bench.ahk` in the
same scratch directory compares both paths and parses/canonically compares their
results outside the timed sections. Three sequential samples were taken per
workload; desktop load and filesystem cache state were not controlled.

| Workload | Output bytes | Legacy samples (ms) | SQL samples (ms) |
| --- | --- | --- | --- |
| Synthetic 50,000 words | 2,800,110 | 3198.459 / 3231.982 / 3251.421 | 142.131 / 138.579 / 138.588 |
| Real derived image, history through yesterday | 15,138,180 | 26166.980 / 27687.056 / 45410.472 | 2243.351 / 2313.867 / 2388.312 |

The real-data invocation adds `--real` and opens the existing derived
`metrics/cache/reader.sqlite` with `SQLiteConst.OPEN_RO`. The image was
702,390,272 bytes at inspection. It neither opens nor modifies `data.sql` and
does not export tokens: the receipt contains only timings and output sizes.
Receipts are `metrics-historical-json-bench.out` and
`metrics-historical-json-real.out`; both processes exited zero. This is not an
end-to-end opening measurement, nor a controlled CPU or peak-memory comparison.
The third legacy sample is materially slower and must not be omitted.

The full-projection candidate benefits from SQL serialization, but even its
2.24–2.39 seconds of historical serialization makes recomputing and sending all
history on every lightweight refresh inappropriate. The revised candidate keeps
the reusable complete snapshot separate from transient live/manifest stages.
Those stages are delivered synchronously to the current page and then deleted;
they must never replace the last complete snapshot. A reopened page can paint
that last complete snapshot before background refresh, without claiming it is
current. Historical invalidation and day rollover still require dedicated
scheduler coverage before this candidate can be considered complete.
