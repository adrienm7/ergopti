; tests/unit/core/timing/test_reload_timing.ahk

; ==============================================================================
; MODULE: Reload Duration Tests (Windows)
; DESCRIPTION:
; A Windows Reload was never measured: macOS logs « Reload completed in N ms »
; after hs.reload() and Linux across its daemon restart, both judged against
; [budgets] driver_reload_ms, while Windows only judged its boot. A slow reload
; was invisible in the Windows log and to tools/dev/field-log-analyse.py
; (reload-budget-windows, timing parity campaign, November 22, 2026). These
; tests pin the hand-off through the successor's environment, the line and the
; budget warning, the refusals, and the two call sites.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body(Lines) with the formatted log lines captured; everything is put back.
_RTM_WithLog(Body) {
	global _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED, _TimingsCache, _LOGGER_DEDUP_KEY
	Saved := { Sink: _LOGGER_TEST_SINK, Info: _LOGGER_INFO_ENABLED, Warn: _LOGGER_WARN_ENABLED,
		Error: _LOGGER_ERROR_ENABLED }
	if (Type(_TimingsCache) != "Map")
		TimingsLoadShared()
	Lines := []
	try {
		_LOGGER_INFO_ENABLED := true, _LOGGER_WARN_ENABLED := true, _LOGGER_ERROR_ENABLED := true
		; A line equal to the previous test's would be withheld by the consecutive dedup.
		_LOGGER_DEDUP_KEY := ""
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Body.Call(Lines)
	} finally {
		_LOGGER_TEST_SINK := Saved.Sink
		_LOGGER_INFO_ENABLED := Saved.Info
		_LOGGER_WARN_ENABLED := Saved.Warn
		_LOGGER_ERROR_ENABLED := Saved.Error
		try EnvSet(ReloadTimingEnvName(), "")
	}
}

; How many captured lines contain Needle.
_RTM_Count(Lines, Needle) {
	Count := 0
	for Line in Lines
		if InStr(Line, Needle)
			Count += 1
	return Count
}

_RTM_LaunchCarriesTheTick() {
	_RTM_WithLog(_RTM_LaunchCarriesTheTickBody)
}
_RTM_LaunchCarriesTheTickBody(Lines) {
	State := Map("seen", "")
	Result := ReloadTimingLaunchStamped(_RTM_Launch.Bind(State), 12345)
	AssertEqual("successor", Result, "the launch's descriptor is returned")
	AssertEqual("12345", State["seen"], "the successor's CreateProcess sees the launch tick")
	AssertEqual("", EnvGet(ReloadTimingEnvName()), "no later child of this instance inherits it")
	AssertEqual(0, _RTM_Count(Lines, "ERROR"), "a stamped launch logs no error")
}
_RTM_Launch(State) {
	State["seen"] := EnvGet(ReloadTimingEnvName())
	return "successor"
}
Test("reload timing: the successor inherits the launch tick and nothing else does (reload-budget-windows)",
	_RTM_LaunchCarriesTheTick)

_RTM_RefusedLaunchClears() {
	_RTM_WithLog(_RTM_RefusedLaunchClearsBody)
}
_RTM_RefusedLaunchClearsBody(Lines) {
	AssertThrows(() => ReloadTimingLaunchStamped(_RTM_Throw, 1), "the launch's refusal reaches the caller")
	AssertEqual("", EnvGet(ReloadTimingEnvName()), "a refused launch leaves no tick behind")
}
_RTM_Throw() {
	throw Error("no successor")
}
Test("reload timing: a refused launch leaves no tick behind (reload-budget-windows)", _RTM_RefusedLaunchClears)

_RTM_TakeIsOneShot() {
	_RTM_WithLog(_RTM_TakeIsOneShotBody)
}
_RTM_TakeIsOneShotBody(Lines) {
	EnvSet(ReloadTimingEnvName(), "777")
	AssertEqual("777", ReloadTimingTakeInherited(), "the successor reads the tick it inherited")
	AssertEqual("", EnvGet(ReloadTimingEnvName()), "and clears it before starting its own workers")
	AssertEqual("", ReloadTimingTakeInherited(), "a second read finds nothing")
}
Test("reload timing: the inherited tick is taken once (reload-budget-windows)", _RTM_TakeIsOneShot)

_RTM_ReportsAndJudges() {
	_RTM_WithLog(_RTM_OverBudgetBody)
	_RTM_WithLog(_RTM_WithinBudgetBody)
}
_RTM_OverBudgetBody(Lines) {
	Budget := TimingsGet("budgets", "driver_reload_ms")
	Took := Budget + 500
	AssertEqual(Took, ReloadTimingComplete("1000", 1000 + Took), "the duration is boot tick minus launch tick")
	AssertEqual(1, _RTM_Count(Lines, "Reload completed in " . Took . " ms (reload request to boot complete)."),
		"the line macOS and Linux write, read by the field log analyser")
	AssertEqual(1, _RTM_Count(Lines, "Over budget: reload took " . Took . " ms (budget " . Budget . " ms)."),
		"a reload over [budgets] driver_reload_ms is the shared overrun warning")
}
_RTM_WithinBudgetBody(Lines) {
	AssertEqual(900, ReloadTimingComplete("100", 1000))
	AssertEqual(1, _RTM_Count(Lines, "Reload completed in 900 ms"))
	AssertEqual(0, _RTM_Count(Lines, "Over budget"), "a reload within its budget writes no warning")
}
Test("reload timing: a completed reload is logged and judged against driver_reload_ms (reload-budget-windows)",
	_RTM_ReportsAndJudges)

_RTM_Unmeasured() {
	_RTM_WithLog(_RTM_AbsentBody)
	_RTM_WithLog(_RTM_MalformedBody)
	_RTM_WithLog(_RTM_FutureBody)
}
_RTM_AbsentBody(Lines) {
	AssertEqual("", ReloadTimingComplete("", 1000), "an ordinary start reports no reload")
	AssertEqual(0, Lines.Length, "and logs nothing")
}
_RTM_MalformedBody(Lines) {
	AssertEqual("", ReloadTimingComplete("12ab", 1000))
	AssertEqual(1, _RTM_Count(Lines, "The reload launch time is malformed"), "a malformed tick is named")
	AssertEqual(0, _RTM_Count(Lines, "Reload completed"))
}
_RTM_FutureBody(Lines) {
	AssertEqual("", ReloadTimingComplete("2000", 1000))
	AssertEqual(1, _RTM_Count(Lines, "lies 1000 ms in the future"), "a tick ahead of the boot is named")
	AssertEqual(0, _RTM_Count(Lines, "Reload completed"))
}
Test("reload timing: an absent, malformed or future tick goes unmeasured (reload-budget-windows)", _RTM_Unmeasured)

; The two call sites: lifecycle.ahk registers hotkeys and ErgoptiPlus.ahk is the
; driver, so neither can be included by this suite.
_RTM_CallSites() {
	Launch := _DriverFuncBody("LifecycleLaunchSuccessor")
	Assert(Launch != "", "LifecycleLaunchSuccessor() must exist")
	Assert(RegExMatch(Launch, "s)ReloadTimingLaunchStamped\(\(\) => ReloadSuccessorLaunch\("),
		"the successor is launched with the launch tick in its environment")
	SplitPath(A_ScriptDir, , &WindowsDir)
	Boot := ""
	try Boot := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	Assert(Boot != "", "ErgoptiPlus.ahk must be readable")
	TakeAt := InStr(Boot, "_ReloadInheritedLaunchTick := ReloadTimingTakeInherited()")
	GateAt := InStr(Boot, "; --- Single-owner gate")
	BootDoneAt := InStr(Boot, 'LoggerInfo("BootProfile", "Boot complete in {1} ms (since process start).", _BootTotalMs)')
	CompleteAt := InStr(Boot, "ReloadTimingComplete(_ReloadInheritedLaunchTick)")
	Assert(TakeAt > 0 && GateAt > TakeAt, "the successor takes the tick at its first statements, before any child starts")
	Assert(BootDoneAt > 0 && CompleteAt > BootDoneAt, "the reload is judged once the boot is complete")
}
Test("reload timing: the successor launch and the boot completion carry the measure (reload-budget-windows)",
	_RTM_CallSites)
