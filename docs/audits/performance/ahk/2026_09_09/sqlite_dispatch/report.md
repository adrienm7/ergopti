<!-- docs/audits/performance/ahk/2026_09_09/sqlite_dispatch/report.md -->

# Per-read SQLite dispatch ownership

## Mechanism

Both row readers previously resolved native procedure names for every step and
column conversion. Each read now retains its own DLL reference and resolves
five hot-loop addresses once. A finally block finalizes the statement before
releasing the reference, including preparation failures and consumer throws.
There is no global address cache or changed database persistence policy.

This also closes a statement leak when a streaming consumer throws a non-Error
value: the previous Error-only catch bypassed finalization. Error objects retain
the existing failure-map contract; arbitrary thrown values still propagate.

## Measurement provenance

Hidden AutoHotkey v2 processes ran on the maintainer's Windows machine on
2026-09-09. QPC measured elapsed time. The resident driver remained active;
desktop load and OS cache state were uncontrolled. Probes live in the owned
`ergopti-ahk-verification-temp-2026-09-08` scratch directory. Commands use
`AutoHotkey64.exe /ErrorStdOut <probe>.ahk`, captured streams, and checked native
exit codes. Private SQLite inputs were opened read-only; no journal or cache
was modified and no private result payload was exported.

The baseline reader is from `e637f7231`. Before production changes,
`probe-sqlite-dispatch.ahk` measured 100,000 integer-column calls in ABBA order:
named, address, address, named. Every checksum was 700,000. Elapsed times were
1211.279, 77.404, 75.878, and 1229.535 ms. This microbenchmark ran during a JS
gate and does not measure full query or dashboard latency.

`probe-sqlite-query.ahk` compared the production reader and an isolated candidate
against the actual five-minute aggregate query, including JSON grouping and
source-row multiplicity. All 5,653 returned rows were encoded and compared for
exact equality in memory. An additional run checked integer extremes, floats,
NULL, UTF-8, existing BLOB text conversion, and empty results.

| ABBA run | Original (ms) | Candidate (ms) | Candidate (ms) | Original (ms) |
| --- | ---: | ---: | ---: | ---: |
| First | 1261.668 | 214.601 | 202.304 | 1093.419 |
| Additional type vectors | 1215.572 | 186.295 | 196.044 | 1157.488 |

Receipts: `sqlite-dispatch-1`, `sqlite-query-candidate-1`, and
`sqlite-query-candidate-2`; all exited zero. The isolated candidate did not
exercise yield callbacks; production regression tests cover those separately.

## Production manifest measurement

`probe-manifest-phases.ahk` times the real manifest projection and JSON encoding
on the same legacy image. Its output has 1,811,993 characters. The image's age
means this is performance evidence, not proof of current aggregate freshness.

Immediately preceding production samples with the JSON fast path already
installed measured projection at 5509.300 and 4178.048 ms
(`json-production-after-1` and `json-production-after-2`). The first sample
after native dispatch changes measured 1403.500 ms for projection and
890.300 ms for encoding (`sqlite-production-after-1`, native exit zero).
A second sample during the JS gate measured 2480.391 ms projection and
1747.004 ms encoding (`sqlite-production-after-2`, native exit zero). The
observed maximum projection falls from 5509.300 to 2480.391 ms, but concurrent
load makes these end-to-end samples less controlled than the paired query
experiment above.

These small sequential samples do not establish p99, OS-cold performance, or
complete UI first paint. Database attachment, journal refresh, IPC, and rendering
are outside this measurement. Keystroke deadlines, tooltip rendering, startup,
and idle CPU are also unmeasured; no budget verdict is claimed for them.

## Regression verification

Four native cases under `sqlite-read-dispatch` cover typed decoding, repeated
and nested readers, early stop, Error and non-Error throws, malformed/empty SQL,
step errors, interruption, and subsequent database reuse. Native
`sqlite3_next_stmt` checks statement ownership rather than source structure.
All four focused cases passed. An isolated wrapper extracted from the baseline
commit with `git archive` passes three cases and fails the exceptional-consumer
case: `sqlite3_next_stmt` returns a live statement instead of zero. The probe
exits one (`sqlite-dispatch-baseline/red-2.out`), establishing root-cause RED
without replacing files in any active checkout. The test fixture cleans leaked
statements even
on assertion failure, preventing contamination of later cases.

Partial export-resolution failures and native FreeLibrary failures are not
injected. Cleanup ordering is explicit in finally blocks. Timing thresholds
are deliberately absent from correctness tests; the recorded baseline proves
the performance problem without a desktop-dependent false-green threshold.

Selected native gates in `sqlite-dispatch-gates.log` completed with exit zero:
5,808 AHK tests, full include-graph parsing, encoding, and five pure E2E tests.
The report additionally selects the JS gate, recorded separately in
`sqlite-dispatch-js.log`; its terminal result must be checked before delivery.
