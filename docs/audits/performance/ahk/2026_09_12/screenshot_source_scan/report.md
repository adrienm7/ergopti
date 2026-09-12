# Screenshot source guard extraction

## Scope and method

Measured the native AHK test `screenshot-source-cost` on Windows on September
12, 2026, from worktree HEAD `8f4fac7b0`. Each version ran in a fresh hidden
AutoHotkey64 process using `/ErrorStdOut
static/ergopti_plus/windows/tests/run_all.ahk --only=screenshot-source-cost`
from the worktree root. The runner records callback wall time with QPC.
TEMP and TMP pointed to the campaign scratch on D:. No concurrent verification
process was present at launch, and no screenshot, clipboard operation or input
injection was performed: the callback only inspects source text.

| Version | Callback time | Samples |
| --- | ---: | ---: |
| Original private recursive scanner | 2378.598 ms | 1 |
| Shared indexed extractor | 611.333 ms | 1 |

Receipts in the campaign scratch are `screenshot-cost-before-01.out` and
`screenshot-cost-after-01.out`, both exit 0. An earlier complete-suite receipt,
`esrc-label-gate-01.out`, recorded 2409.289 ms for the unchanged original guard;
that observation is contextual, not a paired whole-suite measurement.

## Change and regression proof

The callback previously reread the AHK tree seven times and scanned braces
without distinguishing strings or comments. It now calls the existing shared
`_DriverFuncBody` extractor for the same seven functions. Every clipboard,
epoch, suspension and worker-ownership assertion remains intact. The framework
include remains available when the fragment is parsed independently.

The new structural guard extracts this test's actual callback, requires a
nonempty body and rejects the private scanner. `screenshot-guard-before-01.out`
failed on that exact assertion (exit 1); `screenshot-guard-after-01.out` passed
(exit 0). The original behavioral source guard also passed on both versions.

## Limits

Validation: the selected gate completed with 6169 AHK cases passing and 222 of
223 JavaScript checks passing. The metrics range bridge reported a native
process error through `assert.ifError`; the suite retained only its stack tail,
so the original process error code is unavailable. The unchanged bridge passed
in isolation (`screenshot-bridge-diagnostic-01`, exit 0). This does not establish
the cause of the first failure or make the original full gate green. The
standalone test fragment parsed with `#Warn All, StdOut`, exit 0 and empty
stdout/stderr (`screenshot-standalone-01/parse`), without executing callbacks.

This removes redundant source reads without adding a new cache. One sample per
version does not establish a tail-latency distribution. CPU usage, peak memory,
whole-suite duration and driver input latency were not measured. No updater
probation or cleanup waits were shortened; those require separate ownership
evidence. No private user text is included in this report.
