<!-- docs/audits/performance/ahk/2026_09_09/private_file_clone/report.md -->

# Checked file-backed reader clone experiment

## Decision

Keep the production memory-pager clone. A direct replacement with checked
backup into a private file substantially reduced process memory, but increased
clone latency in both sample groups. This does not justify a latency optimization
or prove a benefit for complete dashboard opening.

This experiment is distinct from direct serialization and contiguous memdb
allocation, whose correctness and growth failures are recorded separately.
It retains the existing `SQLite_BackupInto` primitive and never makes the
shared reader image writable.

## Provenance and method

- Measured source: `662f0cad08eff59c569227ecb7ae32d7d9699f94`.
- Windows, AutoHotkey 2.0.26, vendored SQLite 3.50.4.
- Window: 2026-09-09 16:28:44-16:30:39 UTC.
- Input: the existing 702390272-byte derived `reader.sqlite`, opened `OPEN_RO`.
  No journal was read or modified. Source size and modification time remained
  unchanged in every process.
- Four fresh hidden processes, strictly sequential: memory-01, file-01,
  file-02, memory-02. Each performs three clones. No other known heavy
  verification was active; the external Hammerspoon gate was observed terminal
  before starting. Desktop/browser activity was not controlled.
- Available physical memory was approximately 2.12 GiB before the first pair
  and 1.57 GiB before the second. Caches were not flushed. Every sample,
  including the first memory outlier, is retained below; there was no discarded
  warm-up sample or claim of a cold-storage benchmark.
- QPC measures candidate open plus complete checked backup. Schema/page-count
  comparisons and a private create/insert/rollback control follow the timer.
  Close and deletion are outside the timer. File candidates use SQLite's normal
  defaults; no journal/synchronization shortcuts were enabled.
- Each owned candidate is closed before deletion. Recovery companions would
  stop cleanup and preserve the file. All four runs exited zero and left no
  candidate directories. No private database or journal content is in this report.

## Results

| Process order | Mode | Three clone samples (ms) | Median (ms) |
| --- | --- | --- | --- |
| 1 | Memory-01 | 5144.489, 1900.091, 1941.152 | 1941.152 |
| 2 | File-01 | 4466.884, 3712.597, 4035.324 | 4035.324 |
| 3 | File-02 | 3254.342, 3087.450, 3293.812 | 3254.342 |
| 4 | Memory-02 | 1271.928, 1369.571, 1520.062 | 1369.571 |

Across the six samples per mode, the medians are 1710.077 ms for memory and
3503.205 ms for file. The maximum memory sample is 5144.489 ms; the maximum
file sample is 4466.884 ms. Six samples cannot establish tail percentiles or
attribute the first memory outlier to a specific cause.

| Process | Peak working set (bytes) | Peak commit (bytes) |
| --- | --- | --- |
| Memory-01 | 822857728 | 852127744 |
| File-01 | 20111360 | 8024064 |
| File-02 | 19677184 | 8093696 |
| Memory-02 | 823037952 | 852418560 |

These are process counters from `GetProcessMemoryInfo`, not total system memory
or filesystem-cache accounting. They establish a process-memory tradeoff, not
the amount of RAM the whole machine would recover.

## Limits and next decision boundary

The structural and rollback controls are not complete projection equivalence
or failure/concurrency coverage for a new architecture. This measures only
candidate creation: affected-day replay, manifest generation, persistence,
browser rendering, keystroke latency, CPU time, and complete opening remain
unmeasured here. No production source changed.

Do not introduce this as a direct speedup. A separately measured workload under
stronger memory pressure, or a design that also changes publication cost, could
justify reopening the tradeoff. Such a proposal still needs atomic offsets and
aggregates, resident isolation, failure handling, Windows file ownership, and
complete-output equivalence. Do not infer those properties from this benchmark.

## Reproduction artifacts

The owned campaign scratch is
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08`.
Set both `TEMP` and `TMP` there. Run `metrics-private-file-clone-bench.ahk`
with the hidden AutoHotkey executable, `/ErrorStdOut`, and either `memory` or
`file`, preserving the process order above. The script pins the worktree and
the local read-only source explicitly.

Harness SHA-256:
`E32C81FB4C98EE908CB04441EE7C98FA63A2BCB494A62701F2AE247D4919725B`.
Receipts are `metrics-private-clone-{memory,file}-{01,02}` with
`.out`, `.err`, and `.exit` suffixes. A setup warning about the harness's
global catch variable sharing a name with a library local was identical in all
four runs; it did not change the backup path or exit result.
