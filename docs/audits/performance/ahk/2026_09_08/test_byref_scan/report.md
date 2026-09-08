<!-- docs/audits/performance/ahk/2026_09_08/test_byref_scan/report.md -->

# ByRef test source traversal

Date: 2026-09-08. Baseline commit:
`74587a7cd9cb2b1fd01be0a3ccc42f90f624e630`.
Scope: the Windows test suite, not resident typing latency.

## Result

Replacing one complete source search per ByRef function with one identifier
traversal reduced the measured scan from 29.4–32.4 seconds to 1.51–1.55 seconds.
The candidate indexes parameter positions only; it adds no source-text cache.
This result applies to this test, not to the entire suite.

## Discovery and provenance

A private source archive was reused on D: to avoid another large temporary copy.
It contains the pending Windows TOML fix and is not a pristine baseline checkout.
The source text was unchanged between compared variants. A native AHK v2.0.26
runner selected 572 tests using the existing `meta` name filter. QPC measurements
around callbacks totaled 87.535 seconds. Process elapsed time was 103.109 seconds
and process CPU time 93.344 seconds.

The ByRef assertion took 28.590 seconds, making it the largest measured callback.
The next two callbacks took 4.427 and 4.060 seconds. This selection is not an
exhaustive inventory of source tests. The partial archive lacked files required
by two cross-driver coverage checks: 570 passed and two failed. These results
were profiling evidence, not a successful acceptance gate.

## Matched comparison

The original loop was extracted from the baseline Git version of
`tests/meta/test_byref_call_sites.ahk`. The candidate was the actual changed
`_BRC_FindViolations` helper. Both consumed the same already-loaded,
comment-stripped source: 3,198,704 UTF-16 characters and 83 ByRef definitions.
Source loading and definition discovery were outside the measured intervals.

The native process ran a fixed baseline/candidate/candidate/baseline sequence.
Each call returned zero violations for that same driver source. QPC surrounded
the call only; assertions and output followed it.

| Order | Variant   | Elapsed milliseconds |
| ----- | --------- | -------------------: |
| 1     | Baseline  |           29424.6375 |
| 2     | Candidate |            1549.9513 |
| 3     | Candidate |            1514.6853 |
| 4     | Baseline  |           32383.5640 |

The process exited zero. Local receipts are `byref-paired-cost.out` and
`byref-paired-cost.err` in the dedicated 2026-09-08 verification scratch directory;
`byref-paired-cost.ahk` contains the extracted baseline and measurement loop.
Desktop workload was uncontrolled. Two observations per variant establish a
large local gain but do not estimate reliable p95 or p99 behavior.

To repeat: obtain the old per-definition scan from the named baseline, retain it
as a separate callable returning its violation list, and invoke it and the new
helper with one shared source/definition pair in the order above. Do not include
source loading in one variant but exclude it from the other.

## Regression coverage

The new native regression initially failed because successive regex searches
restarted at the beginning for each definition. The candidate keeps a strictly
advancing cursor. The same fixture asserts the three exact violations from
ordinary and nested calls, while excluding unrelated methods, longer names,
historical case mismatches and omitted optional arguments. Matching parameter
positions and the original whole-driver assertion remain in place.

The new scanner retains the opening parenthesis as the next search position so
an immediately nested call is not skipped. Diagnostic ordering now follows call
order rather than definition order; the set of required checks is not reduced.

## Memory, limitations and rejected shortcuts

The post-exit process memory API returned zero, which is unusable evidence.
No working-set reduction is claimed. The candidate's additional index contains
83 names and references to parameter-position arrays for this workload; its
allocation size was not measured. No parent/child source snapshots are retained.

Earlier directory-read probes measured repeated I/O, but caching those texts
would duplicate overlapping parent/child contents. That cache was not implemented;
the much larger ByRef traversal cost was addressed first.

Full-suite elapsed-time improvement, startup memory, remaining slow tests,
interactive desktop interference and resident-driver performance are outside
this matched comparison. No test was removed or relaxed for the timing result.
