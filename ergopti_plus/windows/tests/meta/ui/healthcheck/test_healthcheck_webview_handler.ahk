; tests/meta/ui/healthcheck/test_healthcheck_webview_handler.ahk

; ==============================================================================
; MODULE: HealthCheck WebMessage Handler Meta Test
; DESCRIPTION:
; Static source guard for the diagnostics window's page messages. A former
; "copy_and_close" handler was written but never subscribed, so the page's
; buttons did nothing. The page's buttons now post their actions to
; _HC_OnWebMessage, which the window subscribes, bound to its epoch; the
; native Copy-and-Close button is gone.
;
; SCOPE: source introspection of ui/healthcheck/core.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Dead handler stays removed =============
; ===================================================
; ===================================================


_HCOWM_LiveHandlerIsSubscribed() {
	Src := _DriverDirConcat("ui/healthcheck")
	Assert(InStr(Src, "WebMessageReceived(_HC_OnWebMessage.Bind(WindowEpoch))") > 0,
		"the diagnostics window must subscribe _HC_OnWebMessage, bound to its epoch, so a late message of a closed window cannot reach its replacement")
	Assert(InStr(Src, "healthcheck.copy_and_close") = 0,
		"the native Copy-and-Close button is gone: the page's Copy button posts the copy action")
}
Test("HealthCheck: the page's messages reach a subscribed, epoch-bound handler (webview-dead-handler)",
	_HCOWM_LiveHandlerIsSubscribed)
