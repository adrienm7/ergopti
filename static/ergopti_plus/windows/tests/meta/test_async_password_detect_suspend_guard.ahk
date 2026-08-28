; tests/meta/test_async_password_detect_suspend_guard.ahk

; ==============================================================================
; MODULE: KL_AsyncPasswordDetect Suspend Guard Meta-Test
; DESCRIPTION:
; Structural regression for the suspend guard added to KL_AsyncPasswordDetect
; in keylogger.ahk.
;
; Before the fix, KL_AsyncPasswordDetect fired unconditionally from its
; SetTimer(-1) one-shot even while A_IsSuspended was true. This means UIA and
; Win32 round-trips ran during the intentional pause window, violating the
; invariant that "pause = tout éteint" enforced at the HookDispatcher level.
;
; The fix adds an early-return guard at the top of KL_AsyncPasswordDetect:
;   if A_IsSuspended
;       return
;
; This test inspects keylogger.ahk source and asserts:
;   1. A_IsSuspended is checked inside KL_AsyncPasswordDetect.
;   2. The check precedes dispatch to the disposable UIA worker.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================================================
; ==============================================================
; ======= 1/ Assertions ========================================
; ==============================================================
; ==============================================================

_APDSG_SuspendCheckPresent() {
	; Move-resilient: locate KL_AsyncPasswordDetect across the whole driver
	; source via the framework helper instead of a pinned keylogger path.
	block := _DriverFuncBody("KL_AsyncPasswordDetect")
	Assert(InStr(block, "A_IsSuspended") > 0,
		"keylogger.ahk: KL_AsyncPasswordDetect must check A_IsSuspended before running UIA/Win32 detection")
}
Test("KL_AsyncPasswordDetect: A_IsSuspended guard present (async-password-detect-suspend)", _APDSG_SuspendCheckPresent)


_APDSG_SuspendCheckBeforeDetect() {
	block := _DriverFuncBody("KL_AsyncPasswordDetect")
	posGuard  := InStr(block, "A_IsSuspended")
	posDetect := InStr(block, "RequestFn.Call")
	Assert(posGuard > 0 and posDetect > 0,
		"keylogger.ahk: both A_IsSuspended guard and worker dispatch must be present")
	Assert(posGuard < posDetect,
		"keylogger.ahk: A_IsSuspended guard must precede worker dispatch in KL_AsyncPasswordDetect")
}
Test("KL_AsyncPasswordDetect: suspend guard precedes worker dispatch (async-password-detect-suspend)", _APDSG_SuspendCheckBeforeDetect)


; F-M12: the suspend-guard hardening introduced an abort path that returned WITHOUT
; clearing the pending_hwnd dedupe guard (cleared only at the end after a successful
; detect). KL_SchedulePasswordDetect then dedupes every future re-schedule for that
; hwnd, so the conservative password verdict latches and the field's typing is silently
; dropped from all metrics after resume. The suspend branch must release pending_hwnd.
_APDSG_SuspendClearsPendingHwnd() {
	block := _DriverFuncBody("KL_AsyncPasswordDetect")
	posGuard  := InStr(block, "A_IsSuspended")
	posDetect := InStr(block, "RequestFn.Call")
	posReset  := InStr(block, "KL_ClearPendingPasswordDetect")
	Assert(posReset > 0,
		"KL_AsyncPasswordDetect must reset pending_hwnd on the suspend abort path (async-password-detect-suspend-latch)")
	Assert(posReset > posGuard and posReset < posDetect,
		"the pending owner reset must be INSIDE the A_IsSuspended branch (after the guard, before worker dispatch) so a post-resume re-schedule can re-arm (async-password-detect-suspend-latch)")
}
Test("KL_AsyncPasswordDetect: suspend abort clears pending_hwnd so re-schedule recovers (async-password-detect-suspend-latch)", _APDSG_SuspendClearsPendingHwnd)
