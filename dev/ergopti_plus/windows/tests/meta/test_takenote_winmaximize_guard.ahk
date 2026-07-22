; tests/meta/test_takenote_winmaximize_guard.ahk

; ==============================================================================
; MODULE: TakeNote WinMaximize Existence Guard Meta Test
; DESCRIPTION:
; Regression guard for the "takenote-winmaximize-target-not-found" crash.
;
; ROOT CAUSE ENCODED:
; TakeNote() is bound to Win+N. The old inline WinWaitActive/WinMaximize path
; could block the keyboard thread and eventually maximise AHK's last-found
; window after a timed-out Notepad launch. The current design queues a bounded
; poll; only that poll may maximise the explicit Notepad target, and it logs
; then abandons a deadline expiry.
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
	PollBody := _DriverFuncBody("_TakeNotePoll")
	Assert(Body != "", "TakeNote must exist in modules/shortcuts/win.ahk")
	Assert(PollBody != "", "_TakeNotePoll must own deferred Notepad finalization")

	Assert(InStr(Body, "_TakeNoteQueueFinalize") > 0,
		"TakeNote must queue Notepad finalization instead of waiting on the keyboard hotkey thread")
	Assert(InStr(Body, "WinWait") = 0 && InStr(Body, "WinMaximize") = 0,
		"TakeNote must not wait or maximise windows inline on the keyboard hotkey thread")
	Assert(InStr(PollBody, 'if WMExists(Job["pattern"])') > 0,
		"_TakeNotePoll must check that the explicit Notepad target exists before finalization")
	Assert(InStr(PollBody, 'WinMaximize(Job["pattern"])') > 0,
		"_TakeNotePoll must maximise the explicit Notepad target, never AHK's last-found window")
}
Test("shortcuts: TakeNote defers and targets WinMaximize safely (no last-found TargetError)",
	_TTNWMG_CheckWinMaximizeGuard)





; ============================================================================
; ============================================================================
; ======= 2/ TakeNote logs instead of crashing when the wait times out =======
; ============================================================================
; ============================================================================

_TTNWMG_CheckTimeoutIsLogged() {
	PollBody := _DriverFuncBody("_TakeNotePoll")
	Assert(PollBody != "", "_TakeNotePoll must exist in modules/shortcuts/win.ahk")
	Assert(InStr(PollBody, "deadline") > 0 && InStr(PollBody, "LoggerWarn(") > 0,
		"_TakeNotePoll must log and abandon a Notepad launch that exceeds the bounded deadline")
}
Test("shortcuts: TakeNote logs a warning when the bounded Notepad launch expires",
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
