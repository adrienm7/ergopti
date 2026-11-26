; tests/unit/modules/shortcuts/test_keepawake_session_parity.ahk

; ==============================================================================
; MODULE: Keep-Awake Session Parity Tests
; DESCRIPTION:
; Pins the Windows keep-awake session to the macOS and Linux ones (small native
; units parity campaign): its jitter tick and cursor return read the shared
; [keep_awake] registry (SNU-01), a finished session is the day's awake_ms
; through a passive_period row of kind awake (SNU-02, maintainer decision
; KMD-3), and the session's start and stop are logged (SNU-03). The jitter
; radius is the registry's too (SNU-13), and an accepted exit credits the
; session still running (SNU-11).
;
; The session runs on a fake cancellation hook and its timers are never armed,
; so no case moves the user's cursor.
; ==============================================================================

#Requires AutoHotkey v2.0




; =========================================
; =========================================
; ======= 1/ Fixtures =====================
; =========================================
; =========================================

; Stands in for the cancellation InputHook: StopActivitySimulation calls Stop().
class _KASP_FakeHook {
	Stop() {
	}
}

; Records the rows a system event owner hands the keystats journal.
class _KASP_Journal {
	__New() {
		this.Rows := []
		this.Allowed := true
		this.Tick := 0
	}
	Frame() {
		this.Tick += 1
		return Map("tick", this.Tick, "timestamp", "2026-11-21 10:00:00.000")
	}
	Append(Entry, Guard, Commit) {
		if !Guard.Call()
			return false
		this.Rows.Push(Entry.Clone())
		Commit.Call()
		return true
	}
}

; Runs Body with a keep-awake session started DurationMs ago, a recording
; system event owner in place of the keystats' one, and every log line kept.
_KASP_WithSession(DurationMs, Body) {
	global ActivitySimulation, AwakeInputHook, AwakeStartedTick, _LOGGER_INFO_ENABLED, _LOGGER_DEDUP_KEY
	if !IsSet(ActivitySimulation)
		ActivitySimulation := false
	AssertFalse(ActivitySimulation, "the keep-awake session tests require an idle production state")
	Assert(!IsObject(AwakeInputHook), "the keep-awake session tests require no live cancellation hook")
	Journal := _KASP_Journal()
	Lines := []
	SavedOwner := KLWatch.system_events
	SavedInitialized := Keystats.initialized
	SavedTick := AwakeStartedTick
	SavedInfo := _LOGGER_INFO_ENABLED
	try {
		; The consecutive dedup would hide a line an earlier case logged last.
		_LOGGER_INFO_ENABLED := true, _LOGGER_DEDUP_KEY := ""
		KLWatch.system_events := KLSystemEventOwner(Journal.Frame.Bind(Journal),
			Journal.Append.Bind(Journal), () => Journal.Allowed)
		Keystats.initialized := true
		LoggerSetTestSink((Line) => Lines.Push(Line))
		ActivitySimulation := true
		AwakeInputHook := _KASP_FakeHook()
		AwakeStartedTick := DllCall("GetTickCount64", "Int64") - DurationMs
		Body.Call(Journal, Lines)
	} finally {
		LoggerClearTestSink()
		_LOGGER_INFO_ENABLED := SavedInfo
		SetTimer(StopActivitySimulation, 0)
		ActivitySimulation := false
		AwakeInputHook := ""
		AwakeStartedTick := SavedTick
		KLWatch.system_events := SavedOwner
		Keystats.initialized := SavedInitialized
	}
}

; The passive_period rows of kind awake the journal received.
_KASP_AwakeRows(Journal) {
	Rows := []
	for Entry in Journal.Rows
		if Entry["action"] == "passive_period" && Entry["kind"] == "awake"
			Rows.Push(Entry)
	return Rows
}

; The log lines that contain Needle.
_KASP_Matching(Lines, Needle) {
	Found := 0
	for Line in Lines
		if InStr(Line, Needle, true)
			Found += 1
	return Found
}




; =========================================
; =========================================
; ======= 2/ Cases ========================
; =========================================
; =========================================

; SNU-01: the tick bounds are the registry's, not a driver copy.
_KASP_TickFromRegistry() {
	global _TimingsCache
	Section := _TimingsCache["keep_awake"]
	SavedMin := Section["tick_min_ms"], SavedMax := Section["tick_max_ms"]
	try {
		Section["tick_min_ms"] := 777, Section["tick_max_ms"] := 777
		AssertEqual(777, AwakeNextTickMs(), "the jitter tick follows the shared [keep_awake] bounds")
	} finally {
		Section["tick_min_ms"] := SavedMin, Section["tick_max_ms"] := SavedMax
	}
	Source := FSReadStrict(_DriverProductionFileForSymbol("SimulateActivity"))
	Body := _DriverExtractFunctionBody(&Source, "SimulateActivity")
	AssertContains(Body, 'TimingsGet("keep_awake", "return_delay_ms")',
		"the cursor returns after the shared [keep_awake] delay")
	AssertFalse(InStr(Source, "AWAKE_TICK_MIN_MS", true) || InStr(Source, "AWAKE_RETURN_MS", true),
		"no driver copy of the shared keep-awake timings remains")
}

; SNU-02: a finished session is one passive_period row of kind awake.
_KASP_SessionCredited() {
	_KASP_WithSession(5000, (Journal, Lines) => (
		StopActivitySimulation(false),
		_KASP_AssertOneAwakeRow(Journal, 5000)))
}

_KASP_AssertOneAwakeRow(Journal, AtLeastMs) {
	Rows := _KASP_AwakeRows(Journal)
	AssertEqual(1, Rows.Length, "a finished keep-awake session is credited once to awake_ms")
	AssertTrue(Rows[1]["duration_ms"] >= AtLeastMs && Rows[1]["duration_ms"] < AtLeastMs + 60000,
		"the credited duration is the session's length: " . Rows[1]["duration_ms"])
	AssertEqual("system_event", Rows[1]["type"])
}

; SNU-02: a pause stops the session; its row waits for the drain after resume.
_KASP_PausedSessionKept() {
	_KASP_WithSession(3000, (Journal, Lines) => (
		Journal.Allowed := false,
		StopActivitySimulation(false),
		AssertEqual(0, _KASP_AwakeRows(Journal).Length, "a paused journal receives nothing yet"),
		AssertEqual(0, _KASP_Matching(Lines, "System event delivery remains incomplete"),
			"a session held for the resume is not a delivery failure"),
		Journal.Allowed := true,
		KLWatch.system_events.Drain(),
		_KASP_AssertOneAwakeRow(Journal, 3000)))
}

; SNU-02: stopping an idle keep-awake credits nothing.
_KASP_IdleStopCreditsNothing() {
	_KASP_WithSession(1000, (Journal, Lines) => (
		StopActivitySimulation(false),
		StopActivitySimulation(false),
		AssertEqual(1, _KASP_AwakeRows(Journal).Length, "a second stop has no session to credit")))
}

; SNU-03: the start and the stop are logged, as macOS and Linux do.
_KASP_StopLogged() {
	_KASP_WithSession(1000, (Journal, Lines) => (
		StopActivitySimulation(false),
		AssertEqual(1, _KASP_Matching(Lines, "Keep-awake stopped."), "the stop is logged once")))
	Source := FSReadStrict(_DriverProductionFileForSymbol("StartActivitySimulation"))
	Body := _DriverExtractFunctionBody(&Source, "StartActivitySimulation")
	AssertContains(Body, 'LoggerInfo("shortcuts", "Keep-awake started.")', "the start is logged")
}

; Lets a queued one-shot timer run.
_KASP_SettleTimers() {
	Started := A_TickCount
	while A_TickCount - Started < 100
		Sleep(10)
}

; Places the jitter origin OffsetPx right of the cursor, sets the registry's
; jitter_px to RadiusPx, runs the movement check, and answers whether the
; session survived. The cursor is only read.
_KASP_SurvivesOffset(OffsetPx, RadiusPx) {
	global _TimingsCache, AwakeOriginX, AwakeOriginY, ActivitySimulation
	Section := _TimingsCache["keep_awake"]
	SavedRadius := Section["jitter_px"]
	SavedX := AwakeOriginX, SavedY := AwakeOriginY
	Result := { Survived: false }
	try {
		Section["jitter_px"] := RadiusPx
		_KASP_WithSession(1000, _KASP_CheckOffset.Bind(OffsetPx, Result))
	} finally {
		Section["jitter_px"] := SavedRadius
		AwakeOriginX := SavedX, AwakeOriginY := SavedY
	}
	return Result.Survived
}

_KASP_CheckOffset(OffsetPx, Result, Journal, Lines) {
	global AwakeOriginX, AwakeOriginY, ActivitySimulation
	Position := MCGetPos()
	AwakeOriginX := Position["x"] + OffsetPx
	AwakeOriginY := Position["y"]
	AwakeCheckMouseMoved()
	_KASP_SettleTimers()
	Result.Survived := ActivitySimulation
}

; SNU-13: the jitter radius is the registry's, which macOS reads too, not an
; 80 px driver copy.
_KASP_JitterFromRegistry() {
	AssertFalse(_KASP_SurvivesOffset(5, 3), "a move beyond the shared jitter_px stops the session")
	AssertTrue(_KASP_SurvivesOffset(5, 10), "positive control: a move within it keeps the session")
	Source := FSReadStrict(_DriverProductionFileForSymbol("SimulateActivity"))
	Body := _DriverExtractFunctionBody(&Source, "SimulateActivity")
	AssertContains(Body, "Random(-JitterPx, JitterPx)", "the jitter draws within the shared radius")
	AssertContains(Body, "JitterPx := AwakeJitterPx()", "the tick reads the shared radius")
	AssertFalse(InStr(Source, "AWAKE_JITTER_PX", true), "no driver copy of the jitter radius remains")
}

; SNU-11: a session still running when the exit is accepted is credited. The
; stop sits after the last refusal gate, so a refused exit keeps keep-awake on.
_KASP_ExitCreditsRunningSession() {
	Body := _StripFullLineComments(_DriverFuncBody("Ergopti_OnShutdown"))
	Assert(Body != "", "the lifecycle owner must remain source-visible")
	Terminal := InStr(Body, "ShutdownTerminal := true", true)
	Stop := InStr(Body, "StopActivitySimulation(false)", true)
	Keystats := InStr(Body, "KeystatsStopped := KL_Stop()", true)
	Assert(Terminal > 0 && Stop > Terminal, "the exit stops keep-awake only once no gate can refuse it")
	Assert(Keystats > Stop, "the session is credited before the keystats' terminal drain")
	AssertFalse(InStr(SubStr(Body, 1, Terminal), "StopActivitySimulation", true),
		"no refusal-capable part of the exit stops keep-awake")
	; The stop that runs there credits once and shows nothing.
	_KASP_WithSession(4000, (Journal, Lines) => (
		StopActivitySimulation(false),
		_KASP_AssertOneAwakeRow(Journal, 4000),
		AssertEqual(1, _KASP_Matching(Lines, "Keep-awake stopped."), "the exit's stop is logged")))
}

Test("keep-awake: the jitter tick and cursor return read the shared registry (snu-01)", _KASP_TickFromRegistry)
Test("keep-awake: the jitter radius reads the shared registry (snu-13)", _KASP_JitterFromRegistry)
Test("keep-awake: an accepted exit credits the running session (snu-11)", _KASP_ExitCreditsRunningSession)
Test("keep-awake: a finished session is credited to awake_ms (snu-02)", _KASP_SessionCredited)
Test("keep-awake: a session stopped by a pause is credited after the resume (snu-02)", _KASP_PausedSessionKept)
Test("keep-awake: stopping an idle keep-awake credits nothing (snu-02)", _KASP_IdleStopCreditsNothing)
Test("keep-awake: the session's start and stop are logged (snu-03)", _KASP_StopLogged)
