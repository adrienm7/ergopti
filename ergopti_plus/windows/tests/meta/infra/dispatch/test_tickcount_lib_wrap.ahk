; tests/meta/infra/dispatch/test_tickcount_lib_wrap.ahk

; ==============================================================================
; MODULE: Historical Tick Arithmetic Guards
; DESCRIPTION:
; The pinned AHK v2 runtime reads A_TickCount through GetTickCount64. A process
; uptime therefore retains its full elapsed seconds instead of a DWORD remainder.
; The two uptime registration names remain historical labels for replay identity.
;
; The other five historical guards are unchanged. Their short-lived timing
; contracts do not establish a 32-bit native clock or a full-session uptime cap.
; Native source-derived uptime units exercise both ordinary and long durations.
; ==============================================================================

#Requires AutoHotkey v2.0

_TCLW_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_TCLW_CountOccurrences(Haystack, Needle) {
	Count := 0
	Position := 1
	while Position := InStr(Haystack, Needle, true, Position) {
		Count++
		Position += StrLen(Needle)
	}
	return Count
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
	; Keep the historical registration name while enforcing the native64 domain.
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("HealthCheck_Run", _DriverDir)
	Src := FSReadStrict(Owner), Code := _DriverMaskNonCode(&Src)
	Origin := "m)^global[ `t]+_HealthCheckStartMs[ `t]*:=[ `t]*A_TickCount[ `t]*$"
	Position := RegExMatch(Code, Origin, &Found)
	Assert(Position > 0 && !RegExMatch(Code, Origin, , Position + Found.Len[0]),
		"The session uptime must retain exactly one genuine native clock origin at module load")
	Body := _DriverFuncBody("HealthCheck_Run")
	Assert(Body != "", "The actual healthcheck uptime consumer must resolve")
	Code := _DriverMaskNonCode(&Body)
	Pattern := "m)^[ `t]*UptimeSec[ `t]*:=[^`r`n]*\b_HealthCheckStartMs\b[^`r`n]*$"
	Position := RegExMatch(Code, Pattern, &Found)
	Assert(Position > 0 && !RegExMatch(Code, Pattern, , Position + Found.Len[0]),
		"HealthCheck_Run must have exactly one real uptime assignment reading its origin")
	Statement := Found[0]
	for Token in ["A_TickCount", "_HealthCheckStartMs"]
		Assert(RegExMatch(Statement, "\b" . Token . "\b") && _TCLW_CountOccurrences(Statement, Token) == 1,
			"The healthcheck assignment must use each genuine clock operand once: " . Token)
	Assert(RegExMatch(Statement, "//[ `t]*1000[ `t]*$"), "The healthcheck reports elapsed seconds")
	Assert(!RegExMatch(Statement, "[&|^]|\b(?:Mod|TickElapsed)\s*\(|\b(?:0x[fF]{8}|429496729[56])\b"),
		"Healthcheck uptime must not narrow the native64 elapsed duration")
}
Test("tickcount-wrap: healthcheck.ahk uptime division uses & 0xFFFFFFFF mask", _TCLW_HealthCheckWrapSafe)




; ================================================================
; ================================================================
; ======= 4/ crash_reporter.ahk -- uptime integer division ========
; ================================================================
; ================================================================

_TCLW_CrashReporterWrapSafe() {
	; Both real report paths share the full-session uptime contract.
	for Name in ["CrashReport_Build", "_CrashReport_CheapSnapshot"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", "The actual crash uptime consumer must resolve: " . Name)
		Code := _DriverMaskNonCode(&Body)
		Pattern := "m)^[ `t]*UptimeSec[ `t]*:=[^`r`n]*\b_HealthCheckStartMs\b[^`r`n]*$"
		Position := RegExMatch(Code, Pattern, &Found)
		Assert(Position > 0 && !RegExMatch(Code, Pattern, , Position + Found.Len[0]),
			"Each report must have exactly one real uptime assignment reading its origin: " . Name)
		Statement := Found[0]
		for Token in ["A_TickCount", "_HealthCheckStartMs"]
			Assert(RegExMatch(Statement, "\b" . Token . "\b") && _TCLW_CountOccurrences(Statement, Token) == 1,
				"Each report assignment must use each genuine clock operand once: " . Name . "/" . Token)
		Assert(RegExMatch(Statement, "//[ `t]*1000[ `t]*$"), "The report publishes elapsed seconds: " . Name)
		Assert(!RegExMatch(Statement, "[&|^]|\b(?:Mod|TickElapsed)\s*\(|\b(?:0x[fF]{8}|429496729[56])\b"),
			"Crash report uptime must not narrow the native64 elapsed duration: " . Name)
	}
}
Test("tickcount-wrap: crash_reporter.ahk uptime division uses & 0xFFFFFFFF mask", _TCLW_CrashReporterWrapSafe)


; The old tests above cover four historical sites.  This class ratchet covers
; every first-party absolute-deadline sibling found by the adversarial pass, so
; fixing one function cannot leave another rollover bug behind.
_TCLW_NoFirstPartyAbsoluteDeadlines() {
	Cases := [
		["_TooltipLifecycleDeadlineBounds", "ExpMs := OriginMs +", "TickRemaining64("],
		["_TooltipUiaProcessIsHostile", "A_TickCount < _TooltipUiaHostileCache", "TickExpired64("],
		["_SFD_UiaProcessIsHostile", "A_TickCount < SFD_UIA_HOSTILE_CACHE", "TickExpired64("],
		["_UIASW_Request", "Deadline := A_TickCount + UIASW_DEADLINE_MS", "SetTimer(DeadlineFn, -UIASW_DEADLINE_MS)"],
		["GestureCaptureRegion", '"deadline", A_TickCount +', '"started_tick"'],
		["GestureDirectCapturePoll", 'A_TickCount < State["deadline"]', "TickExpired("],
		["GestureScreenshotRegion", '"selection_deadline", A_TickCount +', '"selection_started_tick"'],
		["GestureRegionCapturePoll", 'A_TickCount >= State["save_deadline"]', "TickExpired("],
		["_TakeNoteQueueFinalize", '"deadline", A_TickCount +', '"started_tick"'],
		["_TakeNoteAbortIfUnavailable", 'A_TickCount >= Job["deadline"]', "TickExpired64("],
		["LLM_RemoteGenerate_Async", '"deadline_tick", A_TickCount +', "_LLMRemote_ReserveRequest("],
		["_LLMRemote_ReserveRequest", '"deadline_tick", A_TickCount +', '"start_tick"'],
		["_LLMRemote_PollRequest", 'entry.Has("deadline_tick")', "_LLM_DeadlineExpired("],
		["SpotlightMouseAt", '_Spotlight_State["Deadline"] := A_TickCount +', '"StartedTick"'],
		["_SpotlightTick", 'A_TickCount >= _Spotlight_State["Deadline"]', "TickExpired("]
	]
	Assert(Cases.Length >= 15,
		"tickcount absolute-deadline ratchet must enumerate the complete audited sibling class")
	for Spec in Cases {
		Body := _DriverFuncBody(Spec[1])
		Assert(Body != "", Spec[1] . " must be discoverable in the driver source")
		Assert(!InStr(Body, Spec[2]),
			Spec[1] . " must not retain the rollover-unsafe absolute deadline: " . Spec[2])
		Assert(InStr(Body, Spec[3]) > 0,
			Spec[1] . " must route deadline arithmetic through the wrap-safe tick primitive")
	}
	; The crash report no longer waits on git: the commit comes from the build
	; stamp, so its system-info collector holds no deadline at all.
	SysInfo := _DriverFuncBody("_CrashReport_SysInfo")
	Assert(SysInfo != "", "_CrashReport_SysInfo must be discoverable in the driver source")
	Assert(!InStr(SysInfo, "A_TickCount +") && !InStr(SysInfo, "RunWait"),
		"_CrashReport_SysInfo must not wait on a child process or hold a tick deadline")
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





; ================================================================
; ================================================================
; ======= 6/ Startup smoke bounded waits =========================
; ================================================================
; ================================================================

; The startup smoke waits live in auto-execute code and have no callable body.
; Production source stays contiguous in the comment-stripped concatenation, so
; the paired negative/positive counts prove both bounded waits use the shared
; wrap-safe primitive without pinning this test to a repository path.
_TCLW_StartupSmokeWaitsAreWrapSafe() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable for startup smoke timing")
	Assert(!InStr(Src, "_StartupSmokePumpUntil := A_TickCount +")
		and !InStr(Src, "_StartupSmokeSuspendUntil := A_TickCount +"),
		"startup smoke waits must not compare rollover-unsafe absolute deadlines")
	AssertEqual(1, _TCLW_CountOccurrences(Src,
		"TickExpired(_StartupSmokePumpStarted, 650)"),
		"the onboarding pump wait must expire through unsigned tick arithmetic")
	AssertEqual(1, _TCLW_CountOccurrences(Src,
		"TickExpired(_StartupSmokeSuspendStarted, 750)"),
		"the suspend restoration wait must expire through unsigned tick arithmetic")
}
Test("tickcount-wrap: startup smoke waits remain bounded across rollover "
	. "(startup-smoke-absolute-deadline)",
	_TCLW_StartupSmokeWaitsAreWrapSafe)





; ================================================================
; ================================================================
; ======= 7/ RShift tap duration =================================
; ================================================================
; ================================================================

; RShift historically duplicated elapsed-time arithmetic instead of using the
; shared primitive already used by LShift and LCtrl. A tap whose key-down and
; key-up straddled the 32-bit counter rollover produced a negative duration and
; was silently rejected by the minimum-tap guard.
_TCLW_RShiftTapDurationIsWrapSafe() {
	Src := _TCLW_ReadSource("platform/remap/rshift.ahk")
	Assert(Src != "", "the RShift remap module must be readable")
	Assert(!InStr(Src, "TimeAfter - TimeBefore"),
		"RShift tap duration must not use rollover-unsafe signed subtraction")
	Assert(InStr(Src, "TickElapsed(TimeBefore, TimeAfter)") > 0,
		"RShift tap duration must use the shared wrap-safe tick primitive")
}
Test("tickcount-wrap: RShift tap duration uses TickElapsed",
	_TCLW_RShiftTapDurationIsWrapSafe)
