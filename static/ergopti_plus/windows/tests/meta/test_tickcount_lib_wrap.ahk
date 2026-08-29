; tests/meta/test_tickcount_lib_wrap.ahk

; ==============================================================================
; MODULE: A_TickCount Wrap Guard — infra/ files meta test
; DESCRIPTION:
; Static source guard for the A_TickCount 49-day wrap-around fix applied to
; four infra/ files: tooltip.ahk, metrics/metrics_filters.ahk, healthcheck.ahk,
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
	Assert(!InStr(Src, "return (A_TickCount - Record.ShownAt) < _LLM_TOOLTIP_MIN_DISPLAY_MS"),
		"tooltip.ahk must not use bare (A_TickCount - Record.ShownAt) without & 0xFFFFFFFF mask (tickcount-wrap)")

	; Positive: masked form must be present
	Assert(InStr(Src, "(Record.ShownAt) & 0xFFFFFFFF)") > 0
		and InStr(Src, "< _LLM_TOOLTIP_MIN_DISPLAY_MS") > 0,
		"tooltip.ahk must mask the surface record's LLM grace delta with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("tickcount-wrap: tooltip.ahk LLM grace comparison uses & 0xFFFFFFFF mask", _TCLW_TooltipWrapSafe)




; =========================================================================
; =========================================================================
; ======= 2/ metrics_filters.ahk -- focus cache TTL comparison ============
; =========================================================================
; =========================================================================

_TCLW_MetricsFocusWrapSafe() {
	Body := _DriverFuncBody("_MF_RefreshFocusNonCritical")
	Assert(Body != "", "_MF_RefreshFocusNonCritical must be discoverable")
	Assert(!RegExMatch(Body,
		"s)\(\(\s*\w+\s*-\s*\(MetricsFocusCache\.state\.last_at\)\)\s*<\s*MF_FOCUS_TTL_MS"),
		"metrics_filters.ahk must not compare its captured clock to the focus timestamp without an unsigned mask (tickcount-wrap)")
	Assert(RegExMatch(Body,
		"s)\(\(\s*\w+\s*-\s*\(MetricsFocusCache\.state\.last_at\)\)\s*&\s*0xFFFFFFFF\)\s*<\s*MF_FOCUS_TTL_MS"),
		"metrics_filters.ahk must mask the complete captured-clock delta with & 0xFFFFFFFF before the focus TTL comparison (tickcount-wrap)")
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


; The old tests above cover four historical sites.  This class ratchet covers
; every first-party absolute-deadline sibling found by the adversarial pass, so
; fixing one function cannot leave another rollover bug behind.
_TCLW_NoFirstPartyAbsoluteDeadlines() {
	Cases := [
		["_TooltipLifecycleDeadlineBounds", "ExpMs := OriginMs +", "TickRemaining("],
		["_TooltipUiaProcessIsHostile", "A_TickCount < _TooltipUiaHostileCache", "TickExpired("],
		["_SFD_UiaProcessIsHostile", "A_TickCount < SFD_UIA_HOSTILE_CACHE", "TickExpired("],
		["_UIASW_Request", "Deadline := A_TickCount + UIASW_DEADLINE_MS", "SetTimer(DeadlineFn, -UIASW_DEADLINE_MS)"],
		["GestureCaptureRegion", '"deadline", A_TickCount +', '"started_tick"'],
		["GestureDirectCapturePoll", 'A_TickCount < State["deadline"]', "TickExpired("],
		["GestureScreenshotRegion", '"selection_deadline", A_TickCount +', '"selection_started_tick"'],
		["GestureRegionCapturePoll", 'A_TickCount >= State["save_deadline"]', "TickExpired("],
		["_TakeNoteQueueFinalize", '"deadline", A_TickCount +', '"started_tick"'],
		["_TakeNoteAbortIfUnavailable", 'A_TickCount >= Job["deadline"]', "TickExpired("],
		["_CrashReport_SysInfo", "Deadline := A_TickCount +", "TickExpired("],
		["LLM_RemoteGenerate_Async", '"deadline_tick", A_TickCount +', "_LLMRemote_ReserveRequest("],
		["_LLMRemote_ReserveRequest", '"deadline_tick", A_TickCount +', '"start_tick"'],
		["_LLMRemote_PollRequest", 'entry.Has("deadline_tick")', "_LLM_DeadlineExpired("],
		["SpotlightMouseAt", '_Spotlight_State["Deadline"] := A_TickCount +', '"StartedTick"'],
		["_SpotlightTick", 'A_TickCount >= _Spotlight_State["Deadline"]', "TickExpired("]
	]
	Assert(Cases.Length >= 16,
		"tickcount absolute-deadline ratchet must enumerate the complete audited sibling class")
	for Spec in Cases {
		Body := _DriverFuncBody(Spec[1])
		Assert(Body != "", Spec[1] . " must be discoverable in the driver source")
		Assert(!InStr(Body, Spec[2]),
			Spec[1] . " must not retain the rollover-unsafe absolute deadline: " . Spec[2])
		Assert(InStr(Body, Spec[3]) > 0,
			Spec[1] . " must route deadline arithmetic through the wrap-safe tick primitive")
	}
	TakeNotePoll := _DriverFuncBody("_TakeNotePoll")
	Assert(TakeNotePoll != "" && InStr(TakeNotePoll, "_TakeNoteAbortIfUnavailable(JobId, Job)") > 0,
		"_TakeNotePoll must reach its wrap-safe terminal-state guard before every later side effect")
	Show := _DriverFuncBody("_TooltipShowNow")
	Present := _DriverFuncBody("_TooltipPresentStack")
	Assert(InStr(Show, "_TooltipCreateLifecyclePlan(") > 0,
		"_TooltipShowNow must carry origin+duration pairs instead of publishing an absolute deadline")
	Assert(InStr(Present, "_TooltipLifecycleDeadlineBounds(") > 0,
		"the final pixel transaction must resolve tooltip deadlines through the wrap-safe owner")
}
Test("tickcount-wrap: every audited first-party absolute deadline uses origin plus duration",
	_TCLW_NoFirstPartyAbsoluteDeadlines)
