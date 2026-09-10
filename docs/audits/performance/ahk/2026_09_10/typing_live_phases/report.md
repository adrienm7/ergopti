<!-- docs/audits/performance/ahk/2026_09_10/typing_live_phases/report.md -->

# Current typing live projection phases

## Scope and provenance

Source revision: `b013547a7`. Two hidden native AHK probes call current
production functions against the existing derived SQLite image opened with
`OPEN_RO`. Image size is 702,390,272 bytes; its modification time stayed
2026-09-09 07:21:14 UTC. Neither probe reads or changes the source ledgers,
publishes the real cache, starts the resident driver or writes private JSON.
Receipts contain only timings, byte counts and process memory counters.

The image is historical; it was not rebuilt with current code. Every sample
uses its latest stored aggregate day as the live projection day, ensuring the
same workload rather than selecting an empty wall-clock day. The foreground
time contribution is disabled through an empty `KLHook.prev_app` in the harness.
No competing heavy verifier was observed before launch. Desktop load and
filesystem residency were uncontrolled. The two probes ran sequentially.
Receipt creation/last-write times bound them to 2026-09-10 05:11:00–05:12:12 UTC
and 05:13:12–05:13:34 UTC respectively.

Scripts and receipts are in the campaign scratch directory:

- `typing-live-current-phases.ahk`, `typing-live-current-phases-01.log`;
- `typing-live-projection-parts.ahk`, `typing-live-projection-parts-01.log`.

Both processes terminated with exit 0. QPC supplies elapsed time. Each probe
warms the projection once before three samples. The first probe retains the
readonly source, creates and closes one private memory clone per sample, calls
`KLPF_BuildTyping` in encoded live mode and composes its raw JSON fields at the
same object boundary as publication. Parsing and equality checks are outside
timing. All three cloned manifests and today buckets equal the source projection.
Keyboard layout metadata is produced by the real helper but excluded from the
equality check because the foreground layout is external state.

## Clone and live build

Readonly open took 2.614 ms. Available physical memory at admission was
1,246,793,728 bytes. The harness refuses to clone below its existing campaign
headroom threshold of 1.5 image sizes plus 128 MiB.

| Sample | Clone (ms) | Live build (ms) | Compose (ms) | Combined (ms) | Lifetime peak working set (bytes) |
| --- | --- | --- | --- | --- | --- |
| 1 | 2613.435 | 4485.190 | 16.880 | 7115.532 | 881967104 |
| 2 | 2772.597 | 5171.459 | 9.658 | 7953.738 | 898654208 |
| 3 | 3144.928 | 4592.045 | 10.257 | 7747.257 | 900034560 |

Combined median: 7747.257 ms; maximum: 7953.738 ms. Each payload is 1,951,775
UTF-8 bytes. Memory comes from `GetProcessMemoryInfo` after equality checks:
it is a cumulative process-lifetime peak, including warmup, retained expected
JSON and verification allocations. It is neither an isolated clone allocation
nor system-wide RAM usage. The source stays readonly throughout.

## Projection attribution

The second probe keeps only a readonly handle and times the actual manifest,
application-filter and today functions separately. Raw outputs equal the
corresponding fields from `KLPF_BuildTyping` in every sample.

| Sample | Manifest (ms) | Application filter (ms) | Today n-grams (ms) |
| --- | --- | --- | --- |
| 1 | 5046.222 | 4.464 | 31.847 |
| 2 | 5554.575 | 5.371 | 27.698 |
| 3 | 5398.676 | 3.970 | 27.156 |

Manifest median/max: 5398.676/5554.575 ms. Today median/max: 27.698/31.847 ms.
Manifest output is 1,925,898 UTF-8 bytes; today output is 25,290 bytes.
The readonly and memory-clone samples are different workloads and times:
do not subtract across these tables to infer storage or allocation costs.

## Decision and limits

These isolated phases already take seconds, so immediate refresh is not
demonstrated. The manifest dominates today's n-grams on this stored day;
profile its base-cell, encoded-series and final assembly components next.
Keep the checked private clone until a measured alternative preserves failure
isolation, aggregate/offset atomicity, worker concurrency and resident ownership.
Existing rejected serialization and file-clone experiments remain applicable.
Final JSON composition is small in these samples and is not the next priority.

No production optimization is proposed or claimed by this report. Comparing
these absolute times with earlier experiments cannot establish a regression:
load, memory pressure, selected day and warmed pages differ. Three samples do
not estimate p95 or p99. Unmeasured work includes cache admission, actual ledger
tails, decryption, aggregate recomputation, durable publication, process startup,
browser rendering and complete opening. Keystroke latency, critical spans,
tooltip behavior, startup readiness and long-lived memory growth were not
exercised. The results do not prove any module free of defects.
