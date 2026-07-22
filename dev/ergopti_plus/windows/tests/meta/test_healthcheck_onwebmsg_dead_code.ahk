; tests/meta/test_healthcheck_onwebmsg_dead_code.ahk

; ==============================================================================
; MODULE: HealthCheck Dead WebMessage Handler Meta Test (Pattern 4)
; DESCRIPTION:
; Static source guard confirming _HealthCheck_OnWebMsg (a fully-written
; "copy_and_close" WebMessageReceived handler) stays removed. It was defined
; but never wired up to any WebMessageReceived subscription anywhere in
; ui/healthcheck/core.ahk -- genuinely dead code with no live impact, since
; the real Copy-and-Close button is a native AHK control, not routed through
; WebView2 at all.
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

_HCOWM_CopyAndCloseIsNativeControl() {
	Src := _DriverDirConcat("ui/healthcheck")
	Assert(InStr(Src, "healthcheck.copy_and_close") > 0,
		'HealthCheck_ShowWindow must still label its Copy-and-Close button via t("healthcheck.copy_and_close") -- the real mechanism is a native AHK button, not a WebView2 message handler')
}
Test("HealthCheck: Copy-and-Close stays a native AHK control, not a WebView2 message round-trip (webview-dead-handler)",
	_HCOWM_CopyAndCloseIsNativeControl)
