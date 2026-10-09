; tests/meta/test_gesture_dispatch_logs_failure.ahk

; ==============================================================================
; MODULE: GestureDispatch Failure Logging Meta Test
; DESCRIPTION:
; Regression guard for LOW-04: GestureDispatch swallowed throws then lied.
;
; GestureDispatch invoked the gesture action with a bare "try" (no catch) and
; then unconditionally logged "Gesture {1} dispatched successfully." even when
; the action threw — a silent failure that the logs actively misreported as a
; success, defeating the START/SUCCESS pairing invariant.
;
; The fix wraps the call in try/catch, moves the success log INSIDE the try
; (so it only runs on a genuine success), and logs the throw via LoggerError.
; This test asserts the catch and the error log exist and that the success log
; sits between "try {" and "catch", so a regression that reintroduces the false
; success fails CI.
;
; SCOPE: source introspection of modules/gestures.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================





; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_GDLF_DispatchCatchesAndLogs() {
	Body := _DriverFuncBody("GestureDispatch")
	Assert(Body != "", "GestureDispatch(slot) must exist in modules/gestures.ahk")

	Assert(InStr(Body, "catch") > 0,
		"GestureDispatch must catch action throws instead of using a bare try (LOW-04)")
	Assert(InStr(Body, "LoggerError") > 0,
		"GestureDispatch must log action throws via LoggerError (LOW-04)")

	; The success log must sit INSIDE the try block (between "try {" and "catch"),
	; so it only fires on a genuine success — never after a swallowed throw.
	TryPos     := InStr(Body, "try {")
	CatchPos   := InStr(Body, "catch")
	SuccessPos := InStr(Body, "LoggerInfo")
	Assert(TryPos > 0, "GestureDispatch must open a try { block around the action call (LOW-04)")
	Assert(SuccessPos > 0, "GestureDispatch must still log success via LoggerInfo")
	Assert(TryPos < SuccessPos and SuccessPos < CatchPos,
		"GestureDispatch success log must be INSIDE the try block (before catch) so it never fires after a throw (LOW-04)")
}
Test("meta gesture-dispatch-logs-failure: GestureDispatch catches throws and logs them (LOW-04)", _GDLF_DispatchCatchesAndLogs)
