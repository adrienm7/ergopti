; tests/meta/test_takenote_winmaximize_guard.ahk

; ==============================================================================
; MODULE: TakeNote WinMaximize Existence Guard Meta Test
; DESCRIPTION:
; Regression guard for the "takenote-winmaximize-target-not-found" crash.
;
; ROOT CAUSE ENCODED:
; TakeNote() (modules/shortcuts/win.ahk, bound to Win+N / #SC025) activates or
; opens Notepad on the note file via WMExists/WMActivate/Run/WinWait/
; WinWaitActive, then called a bare "WinMaximize" (operating on AHK's
; "last found window"). WinWaitActive does not throw on timeout -- it returns
; 0/false -- so a slow or blocked Notepad launch let execution fall through to
; WinMaximize with no valid last-found-window, and WinMaximize threw
; TargetError ("Target window not found."), escalating to the crash-report
; error net for what should have been a silently-skippable timing race.
;
; The fix captures WinWaitActive's return value on both branches (window
; already open / freshly launched) and only calls WinMaximize when the wait
; actually succeeded; otherwise it logs a warning and skips the maximize
; (and the post-maximize SendFinalResult) instead of throwing.
;
; WHY SOURCE INTROSPECTION, NOT LIVE INVOCATION:
; TakeNote() is explicitly banned from live invocation (it shells out to
; notepad.exe and mutates real window state) and AHK v2 built-ins such as
; WinWaitActive / WinMaximize cannot be shadowed/stubbed from a test file the
; way project-defined functions can. This test therefore verifies the fixed
; control-flow shape directly in the driver source, the same technique already
; used by test_gesture_takenote_winwait.ahk and
; test_search_shortcut_run_path_existence_guard.ahk for this exact function
; family.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================================
; =========================================================================
; ======= 1/ TakeNote gates WinMaximize on the WinWaitActive result =======
; =========================================================================
; =========================================================================

_TTNWMG_CheckWinMaximizeGuard() {
	Body := _DriverFuncBody("TakeNote")
	Assert(Body != "", "TakeNote must exist in modules/shortcuts/win.ahk")

	; Negative: a bare, unguarded "WinMaximize" statement (no preceding
	; assignment capturing WinWaitActive's return value) must not reappear.
	; The pre-fix body called WinWaitActive(...) as a standalone statement on
	; both branches, then unconditionally called WinMaximize on the next
	; non-blank line -- i.e. "WinWaitActive(...)" was NOT the right-hand side
	; of an assignment anywhere in the body.
	Assert(InStr(Body, ":= WinWaitActive(") > 0 or InStr(Body, ":=WinWaitActive(") > 0,
		"TakeNote must capture WinWaitActive's return value (it returns 0 on timeout instead of throwing) -- calling it as a bare statement and falling through to WinMaximize regardless reintroduces the TargetError crash")

	; Positive: WinMaximize itself must be reached only through a conditional
	; that inspects the captured result, so a timeout skips it instead of
	; throwing TargetError on a non-existent last-found-window.
	MaximizeIdx := InStr(Body, "WinMaximize")
	Assert(MaximizeIdx > 0, "TakeNote must still call WinMaximize on the success path")

	BeforeMaximize := SubStr(Body, 1, MaximizeIdx - 1)
	; The nearest preceding "if" before the WinMaximize call must test the
	; captured wait-result variable (possibly negated), not be unconditional.
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
Test("shortcuts: TakeNote gates WinMaximize on the captured WinWaitActive result (no bare TargetError on timeout)",
	_TTNWMG_CheckWinMaximizeGuard)





; ============================================================================
; ============================================================================
; ======= 2/ TakeNote logs instead of crashing when the wait times out =======
; ============================================================================
; ============================================================================

_TTNWMG_CheckTimeoutIsLogged() {
	Body := _DriverFuncBody("TakeNote")
	Assert(Body != "", "TakeNote must exist in modules/shortcuts/win.ahk")

	; A timed-out wait must be observable (LoggerWarn or equivalent) rather
	; than silently doing nothing -- a WARNING with no companion log line would
	; leave the note-taking failure undiagnosable in production.
	Assert(InStr(Body, "LoggerWarn(") > 0,
		"TakeNote must log a warning when the Notepad window never becomes active, so a skipped maximize is diagnosable instead of silently vanishing")
}
Test("shortcuts: TakeNote logs a warning when the Notepad window never becomes active",
	_TTNWMG_CheckTimeoutIsLogged)





; ================================================================================
; ================================================================================
; ======= 3/ try/finally around SetTitleMatchMode restoration is preserved =======
; ================================================================================
; ================================================================================

_TTNWMG_CheckTitleMatchModeRestored() {
	Body := _DriverFuncBody("TakeNote")
	Assert(Body != "", "TakeNote must exist in modules/shortcuts/win.ahk")

	; The fix must not have dropped the existing try/finally that restores
	; A_TitleMatchMode -- SetTitleMatchMode(2) is global state and every path
	; through TakeNote (success, timeout, or a future thrown error) must
	; restore the caller's previous match mode.
	Assert(InStr(Body, "} finally {") > 0,
		"TakeNote must keep restoring A_TitleMatchMode in a finally block on every exit path, including the new timeout/skip branch")
	Assert(InStr(Body, "SetTitleMatchMode(PreviousTitleMatchMode)") > 0,
		"TakeNote's finally block must still restore the previous A_TitleMatchMode")
}
Test("shortcuts: TakeNote still restores A_TitleMatchMode via try/finally after the WinMaximize guard fix",
	_TTNWMG_CheckTitleMatchModeRestored)
