<!-- docs/audits/performance/ahk/2026_09_08/test_runner_scan/report.md -->

# AHK runner-reference guard memory

## Scope and provenance

Measured on Windows on September 8, 2026, using Node 22.22.2 x64 and the
repository at `ee991791c` for the alternating experiment. The subject is the JavaScript guard
`tools/test/test-ahk-runners-are-invoked.cjs`, not driver runtime memory.
All executions discovered eight AHK runners and accepted their references.
A macOS integration suite was running concurrently; desktop load was not
controlled. Latency figures are observations, not a causal speedup claim.

The old guard loaded all tracked eligible text into a retained corpus before
looking for references. The candidate retains runner metadata and reads one
file at a time. It still reads every eligible existing tracked file, even after
finding every reference, so later read errors are not hidden.

## Measurements

Each observation used a fresh Node process. A wrapper recorded
`performance.now()` around loading the guard and `process.resourceUsage().maxRSS`
after completion. Peak RSS includes Node and module loading. Heap usage after
completion is not a live-driver memory measurement.

| Order | Variant   | Elapsed ms | Peak RSS KiB |
| ----- | --------- | ---------: | -----------: |
| 1     | Baseline  |    964.100 |       123464 |
| 2     | Candidate |    898.156 |        52040 |
| 3     | Candidate |    829.456 |        50764 |
| 4     | Baseline  |    923.376 |       124004 |

The candidate's peak process RSS was approximately 58–59% lower in this small
matched sequence. Two samples per variant do not establish a percentile or
long-term distribution. A subsequent run of the implemented guard reported
855.510 ms and 50744 KiB, also with eight referenced runners. That subsequent
measurement was made after rebasing onto `7f1be822b`, which added five macOS
test-fixture changes; it is a confirmation, not part of the matched sequence.

The experiment compiled the candidate in memory using Node's module wrapper;
it did not rewrite the active checkout to alternate variants. Its temporary
wrapper is `measure-orphan-guard.cjs` in the September 8 verification directory.
For independent replay, use separate checkouts of the parent and candidate,
load each guard in a fresh Node process, and record the two APIs above. Do not
run generator drift checks concurrently with a driver verification suite.

## Regression evidence and limitations

The new `test-ahk-runner-scan-streaming.cjs` executes the actual guard in an
isolated VM. Filesystem instrumentation delegates substring matching to real
strings and observes whether the first text is examined before the second is
read. Both the scratch draft and the tracked regression failed against the
unchanged guard with `must inspect docs/a.md before reading docs/b.md`; all
semantic scenarios had already passed. The implemented guard passes both.

Semantic cases retain self-reference exclusion, distinct paths with the same
basename, case-sensitive substring mentions, tracked-file filtering, deleted
files, extension filtering, orphan ordering, the empty-runner diagnostic, and
read-error propagation after complete reference coverage. The test is wired
into the standard JS suite.

The ordering regression rejects the old eager load; it would not detect a new
cache retaining text after inspection. Source review and the measured RSS
provide the complementary evidence that this implementation retains no corpus.

Discovery now precedes corpus reads and existence checks are interleaved with
reads. Neither implementation offers an atomic filesystem snapshot; concurrent
file mutation can change which error appears first. This change does not
strengthen the generous historical rule that a documented runner is considered
discoverable; it does not prove the runner is regularly executed.

No driver hot path, startup, tooltip, process-lifetime memory, full-suite peak
RSS, or whole-suite speed improvement was measured here. Final selected-gate
completion remains required before committing this optimization.
