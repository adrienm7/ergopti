; tests/meta/test_healthcheck_onwebmsg_dead_code.ahk

; ==============================================================================
; MODULE: HealthCheck Dead WebMessage Handler Meta Test (Pattern 4)
; DESCRIPTION:
; Static source guard confirming _HealthCheck_OnWebMsg (a fully-written
; "copy_and_close" WebMessageReceived handler) stays removed. It was defined
; but never wired up to any WebMessageReceived subscription anywhere in
; ui/healthcheck/core.ahk -- genuinely dead code. The page's buttons now post
; their actions to _HC_OnWebMessage, which the window does subscribe, bound to
; its epoch; the native Copy-and-Close button is gone.
;
; SCOPE: source introspection of ui/healthcheck/core.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Dead handler stays removed =============
; ===================================================
; ===================================================

_HCOWM_NoDeadHandler() {
	Src := _DriverDirConcat("ui/healthcheck")
	Assert(Src != "", "the ui/healthcheck module must exist")
	Assert(InStr(Src, "_HealthCheck_OnWebMsg") = 0,
		"_HealthCheck_OnWebMsg was dead code (defined but never subscribed to any WebMessageReceived event) and was removed -- do not reintroduce it without also wiring it up")
}
Test("HealthCheck: dead _HealthCheck_OnWebMsg handler stays removed (webview-dead-handler)", _HCOWM_NoDeadHandler)

_HCOWM_LiveHandlerIsSubscribed() {
	Src := _DriverDirConcat("ui/healthcheck")
	Assert(InStr(Src, "WebMessageReceived(_HC_OnWebMessage.Bind(WindowEpoch))") > 0,
		"the diagnostics window must subscribe _HC_OnWebMessage, bound to its epoch, so a late message of a closed window cannot reach its replacement")
	Assert(InStr(Src, "healthcheck.copy_and_close") = 0,
		"the native Copy-and-Close button is gone: the page's Copy button posts the copy action")
}
Test("HealthCheck: the page's messages reach a subscribed, epoch-bound handler (webview-dead-handler)",
	_HCOWM_LiveHandlerIsSubscribed)
