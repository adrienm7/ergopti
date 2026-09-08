# Crash worker enrichment deadline

## Scope and evidence

This pass investigates isolated crash-report publication, not keyboard latency.
The resident driver was not restarted or used as a measurement harness. Tests
use disposable config directories and the existing exact worker-tree owner.
Only one AHK runner executes at a time. No test timeout was increased.

Before the change, `ahk-005-crash-worker-transport` failed its existing 10000 ms
completion deadline both alone and in the full suite. The same isolated test
also failed in an archive of commit
`20539faed8e847e3774abadb6f84deabf47d522b`, before the exit-code-259 fix. The
archive has no Git metadata; this is not a complete performance-equivalent
checkout, but its failure excludes that later code change as a prerequisite.

One sequential native measurement on 2026-09-08 at 14:47:22 +02:00 measured
`Get-CimInstance Win32_OperatingSystem` at 1690.6536 ms and
`Get-CimInstance Win32_Processor | Select-Object -First 1` at 4198.9391 ms.
These are individual observations, not percentiles or complete worker latency.
Concurrent machine load was not controlled, so no environmental cause is claimed.

A paired test kept the same large snapshot, schema assertions and privacy
canaries. The original case failed; the case using the existing `os,cpu` fault
injection passed and verified both named enrichment errors. Both synchronous
CIM calls precede the sole artifact write. Their catches isolate exceptions,
not a call that has yet to return; the subsequent Git call is similarly outside
an explicit reporter deadline.

## Mechanism changed

The AHK owner requests termination of a primary worker after 5000 ms. The
tree-owned `requestTerminate` contract preserves its real completion receipt.
The existing nonzero-primary completion path then starts the minimal writer.
A normal successful completion that wins the race remains valid. No child exit
code is fabricated and no optional system field is permanently removed.

The deadline is bound to the exact owner and attempt. Suspension defers its
action; cancellation and completion revoke it. Refused termination retains the
task and mapping and schedules a retry. Timer-retry failure is recorded, retains
ownership, and can be retried explicitly. The fallback artifact records
`primary worker deadline exceeded` in `enrichment_errors`.

The 5000 ms value is a request deadline, **not** an unconditional guarantee that
the report exists by then: native termination refusal and fallback failure must
remain visible. No successor may start before primary exit is confirmed.

## Regression evidence and validation

The new unresponsive-primary case failed before implementation because no
fallback started. Six targeted lifecycle cases then passed: fallback, normal
completion, cancellation, suspension, refused termination and timer-arm failure.
Three native large-snapshot cases passed: ordinary enrichment, independent CIM
faults and forced primary expiration. All preserve schema and privacy assertions.

The broader crash-family replay passed 90/90 cases. Five additional invalid
budget cases then joined the complete suite. The change-scoped verifier passed
with exit 0: 5763/5763 AHK tests with complete execution coverage, 5/5 end-to-end
tests, 216 JavaScript checks, source encoding and parse validation. The receipt
is `ergopti-crash-deadline-verify.log` in the session's temporary directory.

Prior full-suite watchdog failures and intermittent tooltip budget failures
remain recorded separately. One complete green run does not refute intermittent
latency, and these results do not measure an improvement to keyboard latency.
