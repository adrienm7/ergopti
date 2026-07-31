; tests/meta/test_tickcount_lib_wrap.ahk

; ==============================================================================
; MODULE: A_TickCount Wrap Guard — lib/ files meta test
; DESCRIPTION:
; Static source guard for the A_TickCount 49-day wrap-around fix applied to
; four lib/ files: tooltip.ahk, metrics/metrics_filters.ahk, healthcheck.ahk,
; and crash_reporter.ahk.
;
; ROOT CAUSE ENCODED:
; A_TickCount is a 32-bit unsigned counter (~49.7 days). AHK v2 evaluates
; subtraction in 64-bit signed arithmetic, so (now - past) after a wrap yields
; a large negative number. Any comparison against a positive threshold then
; always evaluates as false: grace timers never expire, uptime reports negative
; values, and focus-cache TTLs are never honoured.
;
; The fix applies `& 0xFFFFFFFF` to every raw subtraction before comparing,
; extracting the unsigned 32-bit remainder and making the delta wrap-safe.
; ==============================================================================

#Requires AutoHotkey v2.0

_TCLW_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}




; ================================================================
; ================================================================
; ======= 1/ tooltip.ahk -- LLM tooltip grace comparison =========
; ================================================================
; ================================================================

_TCLW_TooltipWrapSafe() {
	Src := _DriverDirConcat("ui/tooltip")
	Assert(Src != "", "the ui/tooltip module must be readable")

	; Negative: bare subtraction without mask must not appear
	Assert(!InStr(Src, "return (A_TickCount - _LLM_Tooltip_ShownAt) < _LLM_TOOLTIP_MIN_DISPLAY_MS"),
		"tooltip.ahk must not use bare (A_TickCount - _LLM_Tooltip_ShownAt) without & 0xFFFFFFFF mask (tickcount-wrap)")

	; Positive: masked form must be present
	Assert(InStr(Src, "(_LLM_Tooltip_ShownAt) & 0xFFFFFFFF) < _LLM_TOOLTIP_MIN_DISPLAY_MS") > 0,
		"tooltip.ahk must mask the LLM tooltip delta with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("tickcount-wrap: tooltip.ahk LLM grace comparison uses & 0xFFFFFFFF mask", _TCLW_TooltipWrapSafe)




; =========================================================================
; =========================================================================
; ======= 2/ metrics_filters.ahk -- focus cache TTL comparison ============
; =========================================================================
; =========================================================================

_TCLW_MetricsFocusWrapSafe() {
	Src := _TCLW_ReadSource("lib/metrics/metrics_filters.ahk")
	Assert(Src != "", "lib/metrics/metrics_filters.ahk must be readable")

	Assert(!InStr(Src, "(A_TickCount - MetricsFocusCache.state.last_at) < MF_FOCUS_TTL_MS"),
		"metrics_filters.ahk must not use bare subtraction without & 0xFFFFFFFF mask (tickcount-wrap)")

	Assert(InStr(Src, "(MetricsFocusCache.state.last_at) & 0xFFFFFFFF) < MF_FOCUS_TTL_MS") > 0,
		"metrics_filters.ahk must mask the focus cache delta with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("tickcount-wrap: metrics_filters.ahk focus TTL comparison uses & 0xFFFFFFFF mask", _TCLW_MetricsFocusWrapSafe)




; ================================================================
; ================================================================
; ======= 3/ healthcheck.ahk -- uptime integer division ==========
; ================================================================
; ================================================================

_TCLW_HealthCheckWrapSafe() {
	Src := _DriverDirConcat("ui/healthcheck")
	Assert(Src != "", "the ui/healthcheck module must be readable")

	Assert(!InStr(Src, "UptimeSec := (A_TickCount - _HealthCheckStartMs) // 1000"),
		"healthcheck.ahk must not use bare subtraction without & 0xFFFFFFFF mask (tickcount-wrap)")

	Assert(InStr(Src, "(_HealthCheckStartMs) & 0xFFFFFFFF) // 1000") > 0,
		"healthcheck.ahk must mask the uptime delta with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("tickcount-wrap: healthcheck.ahk uptime division uses & 0xFFFFFFFF mask", _TCLW_HealthCheckWrapSafe)




; ================================================================
; ================================================================
; ======= 4/ crash_reporter.ahk -- uptime integer division ========
; ================================================================
; ================================================================

_TCLW_CrashReporterWrapSafe() {
	Src := _TCLW_ReadSource("modules/diagnostics/crash_reporter.ahk")
	Assert(Src != "", "modules/diagnostics/crash_reporter.ahk must be readable")

	Assert(!InStr(Src, "UptimeSec := (A_TickCount - _HealthCheckStartMs) // 1000"),
		"crash_reporter.ahk must not use bare subtraction without & 0xFFFFFFFF mask (tickcount-wrap)")

	Assert(InStr(Src, "(_HealthCheckStartMs) & 0xFFFFFFFF) // 1000") > 0,
		"crash_reporter.ahk must mask the uptime delta with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("tickcount-wrap: crash_reporter.ahk uptime division uses & 0xFFFFFFFF mask", _TCLW_CrashReporterWrapSafe)
