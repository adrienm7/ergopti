<!-- docs/audits/performance/ahk/2026_09_12/source_reference/report.md -->

# Borrow source buffers during test function extraction

Baseline: 3477878ca on the Windows maintainer workstation, native AutoHotkey v2,
resident driver running. All measurements used sequential hidden processes with
TEMP/TMP in the dedicated verification scratch. No competing heavy verification
was observed at launch. No private ledger was read or changed.

## Evidence

Three fresh processes per variant ran:

```text
AutoHotkey64.exe /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --only=hotif-globals-boot-safe
```

Each process selected four tests. Values below are the runner's QPC callback
duration for the second test, the real transitive HotIf guard. They exclude
process startup and are not whole-suite, CPU, RAM or driver latency measures.

| Sample | Baseline ms | Borrowed source ms |
| --- | ---: | ---: |
| 1 | 2128.490 | 1630.734 |
| 2 | 2229.384 | 1627.515 |
| 3 | 2010.614 | 1597.779 |
| Median | 2128.490 | 1627.515 |
| Maximum | 2229.384 | 1630.734 |

The observed median reduction is 500.975 ms (23.5%). Three observations do not
establish a latency distribution or a long-term tail guarantee.

Temporary coarse-clock phase instrumentation identified 1438–1579 ms in graph
traversal of 72 names, versus 15–16 ms in final global-guard checks. Passing the
5,290,096-character source to a trivial by-value function 72 times took 453 ms;
the corresponding reference calls were below A_TickCount resolution. This is
not a claim of zero reference-call cost.

## Change and regression protection

The body extractor and signature finder now borrow their caller's source
variable. All direct callers were updated. Parsing, index ownership, result
caching and name validation remain exercised by existing behavior tests.
Native function metadata assertions fail before the change when either source
parameter is by value; fixture assertions also check the borrowed source remains
unchanged after successful and rejected lookups.

The implementation does not add a cache. A prior experiment copying ordinary
code spans during quote masking showed no convincing gain (median 2128.490 vs
2120.564 ms) and was removed. Optimization of source masking is not justified
by these measurements. An initial incorrectly quoted filter selected 307 tests;
those receipts are excluded from every performance comparison here.

Scratch receipt prefixes: `hotif-scan-target-baseline-`,
`hotif-source-reference-candidate-`, `hotif-scan-phases-`,
`hotif-source-transfer-01` and `body-source-reference-before-01`.
Validation: `body-source-reference-gate-01` exited 1. Encoding and all 6194 AHK
tests passed; 223/224 JS checks passed. The sole failure is the false-green
ratchet on macOS `test_physical_accounting.lua:72`, introduced in baseline
db4234574. Running the same ratchet in the clean main checkout at 3477878ca
reproduced the identical failure without this patch (receipt
`body-source-reference-baseline-ratchet`, exit 1). No baseline was raised and
no foreign test was changed. The complete gate is not reported as green.
