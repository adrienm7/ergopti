; tests/meta/test_mouse_suspend_guard.ahk

; ==============================================================================
; MODULE: Mouse Suspend Guard Meta Test
; DESCRIPTION:
; Static source guards for the T-W01 "mouse-handlers-bypass-suspend" finding.
;
; KL_Mouse_OnLUp, KL_Mouse_OnRUp, KL_Mouse_AccumScroll and KL_Mouse_FlushScroll
; are registered via HookDispatcher (mouse button hooks) and SetTimer (scroll
; burst flush). None of these paths go through KL_AppendLog's chokepoint guard
; before reaching KL_BumpMouseClick or writing telemetry — they bypass native
; AHK Suspend and fire regardless of A_IsSuspended.
;
; The fixes:
; 1. KL_Mouse_OnLUp / KL_Mouse_OnRUp: add `if A_IsSuspended { ... return }`
;    BEFORE the call to KL_BumpMouseClick so click-distance counters are not
;    bumped while the driver is paused.
; 2. KL_Mouse_AccumScroll: add `if A_IsSuspended return` at the top so scroll
;    ticks are not accumulated and no timer is armed while paused.
; 3. KL_Mouse_FlushScroll: add `if A_IsSuspended return` at the top so a timer
;    that slipped through the pause transition cannot flush stale scroll data.
; 4. KL_Mouse_Stop: `scroll_flush_fn := unset` must appear after the timer
;    cancellation so re-entry cannot re-arm a stale timer reference.
;
; This is a meta-static test (scans source text) because keylogger_mouse.ahk
; registers top-level HookDispatcher subscribers and cannot be #Included by the
; headless runner without pulling in the full driver.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

_MMSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ====================================================
; ====================================================
; ======= 2/ Suspend-guard ordering assertions =======
; ====================================================
; ====================================================

_MMSG_LUpGuardBeforeBump() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_OnLUp")
	Assert(Body != "", "KL_Mouse_OnLUp must exist in keylogger_mouse.ahk")
	PosGuard := InStr(Body, "A_IsSuspended")
	PosBump  := InStr(Body, "KL_BumpMouseClick")
	Assert(PosGuard > 0,
		"KL_Mouse_OnLUp must check A_IsSuspended — mouse button hooks bypass Suspend; without this guard KL_BumpMouseClick fires while the driver is paused")
	Assert(PosBump > 0,
		"KL_Mouse_OnLUp must call KL_BumpMouseClick")
	Assert(PosGuard < PosBump,
		"KL_Mouse_OnLUp: A_IsSuspended guard must appear BEFORE KL_BumpMouseClick so the click counter is not bumped while paused")
}
Test("mouse: KL_Mouse_OnLUp has A_IsSuspended guard before KL_BumpMouseClick", _MMSG_LUpGuardBeforeBump)


_MMSG_RUpGuardBeforeBump() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_OnRUp")
	Assert(Body != "", "KL_Mouse_OnRUp must exist in keylogger_mouse.ahk")
	PosGuard := InStr(Body, "A_IsSuspended")
	PosBump  := InStr(Body, "KL_BumpMouseClick")
	Assert(PosGuard > 0,
		"KL_Mouse_OnRUp must check A_IsSuspended — mouse button hooks bypass Suspend; without this guard KL_BumpMouseClick fires while the driver is paused")
	Assert(PosBump > 0,
		"KL_Mouse_OnRUp must call KL_BumpMouseClick")
	Assert(PosGuard < PosBump,
		"KL_Mouse_OnRUp: A_IsSuspended guard must appear BEFORE KL_BumpMouseClick so the click counter is not bumped while paused")
}
Test("mouse: KL_Mouse_OnRUp has A_IsSuspended guard before KL_BumpMouseClick", _MMSG_RUpGuardBeforeBump)


_MMSG_AccumScrollHasSuspendGuard() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_AccumScroll")
	Assert(Body != "", "KL_Mouse_AccumScroll must exist in keylogger_mouse.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"KL_Mouse_AccumScroll must check A_IsSuspended — SetTimer-backed scroll accumulation bypasses Suspend; without this guard ticks are counted and a flush timer is armed while paused")
}
Test("mouse: KL_Mouse_AccumScroll has A_IsSuspended guard", _MMSG_AccumScrollHasSuspendGuard)


_MMSG_FlushScrollHasSuspendGuard() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_FlushScroll")
	Assert(Body != "", "KL_Mouse_FlushScroll must exist in keylogger_mouse.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"KL_Mouse_FlushScroll must check A_IsSuspended — a one-shot timer armed before pause fires after Suspend is set; without this guard stale scroll data is flushed to the log while paused")
}
Test("mouse: KL_Mouse_FlushScroll has A_IsSuspended guard", _MMSG_FlushScrollHasSuspendGuard)


; keylogger-mouse-scroll-suspend-reset: unlike KL_Mouse_ParkTick (which resets
; prev_x/prev_y/park_last_x on its suspended path), KL_Mouse_FlushScroll's
; A_IsSuspended branch used to return without clearing scroll_start/scroll_last.
; A one-shot flush timer armed just before a Suspend, then firing WHILE
; suspended, left those timestamps stale for the whole pause window; the next
; post-resume scroll then flushed a duration/velocity spanning the entire pause
; instead of just the burst that actually occurred.
_MMSG_FlushScrollResetsAccumulatorWhenSuspended() {
	Body := _DriverFuncBody("KL_Mouse_FlushScroll")
	Assert(Body != "", "KL_Mouse_FlushScroll must exist in keylogger_mouse.ahk")

	GuardPos := InStr(Body, "A_IsSuspended")
	Assert(GuardPos > 0, "KL_Mouse_FlushScroll must check A_IsSuspended")

	; All four accumulator fields must be reset, and the reset must happen
	; INSIDE the suspended branch (before its own "return"), not merely
	; somewhere later in the function (that would only cover the non-suspended path).
	SuspendedBranchEnd := InStr(Body, "return", , GuardPos)
	Assert(SuspendedBranchEnd > 0, "KL_Mouse_FlushScroll's A_IsSuspended branch must contain a return")
	SuspendedBranch := SubStr(Body, GuardPos, SuspendedBranchEnd - GuardPos)

	; Column-aligned assignments (KLMouse.scroll_ticks   := 0) use variable
	; whitespace before `:=`, matching the existing non-suspended reset block's
	; style — tolerate any run of spaces there instead of assuming exactly one.
	for _, Field in ["scroll_ticks", "scroll_h_ticks", "scroll_start", "scroll_last"]
		Assert(RegExMatch(SuspendedBranch, "KLMouse\." . Field . "\s*:=\s*0"),
			"KL_Mouse_FlushScroll's A_IsSuspended branch must reset KLMouse." . Field
			. " := 0 before returning — mirroring KL_Mouse_ParkTick's own suspended-path "
			. "reset — otherwise stale pre-suspend timestamps corrupt the next post-resume "
			. "flush's duration/velocity (keylogger-mouse-scroll-suspend-reset)")
}
Test("mouse: KL_Mouse_FlushScroll resets the scroll accumulator on its suspended path (keylogger-mouse-scroll-suspend-reset)",
	_MMSG_FlushScrollResetsAccumulatorWhenSuspended)


_MMSG_StopClearsScrollFlushFn() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_Stop")
	Assert(Body != "", "KL_Mouse_Stop must exist in keylogger_mouse.ahk")
	Assert(InStr(Body, "scroll_flush_fn := unset") > 0,
		"KL_Mouse_Stop must set scroll_flush_fn := unset after cancelling the timer so re-entry cannot re-arm the stale bound reference")
}
Test("mouse: KL_Mouse_Stop clears scroll_flush_fn after cancellation", _MMSG_StopClearsScrollFlushFn)


; F-M09: the privacy filter (MF_ShouldFilter) must run BEFORE the counter bump, so a
; click/scroll in a password field / disabled app / private-browsing window does not
; accrue into session_clicks/session_scrolls — counts that ride into a later typing row.
; This is distinct from the suspend ordering above (which guards A_IsSuspended).
_MMSG_LUpFilterBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_OnLUp")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseClick")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_OnLUp must consult MF_ShouldFilter BEFORE KL_BumpMouseClick so a filtered window does not bump the click count (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_OnLUp filters before bumping the click count (mouse-counter-privacy-filter)", _MMSG_LUpFilterBeforeBump)

_MMSG_RUpFilterBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_OnRUp")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseClick")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_OnRUp must consult MF_ShouldFilter BEFORE KL_BumpMouseClick (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_OnRUp filters before bumping the click count (mouse-counter-privacy-filter)", _MMSG_RUpFilterBeforeBump)

_MMSG_MUpFilterBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_OnMUp")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseClick")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_OnMUp must consult MF_ShouldFilter BEFORE KL_BumpMouseClick (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_OnMUp filters before bumping the click count (mouse-counter-privacy-filter)", _MMSG_MUpFilterBeforeBump)

_MMSG_AccumScrollFiltersBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_AccumScroll")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseScroll")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_AccumScroll must consult MF_ShouldFilter BEFORE KL_BumpMouseScroll so a filtered window does not bump the scroll count (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_AccumScroll filters before bumping the scroll count (mouse-counter-privacy-filter)", _MMSG_AccumScrollFiltersBeforeBump)

_MMSG_AccumScrollHFiltersBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_AccumScrollH")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseScroll")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_AccumScrollH must consult MF_ShouldFilter BEFORE KL_BumpMouseScroll (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_AccumScrollH filters before bumping the scroll count (mouse-counter-privacy-filter)", _MMSG_AccumScrollHFiltersBeforeBump)

; Each real variadic release callback must consume the one pure measurement owner.
_MMSG_ReleaseUnique(Code, Pattern) {
	if !RegExMatch(Code, Pattern, &Found)
		return false
	if RegExMatch(Code, Pattern, , Found.Pos + Found.Len)
		return false
	return Found
}

_MMSG_ReleaseWriteCount(Code, Name) {
	Pattern := "i)(?<![\w.])(?:" . Name
		. "\b\h*(?::=|//=|\*\*=|<<=|>>>=|>>=|[+\-*/|&^.]=|\+\+|--)"
		. "|(?:\+\+|--)\h*" . Name . "\b)"
	Position := 1
	Count := 0
	while RegExMatch(Code, Pattern, &Found, Position) {
		Count += 1
		Position := Found.Pos + Found.Len
	}
	return Count
}

_MMSG_ReleaseMeasurePolicy(Body) {
	if Body == ""
		return false
	Code := _DriverMaskNonCode(&Body)
	Call := _MMSG_ReleaseUnique(Code,
		"im)^\h*(\w+)\h*:=\h*_KL_Mouse_MeasureGesture\h*\(\h*Gesture\h*,\h*mx\h*,\h*my\h*\)\h*$")
	if !IsObject(Call)
		return false
	if !IsObject(_MMSG_ReleaseUnique(Code, "i)\b_KL_Mouse_MeasureGesture\h*\("))
		return false
	Distance := _MMSG_ReleaseUnique(Code,
		"im)^\h*(\w+)\h*:=\h*" . Call[1] . "\.distance\h*$")
	Duration := _MMSG_ReleaseUnique(Code,
		"im)^\h*(\w+)\h*:=\h*" . Call[1] . "\.duration\h*$")
	if !IsObject(Distance) || !IsObject(Duration)
		return false
	for Name in [Call[1], Distance[1], Duration[1]] {
		if _MMSG_ReleaseWriteCount(Code, Name) != 1
			return false
	}
	Member := "(?<![\w.])" . Call[1] . "\h*\.\h*(?:distance|duration)\b"
	if RegExMatch(Code, "i)(?:" . Member
		. "\h*(?::=|//=|\*\*=|<<=|>>>=|>>=|[+\-*/|&^.]=|\+\+|--)"
		. "|(?:\+\+|--)\h*" . Member . ")")
		return false
	MouseRead := _MMSG_ReleaseUnique(Code, "i)\bMouseGetPos\h*\(")
	Filter := _MMSG_ReleaseUnique(Code, "i)\bMF_ShouldFilter\h*\(")
	Publish := _MMSG_ReleaseUnique(Code,
		"is)\bKL_Mouse_LogDrag\h*\([^)]*?Round\h*\(\h*" . Distance[1]
		. "\h*\)\h*,\h*" . Duration[1] . "\h*\)")
	return IsObject(MouseRead) && IsObject(Filter) && IsObject(Publish)
		&& MouseRead.Pos < Call.Pos && Call.Pos < Filter.Pos
		&& Call.Pos < Distance.Pos && Distance.Pos < Duration.Pos
		&& Duration.Pos < Publish.Pos
}

_MMSG_ReleaseMeasureConnection() {
	for Name in ["KL_Mouse_OnLUp", "KL_Mouse_OnRUp"] {
		Body := _DriverFuncBody(Name)
		Assert(_MMSG_ReleaseMeasurePolicy(Body),
			"each actual release callback must uniquely measure and forward its claimed receipt")
	}
}
Test("mouse: actual release callbacks retain the unique pure measurement owner", _MMSG_ReleaseMeasureConnection)

_MMSG_ReleaseMeasureMutations() {
	for Name in ["KL_Mouse_OnLUp", "KL_Mouse_OnRUp"] {
		Body := _DriverFuncBody(Name)
		Assert(_MMSG_ReleaseMeasurePolicy(Body))
		Variants := [
			"",
			"/*" . Chr(10) . Body . Chr(10) . "*/",
			StrReplace(Body, "Measurement := _KL_Mouse_MeasureGesture(Gesture, mx, my)",
				"; Measurement := _KL_Mouse_MeasureGesture(Gesture, mx, my)"),
			StrReplace(Body, "Measurement := _KL_Mouse_MeasureGesture(Gesture, mx, my)",
				'Ignored := "Measurement := _KL_Mouse_MeasureGesture(Gesture, mx, my)"'),
			StrReplace(Body, "_KL_Mouse_MeasureGesture(Gesture, mx, my)",
				"_KL_Mouse_MeasureGesture(Gesture, my, mx)"),
			StrReplace(Body, "duration := Measurement.duration", "duration := Measurement.distance"),
			StrReplace(Body, "duration := Measurement.duration",
				"duration := Measurement.duration" . Chr(10) . "DURATION := 0"),
			StrReplace(Body, "dist := Measurement.distance",
				"dist := Measurement.distance" . Chr(10) . "if true { DIST += 1 }"),
			Body . Chr(10) . "Measurement := _KL_Mouse_MeasureGesture(Gesture, mx, my)",
			StrReplace(Body, "dist := Measurement.distance",
				"dist := Measurement.distance" . Chr(10) . "Measurement.distance += 1"),
			StrReplace(Body, "duration := Measurement.duration",
				"duration := Measurement.duration" . Chr(10) . "MEASUREMENT.DURATION++"),
			StrReplace(Body, "duration := Measurement.duration",
				"duration := Measurement.duration" . Chr(10) . "if true { ++Measurement.duration }")
		]
		for Variant in Variants
			AssertFalse(_MMSG_ReleaseMeasurePolicy(Variant), "each changed actual-owner link must be rejected")
		Renamed := RegExReplace(Body, "i)\bMeasurement\b", "CapturedMeasure")
		Assert(_MMSG_ReleaseMeasurePolicy(Renamed), "coherent measurement-local renames retain the contract")
		Prose := Body . Chr(10) . "; Measurement := _KL_Mouse_MeasureGesture(Gesture, mx, my)"
			. Chr(10) . 'Ignored := "duration := Measurement.duration"'
		Assert(_MMSG_ReleaseMeasurePolicy(Prose), "prose cannot supply or invalidate executable ownership")
		Comparisons := Body . Chr(10) . "Other.duration := 0"
			. Chr(10) . "Ignored := Measurement.duration == 0"
		Assert(_MMSG_ReleaseMeasurePolicy(Comparisons), "other properties and comparisons are not receipt writes")
	}
}
Test("mouse: release measurement link rejects noncode, duplicate and overwritten owners", _MMSG_ReleaseMeasureMutations)

; Native scroll origins are raw A_TickCount. The actual owners must consume the
; captured origin once before publishing a new burst or computing its velocity.
_MMSG_ScrollNativePolicy(Body, Flush := false) {
	if Body == ""
		return false
	Code := _DriverMaskNonCode(&Body)
	Origin := _MMSG_ReleaseUnique(Code, "im)^\h*(\w+)\h*:=\h*KLMouse\."
		. (Flush ? "scroll_start" : "scroll_last") . "\h*$")
	Clock := _MMSG_ReleaseUnique(Code,
		"im)^\h*(\w+)\h*:=\h*IsSet\h*\(\h*NowTick\h*\)\h*\?\h*NowTick\h*:\h*A_TickCount\h*$")
	if !IsObject(Origin) || !IsObject(Clock) || Origin.Pos >= Clock.Pos
		return false
	Elapsed := _MMSG_ReleaseUnique(Code,
		"im)^\h*(\w+)\h*:=\h*TickElapsed64\h*\(\h*" . Origin[1]
		. "\h*,\h*" . Clock[1] . "\h*\)\h*$")
	if !IsObject(Elapsed) || !IsObject(_MMSG_ReleaseUnique(Code, "i)\bTickElapsed64\h*\("))
		return false
	for Name in [Origin[1], Clock[1], Elapsed[1]] {
		if _MMSG_ReleaseWriteCount(Code, Name) != 1
			return false
	}
	if Origin[1] = Clock[1] || Origin[1] = Elapsed[1] || Clock[1] = Elapsed[1]
		return false
	if Clock.Pos >= Elapsed.Pos
		return false
	AfterClock := SubStr(Code, Clock.Pos + Clock.Len)
	if RegExMatch(AfterClock, "i)\bKLMouse\.scroll_" . (Flush ? "(?:start|last)" : "last")
			. "\b(?!\h*:=)")
		return false
	if Flush {
		Velocity := _MMSG_ReleaseUnique(Code,
			"im)^\h*(\w+)\h*:=\h*\(\h*" . Elapsed[1]
			. "\h*>\h*0\h*\)\h*\?\h*Round\h*\(\h*total\h*/\h*\(\h*"
			. Elapsed[1] . "\h*/\h*1000\.0\h*\)\h*,\h*2\h*\)\h*:\h*0\h*$")
		return IsObject(Velocity) && Elapsed.Pos < Velocity.Pos
	}
	Gap := _MMSG_ReleaseUnique(Code,
		"i)\bif\h*\(\h*" . Origin[1] . "\h*>\h*0\h+and\h+"
		. Elapsed[1] . "\h*>\h*KLMouseConst\.SCROLL_BURST_GAP_MS\h*\)")
	return IsObject(Gap) && Elapsed.Pos < Gap.Pos
}

_MMSG_ScrollNativeConnections() {
	for Name in ["KL_Mouse_AccumScroll", "KL_Mouse_AccumScrollH", "KL_Mouse_FlushScroll"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", "the actual scroll owner must be defined")
		Assert(_MMSG_ScrollNativePolicy(Body, Name = "KL_Mouse_FlushScroll"),
			"actual scroll timing must use one captured native origin and final clock")
	}
}
Test("scroll-native64: actual owners preserve unique native timing authority", _MMSG_ScrollNativeConnections)

_MMSG_ScrollNativeMutations() {
	for Name in ["KL_Mouse_AccumScroll", "KL_Mouse_AccumScrollH", "KL_Mouse_FlushScroll"] {
		Body := _DriverFuncBody(Name)
		Flush := Name = "KL_Mouse_FlushScroll"
		Assert(_MMSG_ScrollNativePolicy(Body, Flush))
		OriginText := Flush ? "start := KLMouse.scroll_start" : "last := KLMouse.scroll_last"
		ClockText := "now := IsSet(NowTick) ? NowTick : A_TickCount"
		MovedOrigin := StrReplace(Body, OriginText, "; removed captured origin")
		MovedOrigin := StrReplace(MovedOrigin, ClockText, ClockText . Chr(10) . OriginText)
		Variants := [
			"",
			"/*" . Chr(10) . Body . Chr(10) . "*/",
			StrReplace(Body, "TickElapsed64(", "TickElapsed("),
			StrReplace(Body, "now := IsSet(NowTick) ? NowTick : A_TickCount",
				'Ignored := "now := IsSet(NowTick) ? NowTick : A_TickCount"'),
			StrReplace(Body, "now := IsSet(NowTick) ? NowTick : A_TickCount",
				"; now := IsSet(NowTick) ? NowTick : A_TickCount"),
			Body . Chr(10) . "if true { NOW := 0 }",
			Body . Chr(10) . (Flush ? "START++" : "LAST++"),
			Body . Chr(10) . (Flush ? "DURATION_MS := 0" : "ELAPSED := 0"),
			MovedOrigin
		]
		for Variant in Variants
			AssertFalse(_MMSG_ScrollNativePolicy(Variant, Flush), "noncode or overwritten clock authority must refuse")
		Prose := Body . Chr(10) . '; now := IsSet(NowTick) ? NowTick : A_TickCount'
			. Chr(10) . 'Ignored := "TickElapsed64(last, now)"'
		Assert(_MMSG_ScrollNativePolicy(Prose, Flush), "prose does not contribute clock authority")
		Comparisons := Body . Chr(10) . "Other.now := 0" . Chr(10) . "Ignored := now == 0"
		Assert(_MMSG_ScrollNativePolicy(Comparisons, Flush), "other properties and comparisons do not write the clock")
		Renamed := RegExReplace(Body, "i)\bnow\b", "CapturedNow")
		Renamed := RegExReplace(Renamed, "i)\b" . (Flush ? "start" : "last") . "\b", "CapturedOrigin")
		Renamed := RegExReplace(Renamed, "i)\b" . (Flush ? "duration_ms" : "elapsed") . "\b", "CapturedElapsed")
		Assert(_MMSG_ScrollNativePolicy(Renamed, Flush), "coherent local renames preserve the timing contract")
	}
}
Test("scroll-native64: actual timing rejects masked, noncode and rebound mutations", _MMSG_ScrollNativeMutations)
