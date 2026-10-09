; tests/meta/test_tooltip_renderer_error_logging.ahk

; ==============================================================================
; MODULE: TooltipRenderer Error Logging Meta Test
; DESCRIPTION:
; Regression guard for F50 (AUDIT_AHK_2026-07-01.md): TooltipRHide wrapped
; TooltipHide() in a bare `try` with zero `catch` clause, silently swallowing
; any failure with no diagnostic trace. TooltipRShow's catch clause called
; OutputDebug instead of the centralized Logger — invisible outside an
; attached debugger and never reaching ErgoptiPlus.log, unlike every sibling
; adapter's catch block in this zone (mouse_control.ahk, window_manager.ahk,
; window_info.ahk).
;
; The fix gives TooltipRHide a real catch that logs via LoggerWarn, and
; routes TooltipRShow's catch through LoggerWarn instead of OutputDebug.
;
; SCOPE: source introspection of adapters/tooltip_renderer.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================================================
; ===============================================================
; ======= 1/ TooltipRHide has a real catch that logs ============
; ===============================================================
; ===============================================================

_TREL_HideHasCatchAndLogs() {
	Body := _DriverFuncBody("TooltipRHide")
	Assert(Body != "", "TooltipRHide must be defined in adapters/tooltip_renderer.ahk")

	TryPos := InStr(Body, "try {")
	Assert(TryPos > 0, "TooltipRHide must wrap TooltipHide() in a try")

	CatchPos := InStr(Body, "} catch", , TryPos)
	Assert(CatchPos > 0,
		"TooltipRHide: the try must have a catch clause — a bare try with no catch silently swallows every TooltipHide() failure with zero diagnostic trace (F50)")

	CatchBody := SubStr(Body, CatchPos, 300)
	Assert(InStr(CatchBody, "LoggerWarn") > 0,
		"TooltipRHide: the catch clause must call LoggerWarn so a real TooltipHide() failure is diagnosable, not silently invisible (F50)")
}
Test("tooltip_renderer: TooltipRHide's try has a catch that logs (F50)", _TREL_HideHasCatchAndLogs)





; ================================================================
; ================================================================
; ======= 2/ TooltipRShow logs via Logger, not OutputDebug =======
; ================================================================
; ================================================================

_TREL_ShowUsesLoggerNotOutputDebug() {
	Body := _DriverFuncBody("TooltipRShow")
	Assert(Body != "", "TooltipRShow must be defined in adapters/tooltip_renderer.ahk")
	Assert(InStr(Body, "OutputDebug") = 0,
		"TooltipRShow must not use OutputDebug — it is invisible outside an attached debugger and never reaches ErgoptiPlus.log (F50)")
	Assert(InStr(Body, "LoggerWarn") > 0,
		"TooltipRShow's catch clause must route through the centralized LoggerWarn, matching every sibling adapter's catch block (F50)")
}
Test("tooltip_renderer: TooltipRShow logs via LoggerWarn, not OutputDebug (F50)", _TREL_ShowUsesLoggerNotOutputDebug)
