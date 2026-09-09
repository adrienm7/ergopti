<!-- docs/audits/performance/ahk/2026_09_09/typing_projection_cursor/report.md -->

# Typing projection cursor

## Reproduction

Baseline: `e581fb522`. The paged projection orders raw events by device and
event ID. Its OR-based continuation predicate lets SQLite bound the primary
index by device, but repeatedly visits earlier IDs of that device.

`typing-cursor-probe-01` used the canonical schema and 20,000 synthetic rows in
memory. Three alternating pairs at each cursor position returned identical
128-row pages. At ID 19,000 the baseline executed 156,492 SQLite VM operations;
the row-value predicate executed 4,632. Query plans respectively bounded
`device_id` and `(device_id,id)`. Page times were 15.157/8.102,
13.977/6.001 and 15.153/5.752 ms (baseline/candidate).

The production regression observes completed projection statements through
[SQLite's trace callback](https://www.sqlite.org/c3ref/c_trace.html) and counts
[VM operations](https://www.sqlite.org/c3ref/c_stmtstatus_counter.html). It
requires multiple observed pages, complete output and bounded later-page work.
`typing-page-work-before-01` failed on the original implementation: first page
3,721 operations, maximum 11,660, exceeding the two-times allowance.
The test does not depend on wall-clock speed or an exact query-plan string.

## Complete projection measurement

`typing-cursor-full-probe-01` compared the baseline function extracted from Git
with the candidate production function. Each run prepared counts and ordered
payloads for all 20,000 rows, with derived tables cleared before timing. All
counts and payloads were checked after each run. Payloads were empty arrays;
this excludes encryption cost and realistic per-event JSON complexity.

| Scope | Pair | Baseline ms | Candidate ms |
| --- | --- | ---: | ---: |
| All dates | 1 | 3348.195 | 3220.478 |
| All dates | 2 | 3576.944 | 3300.132 |
| All dates | 3 | 3603.098 | 3358.731 |
| One date | 1 | 6219.679 | 6157.337 |
| One date | 2 | 6477.611 | 6307.528 |
| One date | 3 | 6644.361 | 6276.837 |

Candidate ran first in the second pair of each scope. The unscoped projection
saved 128–277 ms in these samples; the date-scoped projection saved 62–368 ms.
Three pairs do not establish a latency distribution or a universal speedup.

## Limits and decision

Replace only the continuation predicate with a lexicographic row-value bound.
The existing ordering, joins, date scope and private-candidate publication
remain intact. Behavioral tests cover restarted IDs, distinct devices, date
exclusions, cached counts, payload admission and failure after a committed page.

The date-scoped probe used the date index and a temporary ordering tree, so
it did not gain a direct composite seek: at ID 19,000 VM operations increased
from 208,783 to 247,783 despite similar page times. Do not force the primary
index without measuring sparse historical date selections. Complete scoped
projection samples showed no regression, but that query plan remains a
separate performance investigation.

The hidden probes ran sequentially after other verification finished. Initial
available RAM was 3,425,928 KiB; CPU and peak memory were not measured. Receipts
and harnesses reside in the campaign scratch on D:. No private journal or
production SQLite image was opened. These measurements cover typing payload
preparation, not aggregate replay, cloning, manifest publication or UI opening.
