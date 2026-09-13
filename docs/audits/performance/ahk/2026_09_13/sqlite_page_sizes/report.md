<!-- docs/audits/performance/ahk/2026_09_13/sqlite_page_sizes/report.md -->

# SQLite page-size feasibility probe

## Scope

Windows native AHK probe on 2026-09-13, using the vendored SQLite 3.50.4 and
production `SQLite_CloneMemory` at `535b49cc3`. No production behavior changed.
The initial synthetic probe opened no real journal or derived cache. The resident driver remained live;
other host activity was not controlled. One native probe ran at a time.

The [SQLite backup documentation](https://www.sqlite.org/backup.html) identifies
page-size mismatch as a possible refusal for in-memory destinations. Native
tests show that this implementation's newly opened destinations successfully
clone the tested source geometries. No compatibility fix is justified by this
experiment. Tests retain the page size, complete blob length and source/candidate
isolation through a subsequent update and insert.

## Synthetic measurement

Three private files each contain 32768 identical logical rows: integer primary
key plus a 1024-byte zero blob, totaling 33554432 payload bytes. Only page size
differs. Close each writer, reopen its file with OPEN_RO, then warm one clone.
Run the page-size sequence 4096/16384/65536/65536/16384/4096 three times,
sequentially, giving six measured clones per geometry. QPC timing surrounds
only `SQLite_CloneMemory`. Validate row count, total payload length and ID sum
after each timed clone, then close it before starting another.

| Page size (bytes) | File size (bytes) | Clone median (ms) | Clone max (ms) |
| ---: | ---: | ---: | ---: |
| 4096 | 44855296 | 107.613 | 121.798 |
| 16384 | 35864576 | 59.783 | 65.868 |
| 65536 | 34275328 | 50.462 | 55.588 |

Samples in milliseconds:

- 4096: 108.774, 106.451, 103.636, 116.896, 121.798, 103.918.
- 16384: 58.339, 58.888, 58.611, 62.617, 65.868, 60.677.
- 65536: 50.853, 55.588, 49.279, 50.071, 45.813, 52.800.

Reproduction: hidden `AutoHotkey64.exe /ErrorStdOut` launch of campaign scratch
`sqlite-page-size-probe.ahk`, with TEMP/TMP redirected to that scratch on D:.
Receipt: `sqlite-page-size-probe-01.out`, exit 0. The harness closes all owned
handles and deletes only its three synthetic files and empty private directory.

## Decision and remaining evidence

Larger pages reduced both file size and measured clone time for this workload.
The uniform blob rows are not representative of the full metrics schema or its
distribution of event and aggregate rows. These numbers do not measure opening
a dashboard, incremental recomputation, cache publication, RAM, CPU or a p99.

Keep the production page size unchanged. Before proposing a format change,
measure a private copy of a representative derived image, compare complete
logical contents, and exercise non-default page-size read failures, incremental
growth, cache restoration and publication. Preserve checked backup and readonly
source ownership; this is a separate investigation from the rejected mmap and
contiguous-buffer proposals.

## Representative derived-image experiment

On 2026-09-13, ending around 13:08 Europe/Paris, repeat the experiment using
production `SQLite_CloneMemory` at `7de8f7c04`. Open the existing derived image
with OPEN_RO and verify `sqlite3_db_readonly`. Make a checked backup into a
private baseline, then close the original. No source journal is opened or
modified. All subsequent work uses the private copies, retained only in campaign
scratch and excluded from repository artifacts.

Build 4096-, 16384- and 65536-byte variants with `PRAGMA page_size` and
`VACUUM INTO`, reopening each to verify its geometry. Include the vacuumed 4096
control to distinguish compaction from page size. SQLite documents the
[consistent logical copy produced by VACUUM INTO](https://www.sqlite.org/lang_vacuum.html).
Repacking takes 5282.594, 3862.573 and 3425.259 ms respectively; these are single
build observations, excluded from clone timings.

Compare each variant with the private baseline in both directions. All 48
non-internal tables and their schema definitions match. For every declared
column, compare its SQLite type and value with BINARY collation, grouping rows
and retaining their multiplicity before applying EXCEPT in both directions.
This checks nullable and duplicate rows without printing payloads. It does not
compare physical pages, implicit rowids or SQLite internal tables. File-backed
temporary storage bounds the comparison's memory demand.

Open all four private sources readonly, warm one clone per source, then run
baseline/4096/16384/65536/65536/16384/4096/baseline three times sequentially.
Close each clone before the next; time only the checked clone call with QPC.
Require available physical memory greater than twice the baseline file size
before every warm and measured clone. This guard is not a peak-memory measure.
The machine has about 6.94 GiB usable RAM; other host activity and the live
resident remain uncontrolled. No other suite or native probe runs concurrently
under this agent's ownership. Unlike the earlier synthetic probe, this timing
phase checks clone success but does not reread every cloned row; the exhaustive
logical comparison above covers the source variants.

| Source | File size (bytes) | Clone median (ms) | Clone max (ms) |
| --- | ---: | ---: | ---: |
| Original geometry backup | 702390272 | 1684.988 | 1785.124 |
| Vacuumed 4096 | 658853888 | 1684.428 | 4362.445 |
| Vacuumed 16384 | 652525568 | 1101.040 | 2801.071 |
| Vacuumed 65536 | 657260544 | 893.294 | 966.054 |

Six samples per source, in milliseconds:

- Baseline: 1700.110, 1785.124, 1669.865, 1739.446, 1643.691, 1659.323.
- 4096: 1547.845, 4362.445, 1672.566, 1720.523, 1648.768, 1696.289.
- 16384: 1113.396, 1062.019, 1145.954, 1005.196, 2801.071, 1088.684.
- 65536: 933.904, 822.691, 891.744, 894.843, 966.054, 827.921.

The 65536-byte variant reduces the observed median clone time by about 47%
against either baseline or the compacted 4096 control. Compaction alone does
not improve the median in this run. The 4096 and 16384 outliers are retained;
their cause is unverified. Six observations do not establish a p99, stability
under concurrent workload, or dashboard opening latency.

Reproduction: hidden `AutoHotkey64.exe /ErrorStdOut` launch of campaign scratch
`sqlite-real-page-size-probe.ahk`, sequential modes `build`, `compare`, `measure`,
with TEMP/TMP redirected to campaign scratch. Harness SHA-256:
`2373607ceaf13cd89652d24e2c91c3e10085fb1defa8dc38351abda891fdf304`.
Receipts `sqlite-real-page-size-build-01.out`,
`sqlite-real-page-size-compare-01.out` and
`sqlite-real-page-size-measure-01.out` all finish with exit 0 and empty stderr.

The representative-copy and logical-equivalence prerequisites are now met for
this image. Keep production geometry unchanged pending non-default page-size
read-refusal, incremental growth, cache restoration and publication tests,
plus end-to-end cost measurements. Conversion itself has a cost and must not
be added to every refresh. No production fix or complete-opening speedup is
claimed by this evidence-only update.
