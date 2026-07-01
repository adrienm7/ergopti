; tests/meta/test_shell_runner_poll_suspend_guard.ahk

; ==============================================================================
; MODULE: ShellRunner Poll Suspend Guard Meta Test (Pattern 1, 1h)
; DESCRIPTION:
; Regression guard for the "native Suspend() never disarms a SetTimer
; callback" gap-class as it applies to ShellRunner's async completion poller.
; _SR_Poll is a periodic SetTimer that fires OnDone callbacks for completed
; async subprocesses; native Suspend() has no effect on it. Currently dormant
; (zero production callers spawn an async task today), fixed as
; defense-in-depth so a future caller cannot regress into this gap silently.
;
; SCOPE: source introspection of adapters/shell_runner.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ _SR_Poll suspend guard ===============
; =================================================
; =================================================

_SRPSG_PollHasSuspendGuard() {
	Body := _DriverFuncBody("_SR_Poll")
	Assert(Body != "", "_SR_Poll must exist in adapters/shell_runner.ahk")

	GuardPos := InStr(Body, "A_IsSuspended")
	Assert(GuardPos > 0,
		"_SR_Poll must check A_IsSuspended — this periodic SetTimer bypasses native Suspend() and would otherwise fire OnDone callbacks while the driver is paused")

	; The guard must precede the callback-firing loop, not the self-disarm
	; branch above it (that branch legitimately always runs, suspended or not,
	; so the queue can still be recognised as drained).
	DispatchPos := InStr(Body, 'task["OnDone"].Call(')
	Assert(DispatchPos > 0, '_SR_Poll must still fire OnDone via task["OnDone"].Call(...)')
	Assert(GuardPos < DispatchPos,
		"_SR_Poll: the A_IsSuspended guard must appear BEFORE the OnDone dispatch")
}
Test("shell_runner: _SR_Poll has A_IsSuspended guard before OnDone dispatch (suspend-guard-pattern-1)",
	_SRPSG_PollHasSuspendGuard)
