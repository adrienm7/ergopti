<!-- docs/audits/performance/hammerspoon/2026_09_08/test_execution/report.md -->

# Test execution: duplicate generator removal

## Scope and method

Measured on 2026-09-08 in the Hammerspoon fix worktree on Windows with Node
22.22.2. This is developer test-harness performance, not native Hammerspoon
latency. One sequential complete JS run per version; no second heavy suite was
launched alongside it. Other machine activity was not controlled. There is no
sample distribution or statistically established latency budget.

Baseline commit: `da8cfc9cc`. Candidate changes only the generator registry,
adds its ownership regression and registers that regression in the JS suite.
The normal 219-check workload is preserved; the candidate adds one check.

Both measurements executed `node tools/test/run-js-suite.cjs` with a private
parent-only preload around `child_process.spawnSync`. The preload records
`performance.now()` before/after each original synchronous call, its exit
status and captured output byte lengths, plus parent memory and CPU. It is
not propagated through `NODE_OPTIONS`. Raw local receipts are retained under
the worktree's ignored `.rtk/` directory as `js-runner-resource-baseline.json`
and `js-runner-resource-candidate.json`, alongside their complete logs.

To repeat the whole-suite elapsed-time comparison on PowerShell, time
`node tools/test/run-js-suite.cjs` with `Measure-Command` and redirect output
to a log; check `$LASTEXITCODE` independently. Individual rows below are
replayable by timing their named command the same way. Never run the generator
checks concurrently with each other or with driver readers.

## Observations

| Workload | Before (seconds) | After (seconds) |
| --- | ---: | ---: |
| Complete JS suite | 470.712 | 259.536 |
| `node tools/test/test-drift-guard-covers-every-output.cjs` | 169.461 | 26.727 |
| `node tools/test/test-features-manifest-no-drift.cjs` | 28.097 | 4.266 |
| `node tools/build/gen-all.cjs` | 28.728 | 3.947 |
| `npm run --silent build:domain` | 28.139 | 25.769 |

Observed complete-suite reduction: 211.176 seconds, or 44.9%. The unchanged
domain build also varied, so do not attribute every millisecond to this change.
The three affected generation checks account for approximately 191 seconds
of the observed reduction.

All baseline 219 checks and candidate 220 checks passed. No scenario was removed.
The output inventory was compared before and after: exactly the same 25 paths.
The independent domain build, including its validations and Linux assembly,
still runs as a separate JS check.

## Mechanism and regression evidence

The registry contained both the aggregate domain build and the leaf generators
for its twelve outputs. Every registry traversal repeated generation and also
ran the aggregate's validation and assembly steps. The drift-coverage test
performs six traversals: initial clean control, four independent perturbations,
and final clean control. Those six scenarios remain unchanged.

The registry now lists only leaf owners. The new output-ownership regression
fails against the baseline with twelve duplicate ownership receipts, then
passes with all 25 outputs uniquely owned. Existing hostile guard receipts,
restoration failures and preservation checks remain green. No cache, stale
result reuse, batched perturbation or relaxed assertion was introduced.

## Memory, CPU and remaining work

Baseline captured successful output totaled 191,882 bytes. Removing retained
success output was therefore deprioritized as a memory optimization.
Parent peak RSS was 37,152 KiB before and 37,220 KiB after; parent measured CPU
was 1.360 and 1.422 seconds respectively. Neither metric includes the complete
child process tree, so there is no demonstrated total RAM or CPU reduction.

Next measurements should cover child-tree resources and HS module costs.
Responsibility-based test splits, shared fixture cleanup and semantic duplicate
review remain unfinished. Native macOS performance remains unmeasured.
