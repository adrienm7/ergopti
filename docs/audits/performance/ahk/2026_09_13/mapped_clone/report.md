<!-- docs/audits/performance/ahk/2026_09_13/mapped_clone/report.md -->

# Read-only mapped source clone investigation

## Decision

Keep production mapped reads disabled. Mapping the read-only source reduced
checked memory-clone latency in this experiment, but changed native read-refusal
behavior. This is a promising phase measurement, not a validated replacement
for the existing I/O contract or a measurement of dashboard opening.

## Provenance

- Source commit: `17e7255c7` (Windows code unchanged during the experiment).
- Windows, AutoHotkey v2, existing vendored SQLite through `SQLite_Open` and
  `SQLite_CloneMemory`. Every real source handle used `OPEN_RO`, with native
  `sqlite3_db_readonly` asserted before cloning.
- Existing derived image: 702,390,272 bytes, modification time unchanged since
  2026-09-09. No raw journal read, source mutation, or private payload export.
- First process: 2026-09-12 23:59:25–23:59:33 UTC. Second fresh process:
  2026-09-13 00:00:29–00:00:36 UTC. Runs were sequential and hidden.
- Before the first comparison, free physical memory was 2,427,640 KiB out of
  7,274,124 KiB. Resident AHK PIDs 12668/13436 remained untouched. No owned
  verifier was active; observed Node command classifications did not identify
  another test/benchmark. External desktop load was uncontrolled.
- Filesystem caches were not flushed. A prior page-occupancy scan read this
  same image, so these are explicitly warm-cache observations. No sample was
  discarded. Per-process peak RAM and full opening latency were not measured.

## Image occupancy

The read-only metadata probe returned 171,482 pages of 4,096 bytes and zero
freelist pages. A freelist purge therefore cannot reduce this image.
`dbstat` reported 613,251,375 payload bytes and 52,963,479 unused bytes within
allocated pages. In-page slack is not a freelist and does not establish the
benefit or cost of a compaction strategy. Baseline `mmap_size` was zero.

## Clone measurements

Each sample opens a fresh read-only source connection and sets either zero or
1,073,741,824 mapped bytes. The effective pragma value is checked. QPC times
only the production `SQLite_CloneMemory` call, including destination open and
checked backup. Source open/settings, page/schema-count checks, private
create/insert/rollback control and handle close are outside the timed interval.
Those controls establish basic structure and private mutation, not full output
equivalence under faults or worker concurrency.

| Process | Sample | Mapped bytes | Clone ms |
| --- | --- | --- | --- |
| 1 | 1 | 0 | 1217.353 |
| 1 | 2 | 1073741824 | 742.700 |
| 1 | 3 | 1073741824 | 816.527 |
| 1 | 4 | 0 | 1661.072 |
| 1 | 5 | 0 | 1517.904 |
| 1 | 6 | 1073741824 | 980.919 |
| 2 | 1 | 1073741824 | 737.565 |
| 2 | 2 | 0 | 1140.557 |
| 2 | 3 | 0 | 1162.784 |
| 2 | 4 | 1073741824 | 724.898 |
| 2 | 5 | 1073741824 | 717.661 |
| 2 | 6 | 0 | 1127.970 |

Six samples per mode: medians 1190.069 ms without mapping and 740.133 ms with
mapping, a difference of 449.936 ms (37.8%). Maxima were 1661.072 ms and
980.919 ms. The groups show desktop/process variation; these are not p95/p99
estimates, keystroke timings, cold-storage results or end-to-end savings.

## Native refusal observation

An independent synthetic SQLite file contains one 32,768-byte zero BLOB.
An exclusive `LockFileEx` lock covers its last page while each read-only source
is cloned. No real image or journal is locked. Both runs observed:

| Source mode | Clone during lock | Payload length |
| --- | --- | --- |
| ordinary reads | refused (zero handle) | unavailable |
| mapped reads | succeeded | 32768 |

Unlocked controls subsequently succeeded. Mapping bypassed this read-refusal
mechanism; the observed mapped output was correct, so this is not evidence of
corruption or lost bytes. It does mean that existing checked-read fault evidence
cannot simply be transferred to the mapped path.

[SQLite's mapped-I/O documentation](https://www.sqlite.org/mmap.html) also
describes a different failure model: mapped-file I/O errors can terminate the
process rather than return through SQLite's normal error handling. Before any
adoption, establish fail-closed parent publication, source replacement and
concurrent worker behavior with faults appropriate to that access mechanism.
Do not weaken the ordinary-read regression assertions to claim equivalence.

## Local receipts and scope

Campaign scratch: `D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08`.

- `metrics-page-layout-probe.ahk` / `metrics-page-layout-probe-01.out`.
- `metrics-mmap-clone-probe.ahk` / `metrics-mmap-clone-probe-01.out` and `-02.out`;
  the second process passes `reverse` to invert sample order.
- `metrics-mmap-lock-probe.ahk` / `metrics-mmap-lock-probe-01.out` and `-02.out`.
  The final script moves exit after fixture cleanup. The first run's confirmed
  empty owned directory was removed separately; no global Temp sweep occurred.

All probes exited zero. Minimal standalone SQLite includes emitted warnings for
unused logger dependencies; no probe error or runtime driver warning is claimed.
Production behavior and resident processes were unchanged. The broader remaining
manifest, range, JSON transfer and display costs are unmeasured in this pass.

## Follow-up: publication with an active SQLite reader

At Windows source commit `782b198ea`, a small synthetic replacement probe used
the production `FSAtomicMoveReplace` with independent SQLite connections in one
hidden process. Ordinary and 1 GiB mapped readers both refused replacement while
open (`MoveFileExW` error 5). The old reader and its memory clone retained the
first generation's payload and offset. Closing the reader allowed replacement;
a fresh connection then observed the second generation. Receipt:
`metrics-mmap-replace-probe-01.out` in the campaign scratch.

Permanent coverage now exercises `KLR_CacheSave` with both reader modes in
`tests/unit/test_klr_cache_publication_order.ahk`. The existing exclusive-file
case remains. The two added cases force native replacement refusal, assert its
diagnostic, compare app-day, hourly, character-class and n-gram fixture values
in the retained reader and clone,
check the clone's consumed offset, and verify staging cleanup. Closing the
reader permits publication of the unchanged newer candidate with its new
offset and rows. All three targeted cases passed in
`metrics-reader-replace-native-01.out` (process exit 0).

This adds regression coverage without a production correction: the existing
publication behavior met these assertions. The fixture uses independent handles
in one process; it does not establish cross-process worker fault containment or
safe recovery from a mapped I/O exception. Production mapped reads stay disabled.
