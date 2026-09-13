# Selected-range JSON serialization

The range worker built every n-gram cell as an AHK Map and then encoded the
complete result. Complete snapshots already have a direct SQL JSON producer.
Use that existing producer for selected ranges as well.

## Evidence

Baseline revision: ee6dbd7dd. Measurement started 2026-09-13 21:31:13 local
on the shared Windows workstation, using the configured AutoHotkey v2 x64
runtime. One hidden native process; no concurrent verification was observed
at startup. The resident driver remained running. No private data was used.

Synthetic in-memory SQLite fixture: 59,904 rows, thirteen n-gram families,
two devices, three applications, three dates and 256 tokens per cell.
Selected application plus Unknown; captured current day 2030-01-02.

Compared these complete operations with QueryPerformanceCounter:

- Baseline: KL_JsonEncode(KLR_ReadRangeSplitToday(...)).
- Candidate: KLR_BuildRangeSplitTodayJson(...).

One pair warmed both paths, then four measured pairs alternated order.
Fixture creation and canonical JSON comparison were outside timing.
All ten outputs were canonically equal and each contained 465,380 UTF-8 bytes.

| Pair | Order | Baseline ms | Candidate ms |
| --- | --- | ---: | ---: |
| 1 | Candidate, baseline | 771.186 | 69.567 |
| 2 | Baseline, candidate | 752.545 | 71.675 |
| 3 | Candidate, baseline | 723.933 | 74.903 |
| 4 | Baseline, candidate | 715.408 | 71.584 |

Median: 738.239 ms baseline versus 71.630 ms candidate, about 90.3% lower.
Maximum: 771.186 versus 74.903 ms. This is one workload, not a general p99.
CPU consumption and peak memory were not measured. These values exclude DB
construction/restoration, worker startup, publication, WebView and rendering;
they do not establish complete dashboard opening latency.

## Validation and reproduction

The committed metrics-range-json-equivalence fixture independently checks
cardinalities and counts across all thirteen families, selected/Unknown apps,
two devices and three range boundaries. Existing historical JSON tests cover
auxiliary families, escaped tokens, source counters and row limits.
The worker source guard requires the direct complete serializer and rejects
the old Map-producing call. Ordinary Map-returning APIs remain available.

Local measurement harness and receipt are in the campaign scratch:
range-serialization-bench.ahk and range-serialization-bench-01.out.
The harness temporarily registered one selected test in run_all; that include
was removed after measurement. It does not run during ordinary verification.
Use --only=range-serialization-bench when explicitly replaying that harness.

Production change is limited to the selected-range worker's serializer call;
atomic publication and its failure path are unchanged.
