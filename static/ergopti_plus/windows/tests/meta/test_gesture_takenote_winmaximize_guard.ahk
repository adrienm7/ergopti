; tests/meta/test_gesture_takenote_winmaximize_guard.ahk

; ==============================================================================
; MODULE: GestureTakeNote WinMaximize Existence Guard Meta Test (Pattern 2)
; DESCRIPTION:
; Companion to test_takenote_winmaximize_guard.ahk (the F5 fix for the sibling
; TakeNote in modules/shortcuts/win.ahk). GestureTakeNote
; (modules/gestures/actions.ahk) had the exact same bug shape: WinWaitActive
; called as a bare statement (return value discarded) on both branches, then
; an unconditional WinMaximize on the next line. WinWaitActive does not throw
; on timeout -- it returns 0/false -- so a slow or blocked Notepad launch let
; execution fall through to WinMaximize with no valid last-found-window,
; throwing TargetError.
;
; SCOPE: source introspection of modules/gestures/actions.ahk — GestureTakeNote
; shells out to notepad.exe and mutates real window state, so it cannot be
; safely invoked live from a test.
; ==============================================================================

#Requires AutoHotkey v2.0




; =========================================================================
; =========================================================================
; ======= 1/ GestureTakeNote gates WinMaximize on the wait result =========
; =========================================================================
; =========================================================================

_GTNWMG_CheckWinMaximizeGuard() {
	Body := _DriverFuncBody("GestureTakeNote")
	Assert(Body != "", "GestureTakeNote must exist in modules/gestures/actions.ahk")

	Assert(InStr(Body, ":= WinWaitActive(") > 0,
		"GestureTakeNote must capture WinWaitActive's return value (it returns 0 on timeout instead of throwing) -- calling it as a bare statement and falling through to WinMaximize regardless reintroduces the TargetError crash")

	MaximizeIdx := InStr(Body, "WinMaximize")
	Assert(MaximizeIdx > 0, "GestureTakeNote must still call WinMaximize on the success path")

	BeforeMaximize := SubStr(Body, 1, MaximizeIdx - 1)
	LastIfPos := 0
	SearchPos := 1
	loop {
		Found := InStr(BeforeMaximize, "if ", , SearchPos)
		if (Found = 0)
			break
		LastIfPos := Found
		SearchPos := Found + 1
	}
	Assert(LastIfPos > 0, "WinMaximize must sit behind an 'if' that checks the WinWaitActive result -- an unconditional call reintroduces the TargetError crash on a timed-out wait")

	GuardClause := SubStr(BeforeMaximize, LastIfPos)
	Assert(InStr(GuardClause, "NoteWindowIsActive") > 0 or InStr(GuardClause, "WinWaitActive") > 0,
		"The 'if' guarding WinMaximize must reference the captured WinWaitActive result, not an unrelated condition")
}
Test("gestures: GestureTakeNote gates WinMaximize on the captured WinWaitActive result (no bare TargetError on timeout)",
	_GTNWMG_CheckWinMaximizeGuard)

_GTNWMG_CheckTimeoutIsLogged() {
	Body := _DriverFuncBody("GestureTakeNote")
	Assert(InStr(Body, "LoggerWarn(") > 0,
		"GestureTakeNote must log a warning when the Notepad window never becomes active, so a skipped maximize is diagnosable instead of silently vanishing")
}
Test("gestures: GestureTakeNote logs a warning when the Notepad window never becomes active",
	_GTNWMG_CheckTimeoutIsLogged)

_GTNWMG_CheckTitleMatchModeRestored() {
	Body := _DriverFuncBody("GestureTakeNote")
	Assert(InStr(Body, "} finally {") > 0,
		"GestureTakeNote must keep restoring A_TitleMatchMode in a finally block on every exit path, including the new timeout/skip branch")
	Assert(InStr(Body, "SetTitleMatchMode(PreviousTitleMatchMode)") > 0,
		"GestureTakeNote's finally block must still restore the previous A_TitleMatchMode")
}
Test("gestures: GestureTakeNote still restores A_TitleMatchMode via try/finally after the WinMaximize guard fix",
	_GTNWMG_CheckTitleMatchModeRestored)
