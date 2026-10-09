; tests/meta/test_mouse_control_error_logging.ahk

; ==============================================================================
; MODULE: MouseControl Error Logging Meta Test
; DESCRIPTION:
; Regression guard for the bare-try-no-catch anti-pattern in MCSetPos/MCGetPos
; (adapters/mouse_control.ahk). Both functions wrapped their DllCall in a bare
; `try {}` with zero `catch` clause and zero Logger calls anywhere in the file —
; worse than the file's own MCGetMonitorCount/MCGetMonitorBounds, which at
; least return a documented zero-value sentinel on failure. A DllCall failure
; silently vanished with no diagnostic trace and no way to distinguish
; "cursor genuinely at (0,0)" from "the query failed".
;
; The fix adds a real catch clause with LoggerWarn to both functions, keeping
; the documented fail-safe return shape (MouseControl.spec.js: setPos is
; "silent_noop", getPos is "return_zero_object") unchanged — only
; diagnosability changes.
;
; SCOPE: source introspection of adapters/mouse_control.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================================================
; ===============================================================
; ======= 1/ MCSetPos has a real catch that logs ================
; ===============================================================
; ===============================================================

_MCEL_SetPosHasCatchAndLogs() {
	Body := _DriverFuncBody("MCSetPos")
	Assert(Body != "", "MCSetPos must be defined in adapters/mouse_control.ahk")

	TryPos := InStr(Body, "try {")
	Assert(TryPos > 0, "MCSetPos must wrap its DllCall in a try")

	CatchPos := InStr(Body, "} catch", , TryPos)
	Assert(CatchPos > 0,
		"MCSetPos: the try must have a catch clause — a bare try with no catch silently swallows every DllCall failure with zero diagnostic trace")

	CatchBody := SubStr(Body, CatchPos, 300)
	Assert(InStr(CatchBody, "LoggerWarn") > 0,
		"MCSetPos: the catch clause must call LoggerWarn so a real DllCall failure is diagnosable, not silently invisible")
}
Test("mouse_control: MCSetPos's try has a catch that logs (bare-try-anti-pattern)", _MCEL_SetPosHasCatchAndLogs)




; ===============================================================
; ===============================================================
; ======= 2/ MCGetPos has a real catch that logs ================
; ===============================================================
; ===============================================================

_MCEL_GetPosHasCatchAndLogs() {
	Body := _DriverFuncBody("MCGetPos")
	Assert(Body != "", "MCGetPos must be defined in adapters/mouse_control.ahk")

	TryPos := InStr(Body, "try {")
	Assert(TryPos > 0, "MCGetPos must wrap its DllCall in a try")

	CatchPos := InStr(Body, "} catch", , TryPos)
	Assert(CatchPos > 0,
		"MCGetPos: the try must have a catch clause — a bare try with no catch silently swallows every DllCall failure with zero diagnostic trace")

	CatchBody := SubStr(Body, CatchPos, 300)
	Assert(InStr(CatchBody, "LoggerWarn") > 0,
		"MCGetPos: the catch clause must call LoggerWarn so a real DllCall failure is diagnosable, not silently invisible")
}
Test("mouse_control: MCGetPos's try has a catch that logs (bare-try-anti-pattern)", _MCEL_GetPosHasCatchAndLogs)
