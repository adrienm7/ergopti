; tests/unit/modules/shortcuts/test_keepawake_session_parity.ahk

; ==============================================================================
; MODULE: Keep-Awake Session Parity Tests
; DESCRIPTION:
; Pins the Windows keep-awake session to the macOS and Linux ones (small native
; units parity campaign): its jitter tick and cursor return read the shared
; [keep_awake] registry (SNU-01), a finished session is the day's awake_ms
; through a passive_period row of kind awake (SNU-02, maintainer decision
; KMD-3), and the session's start and stop are logged (SNU-03).
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
		Section["tick_min_ms"] := "777", Section["tick_max_ms"] := "777"
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

Test("keep-awake: the jitter tick and cursor return read the shared registry (snu-01)", _KASP_TickFromRegistry)
Test("keep-awake: a finished session is credited to awake_ms (snu-02)", _KASP_SessionCredited)
Test("keep-awake: a session stopped by a pause is credited after the resume (snu-02)", _KASP_PausedSessionKept)
Test("keep-awake: stopping an idle keep-awake credits nothing (snu-02)", _KASP_IdleStopCreditsNothing)
Test("keep-awake: the session's start and stop are logged (snu-03)", _KASP_StopLogged)
