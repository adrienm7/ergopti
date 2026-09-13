<!-- docs/audits/performance/ahk/2026_09_13/sqlite_page_sizes/report.md -->

# SQLite page-size feasibility probe

## Scope

Windows native AHK probe on 2026-09-13, using the vendored SQLite 3.50.4 and
production `SQLite_CloneMemory` at `535b49cc3`. No production behavior changed.
No real journal or derived cache was opened. The resident driver remained live;
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
