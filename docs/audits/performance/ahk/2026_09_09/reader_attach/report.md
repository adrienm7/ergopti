<!-- docs/audits/performance/ahk/2026_09_09/reader_attach/report.md -->

# Read-only metrics image admission

## Scope and result

Disposable projection workers now retain a validated SQLite image read-only
instead of copying every page into memory before answering unchanged requests.
Resident callers still receive a private writable copy. New ledger bytes trigger
a private writable candidate; failed refreshes cannot publish partial aggregates.
This removes unnecessary admission work, not the entire dashboard startup cost.

## Measurement provenance

Measured on the maintainer's Windows machine on 2026-09-09 at 00:35 local time,
against the existing 685,060,096-byte private reader image. The journal and image
were never opened for writing by the probe. No private records were exported.
The resident driver and its UI Automation workers remained running. OS page-cache
state was uncontrolled; these are not cold-boot measurements.

Each sample used a fresh hidden AutoHotkey v2 process and the production SQLite
wrapper, filesystem adapter, reader state, and cache admission implementation.
The probe read the stored format version first and used it only for admission:
this legacy image is suitable for measuring page-copy cost, not evidence of
current aggregate correctness. Cache rejection was replaced by a throwing guard
in an isolated module copy so the benchmark could never discard the private
image. Debug logging was disabled. A nonzero aggregate row count was checked
before and after admission. Copy mode required physical-memory headroom of
1.5 times the image size plus 128 MiB.

Command: `AutoHotkey64.exe /ErrorStdOut probe-reader-attach.ahk <mode>`.
The scratch probe and receipts are under the owned
`ergopti-ahk-verification-temp-2026-09-08` directory. Receipt prefix:
`attach-20260909-003505-`. All six processes exited zero. The probe's top-level
catch variable produced two name-shadowing warnings; these did not originate
from execution of the measured admission path.

Modes alternated read-only/copy three times. Copy mode selects the retained
resident copy implementation, equivalent to the previous worker admission
mechanism. QPC surrounds the actual `KLR_CacheAttach` call, including validation.
Peak working set is the native process lifetime peak, not total system memory.

| Sample | Copy admission (ms) | Read-only admission (ms) |
| --- | ---: | ---: |
| 1 | 1188.8583 | 3.9900 |
| 2 | 1251.7872 | 3.5490 |
| 3 | 1258.1895 | 3.8162 |
| Median | 1251.7872 | 3.8162 |
| Maximum | 1258.1895 | 3.9900 |

Copy peak working sets were 803,667,968; 803,667,968; and 803,639,296 bytes.
Read-only peaks were 16,838,656; 16,830,464; and 16,842,752 bytes.
Three samples establish a clear admission improvement, not a credible p99.

## Regression evidence and risks

The stable `klr-readonly-image` test group uses the real SQLite DLL and covers:

- Native read-only worker admission and unchanged-handle reuse.
- Private writable resident admission.
- Appended data switching to a writable candidate with cold-build equivalence.
- Reset releasing the image handle.
- Windows publication locks preserving the last-good image, followed by
  successful publication after the reader closes.
- Rejection of read-only worker state becoming resident-owned.

Recorded pre-fix run failed the worker's native read-only assertion (expected
1, observed 0), while the resident control passed. The final focused run passed
all four cases. `node tools/test/verify-change.cjs` exited zero: encoding,
5,799/5,799 AHK tests with complete execution manifest, entry compilation, and
5/5 pure E2E cases. Receipts: `reader-ro-red`, `reader-ro-green2`, and
`reader-ro-verify.log` in the same scratch directory.

## Remaining work and rejected shortcuts

The image remains atomically published, not mutated in place. Simply wrapping
the existing replay in an outer transaction is unsafe: replay and projection
already contain transaction boundaries. Read-write WAL admission and offset
commit redesign remain separate work; this change does not claim to deliver
them. Incremental refresh still copies the image and replays affected days.

Manifest projection, JSON encoding, whole-dashboard first paint, cold rebuild,
keystroke latency, low-level hooks, Critical spans, tooltips, and idle behavior
were not measured by this experiment. No budget verdict is asserted for those
paths. Native macOS and Linux benchmark receipts belong to their distinct
workloads and cannot establish Windows end-to-end latency.
