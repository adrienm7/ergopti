# Scoped typing projection preparation

## Problem and change

At baseline `0aa281acc`, a date-scoped projection can use the date/app index
and sort the same source rows for every 128-row page. A native regression
observed nine sorts for a 1024-row, single-day fixture. The existing unscoped
composite cursor avoids prefix rescanning but does not eliminate this plan.

Scoped preparation now selects missing device/event keys once into an owned
MEMORY TEMP table. Pages seek through that table and join the immutable private
source by its complete primary key. The table contains identifiers, not decoded
payloads, and is removed on success or failure. Duplicate ownership is rejected;
cleanup failure rejects preparation. The unscoped path keeps its direct cursor.
No durable index, cache format, publication throttle, or source ledger changes.

## Evidence and method

Local Windows/AutoHotkey measurements use the installed SQLite library and
canonical schema, with synthetic data only. The native process is hidden and
waits for the other agent's verifier before starting. Three alternating paired
measurements compare the baseline function with the candidate, including key
selection, page writes, and cleanup. These are preparation timings, not dashboard
opening measurements. Other desktop activity can still affect wall-clock time.

The workload has three devices and seven apps. The dense case has 20000 events
on one day. The sparse database has 60000 events across 60 days, selecting either
one day (1000 events) or two distant days (2000 events). Each event contains one
manual and one synthetic character. Every pair checks numeric counts, replay
payloads, temporary table cleanup, and zero row writes on an unchanged repeat.

Native regression receipt `typing-scoped-work-before-01` fails on the baseline
with nine sorts. Receipt `typing-scoped-after-01` passes all five targeted tests,
including exact device/ID/payload associations, counts-only then replay admission,
late encrypted-payload failure preserving the durable image, and duplicate key
table ownership. The native observer requires at least eight actual page queries;
failure to observe the changed query shape cannot pass silently.

## Alternatives and limits

A durable `(date,device_id,id)` index improved dense page selection in an earlier
probe but added 610304 bytes to the dense image and 1871872 bytes to the sparse
image, plus measured build costs of 24.049 and 70.403 ms. It also increases what
future refreshes must clone. The temporary key list avoids that durable cost.
Its memory usage scales with pending scoped keys; the isolated dense prototype
observed 380544 additional SQLite allocator bytes for 20000 keys. This is not
total process RAM or a measurement on the user's historical image.

Scratch scripts and receipts are owned by this campaign under
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08`:
`typing-date-index-probe.ahk`, `typing-date-queue-probe.ahk`,
`typing-date-queue-full-probe.ahk`, and
`typing-date-queue-production-probe.ahk`. The production probe uses the current
implementation and checks exact payload equality in addition to cardinality.

## Final implementation measurement

`typing-date-queue-production-01` exited 0 with all equivalence and cleanup
checks passing. Milliseconds, baseline/candidate in paired order:

| Workload | Pair 1 | Pair 2 | Pair 3 |
| --- | --- | --- | --- |
| Dense day | 10940.852 / 7215.125 | 16622.595 / 7830.279 | 14832.977 / 8144.009 |
| Sparse day | 377.284 / 381.844 | 391.071 / 366.442 | 406.319 / 373.663 |
| Two distant days | 996.646 / 821.390 | 799.693 / 772.328 | 811.294 / 764.066 |

Maximum dense latency was 16622.595 ms baseline and 8144.009 ms candidate.
However, the other agent started a verifier at local 00:20:30 during this
measurement window; its Node process (PID 5452) and Lua child were confirmed
active at completion. These final wall-clock samples are load-contaminated and
do not establish a precise speedup. Do not relabel them as isolated measurements.

The preceding scratch-function probe, before that verifier, measured dense
baseline/candidate pairs of 10111.015/6793.392, 10462.968/7177.113, and
10544.779/6989.781 ms. It supported testing this mechanism, but does not replace
the production implementation's correctness and lifecycle checks. Sparse cases
do not establish a consistent improvement. The native sort regression provides
load-independent evidence that the repeated selection work was removed.
