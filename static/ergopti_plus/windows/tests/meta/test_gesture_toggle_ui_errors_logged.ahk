; tests/meta/test_gesture_toggle_ui_errors_logged.ahk

; ==============================================================================
; MODULE: Gesture Toggle UI Errors Logged Meta Test
; DESCRIPTION:
; Regression guard for AHK-31: GestureGenericToggleUI used bare `try`
; statements (no catch) for the open_fn and close_fn dispatch calls.
; When either callback threw (e.g. KLUI_ToggleApps hitting a WebView2
; cold-start failure, or OpenPersonalEditor finding a missing file), the
; exception was silently discarded. The action appeared as a missed gesture
; and nothing was written to ErgoptiPlus_errors_*.log.
;
; Fix (AHK-31): both `try open_fn.Call()` and `try close_fn.Call()` are
; replaced with try/catch blocks that call LoggerError so failures reach
; the errors-only log sink, making the silent no-op diagnosable.
;
; This test asserts (source introspection on GestureGenericToggleUI):
;   (a) The function body contains `catch` (no longer bare try) for both
;       open and close dispatch sites.
;   (b) LoggerError is present (failure is surfaced, not swallowed).
;   (c) The bare patterns `try open_fn.Call()` and `try close_fn.Call()`
;       are absent (the fix replaced them with try/catch blocks).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TGTUEL_CheckToggleUIErrorsLogged() {
	Body := _DriverFuncBody("GestureGenericToggleUI")
	Assert(Body != "", "GestureGenericToggleUI must exist in modules/gestures/actions.ahk")

	; (a) catch must be present for both dispatch sites
	Assert(InStr(Body, "catch"),
		"AHK-31: GestureGenericToggleUI must have catch blocks for open_fn and close_fn dispatch — bare try silently swallows callback failures and produces no diagnostic trace in ErgoptiPlus_errors_*.log")

	; (b) LoggerError must be present so the error reaches the errors-only log sink
	Assert(InStr(Body, "LoggerError"),
		"AHK-31: GestureGenericToggleUI must call LoggerError in its catch blocks so action failures are written to the errors-only log sink (bare try swallows the exception and produces zero evidence)")

	; (c) The old bare-try patterns must be gone
	Assert(!InStr(Body, "try open_fn.Call()"),
		"AHK-31: bare 'try open_fn.Call()' must not appear in GestureGenericToggleUI — it must be replaced by a try/catch that logs the error")
	Assert(!InStr(Body, "try close_fn.Call()"),
		"AHK-31: bare 'try close_fn.Call()' must not appear in GestureGenericToggleUI — it must be replaced by a try/catch that logs the error")
}


Test("meta ahk-31: GestureGenericToggleUI uses try/catch + LoggerError for open/close dispatch so failures reach the errors-only log sink",
	_TGTUEL_CheckToggleUIErrorsLogged)
