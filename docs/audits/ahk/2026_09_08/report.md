<!-- docs/audits/ahk/2026_09_08/report.md -->

# AHK legacy process cleanup audit

## Scope and executive summary

Audited commit: `cd1283a170ded1473dd8cf635130aa9b65488d0b`.

This bounded pass follows a failed legacy process launch through terminal claims,
native termination refusal, capture cleanup and normal native exit reporting.
It confirms two actionable defects, AHK-907 and AHK-908. No production fix is
included in this audit.

The previous UIA callback-order defect was fixed in the audited commit. This is
a separate lower-level failure: legacy cleanup can return success, mark its claim
finished and leave its child alive without a registry owner. Fixing the UIA caller
alone cannot restore the launcher's lost ownership.

## AHK-907: refused legacy termination loses its cleanup owner

- Severity: high. Confidence: high.
- Violated guarantees: G2 (truthful outcome), G3 (resource ownership).
- Source: `adapters/shell_runner.ahk`, especially
  `_SR_LegacyFailStart`, `_SR_LegacyBuildClaimLocked`,
  `_SR_LegacyBeginFinalize`, and `_SR_LegacyTerminateClaim`.

### Root cause

A published start failure removes the exact state from `_SR_ActiveTasks` and
builds a terminal claim. Finalization marks that claim finished **before**
fallible native termination and filesystem cleanup. Both termination errors are
logged, but cleanup continues and returns true unconditionally. The claim cannot
be retried because its one-shot finished flag was already consumed.

Sibling non-completion routes use the same finalizer: explicit termination,
cancellation during launch and publication rejection. Their ownership must be
covered by the repair, not just the UIA start-failure caller.

The current native legacy creator closes its process handle after resuming the
child and returns only the PID. The ordinary poller checks process liveness by
PID. A durable repair should retain the original native capability rather than
open a process later by a potentially reused identifier. This is a design
requirement derived from code, not a measured PID-reuse incident.

### Reproduction and observed result

Apply [repro.patch](repro.patch) only to a newly extracted private archive of the
audited commit's Windows and shared trees. It adds a bounded sleeping child and
one test, and replaces **only the two termination operations** in the audited
finalizer with deterministic refusal functions. State transitions, exception
handling, capture cleanup and return values remain the audited implementation.

The probe creates a real suspended child using a separately retained native job
and process handle, resumes it, then publishes its actual PID through the legacy
state machine. It invokes the published-start-failure claim and finalizer.
Zero-time waits on the independently held native process handle prove liveness
before and after both injected refusals.

Observed receipt:

```text
receipt=1, alive=1, finished=1, registered=0, tree_requests=1, direct_requests=1
```

The final test exits 1 with the intended assertion:

```text
refused termination must not report completed cleanup - actual: <1>
```

The fault injection proves handling of refusal; it does not measure how often
Windows denies termination or establish a specific live user's orphan cause.
The independently retained job exists solely to make the reproduction safe.
It is not ownership provided by the legacy code being tested.

The fixture confirms native cleanup before deleting its private capture. Its
first version hit a sharing refusal during capture deletion, masking the final
assertion despite printing the same anomalous receipt. The final fixture permits
ten bounded 25 ms cleanup retries; the second run fails on the actual ownership
assertion and leaves no probe child running. No existing driver was stopped.

Temporary archive:
`ergopti-legacy-cleanup-proof-a3a5fa6fd9e74e39bbeb295967885179`.
Final receipts: TEMP `ergopti-legacy-cleanup-proof.out/.err`.
Run hidden with AutoHotkey64, from the archived Windows tests directory:

```text
/ErrorStdOut run_all.ahk --only legacy-cleanup-denial-probe
```

Exit 1 is the expected pre-fix reproduction, not a green suite result. The patch
does not change the production checkout and must not be applied to an active
worktree. The child self-exits after 60 seconds as a secondary safety bound;
normal fixture cleanup terminates its exact owned job much earlier.

### Why existing tests miss it

`test_shell_runner_legacy_state_machine.ahk` verifies that failed publication
retires the exact registry entry and revokes its callback. Those are useful
logical ownership assertions but stop before the fallible physical teardown.
They neither prove process exit nor require a retained cleanup owner after
termination refusal. A truthful error log does not make a true cleanup return
or a consumed one-shot claim correct.

### Required repair and regression plan

1. Retain exact native process identity through launch, completion and refused
   termination. Do not replace this with PID lookup or a blocking keyboard wait.
2. Separate callback revocation from physical cleanup ownership. Keep a reachable
   owner until exit, capability closure and capture cleanup are acknowledged.
3. Cover failed startup before/after publication, explicit cancellation, launch
   reentry, stale snapshots and duplicate calls. Preserve the existing legacy
   descendant contract; silently enabling kill-on-close jobs changes semantics.
4. Add deterministic refusal/retry coverage plus real native healthy controls.
   Assert no completed receipt while the child remains alive, no duplicate
   callback, exact-owner retry and capture preservation until safe deletion.
5. Check native close refusal, reused identifiers and publication collisions.
   The current source-count tests may need to follow the new responsibility
   boundaries, but their safety guarantees must not be removed.
6. Run the gates selected by `verify-change`, commit the fix and regression
   tests atomically, and use `Audit-Finding: AHK-907` for derived status.

## AHK-908: native child failure is reported as success

- Severity: high. Confidence: high. Violated guarantee: G2.
- Root: `_SR_LegacyCreateDirect` closes the process capability before completion.
  `_SR_Poll` waits for `ProcessExist(Pid)` to become false, then `_SR_GetExitCode`
  tries to reopen that PID. Its failed-open fallback returns zero, fabricating a
  successful result after the original process object is gone.
- Silence: `OnDone` receives zero even though the intended child exited with a
  failure. No native-query failure is surfaced on this fallback path.

The second probe uses the public `ShellRunner_Spawn` without any production
fault injection. Its child writes a unique output marker and calls `ExitApp(37)`.
The observed callback contains the marker but reports zero:

```text
expected=37, observed=0, marker=legacy-exit-37
```

The test exits 1 on `native child failure must not become success`, expected 37,
actual 0. Output confirms this was the intended child, not a launch failure or
missing executable. The marker is captured by the ordinary production path.

Apply [exit_code_repro.patch](exit_code_repro.patch) alone to a fresh archive of
the audited SHA. Unlike the first patch, it changes no production function.
Launch hidden from the archived Windows tests directory with:

```text
/ErrorStdOut run_all.ahk --only legacy-exit-code-probe
```

The initial observation used the existing isolated archive with the first
probe's termination refusals still present, but this normal completion path
never invokes those operations. Both injections were then removed and the
adapter's Git blob hash verified identical to the audited source:
`55c05d6e5cf0f476df7c66dff53b998cd1f975f1`. That second run reproduced exactly
the same zero-for-37 failure. The standalone replay patch changes no production
operation. TEMP receipts: `ergopti-legacy-exit-code-proof.out/.err` and
`ergopti-legacy-exit-code-clean-proof.out/.err`. The child exits immediately on
its own; no extra native process reference is held that could artificially keep
its exit-code record queryable.

The temporary archive now contains the restored production adapter and both
probe registrations. Do not reuse it for AHK-907 without restoring that probe's
explicit refusal injection; the immutable patches specify each reproduction.

Repair requires retaining the original native capability through completion and
checking its real exit status. Cover fast nonzero and zero exits, delayed polling
under suspension, duplicate completion and stale identities. A failed status
query must not become successful output. Use `Audit-Finding: AHK-908` when this
fix and its regression tests are committed; AHK-907 remains a separate teardown
obligation even if both benefit from the same retained capability.

## Refutations and limits

UIA's accepted asynchronous native termination is not by itself proof that
physical ownership vanished: `ShellRunner.detach()` revokes callback ownership
but normally retains the task for the poller. The finding here instead covers
the finalizer route that already removed the registry entry.

Older UIA workers observed beside the resident driver were launched by a
resident predating the direct-launch fix. Their presence alone does not prove
this current defect occurred in normal use. No resident restart was performed.

No latency, CPU, memory growth rate, password disclosure or user-visible failure
frequency was measured. No performance optimization is proposed.

## Coverage register and memory watch-list

Reviewed: legacy state/claim publication, failure cleanup, callback detachment,
native creator capability lifetime, UIA start refusal and existing legacy tests.
Reproduced: one published-start-failure path with two controlled termination
refusals and an independently supervised real child; one fast nonzero native
exit through the public legacy launcher, misreported as zero.

Watch-list: preserve exact process capability, retain ownership across fallible
cleanup, never treat buffered/native request acceptance as final completion, and
keep tests capable of rejecting the original failure.

Not exhaustively covered: all normal completion variants, output read failures, natural exit
races, descendant trees, shutdown during poller failure, registry collisions,
native close refusal and every consumer of legacy handles. These are required
repair checks, not implicitly verified behavior. The whole-driver audit remains
open; two consecutive no-new-finding passes have not been completed.
