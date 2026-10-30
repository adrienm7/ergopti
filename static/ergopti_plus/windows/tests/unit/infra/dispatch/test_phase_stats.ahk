; tests/unit/infra/dispatch/test_phase_stats.ahk

; ==============================================================================
; MODULE: Phase Stats Tests
; DESCRIPTION:
; The Windows port of _shared/lua/phase_stats_core.lua keeps the core's figures and
; evidence line, flushes on the latency summary's tick and records the phases macOS
; and Linux record. Before this a Windows log had no per-program child-process time
; and no parse or rebuild total to compare with the two other drivers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Figures =======
; ==========================
; ==========================

; A store with a driven clock and captured evidence lines.
_TPS_Store(InfoEnabled := true) {
	Context := { Clock: 1000.0, Lines: [] }
	Context.Store := PhaseStatsStore(() => InfoEnabled, (Template, Args*) => Context.Lines.Push(Format(Template, Args*)),
		() => Context.Clock)
	return Context
}

_TPS_Figures() {
	Context := _TPS_Store()
	Context.Store.Add("process.curl", 1)
	Context.Store.Add("process.curl", 3)
	Figures := Context.Store.Figures("process.curl")
	AssertEqual(2, Figures.N, "the occurrences")
	AssertEqual(4, Figures.TotalMs, "the total")
	AssertEqual(3, Figures.MaxMs, "the maximum")
	AssertEqual(0, Context.Store.Figures("never"), "a phase never recorded has no figures")
	Started := Context.Store.Now()
	Context.Clock += 7
	AssertEqual(7, Context.Store.Stop("boot.stage", Started), "a phase closes on the clock")
}
Test("phase stats: keeps count, total and maximum per phase (phase-stats-windows)", _TPS_Figures)

_TPS_Attribution() {
	Context := _TPS_Store()
	Context.Store.Add("toml.parse", 1)
	Context.Store.Add("process.curl", 4)
	Context.Clock += 10
	Since := Context.Store.Now()
	Context.Store.Add("menu.rebuild", 3)
	Context.Store.Add("process.git", 12.34)
	AssertEqual("process.git=12.3 ms, menu.rebuild=3.0 ms", Context.Store.RecentSince(Since),
		"the long phases of the held window, longest first")
	AssertEqual("", Context.Store.RecentSince(Context.Clock + 1), "none ran")
}
Test("phase stats: names the long phases that ran during a held window (phase-stats-windows)", _TPS_Attribution)





; =======================================
; =======================================
; ======= 2/ The Interval Summary =======
; =======================================
; =======================================

_TPS_OneLinePerFamily() {
	Context := _TPS_Store()
	Context.Store.Add("process.xdotool", 2)
	Context.Store.Add("process.curl", 8)
	Context.Store.Add("boot.stage", 40)
	Context.Store.Count("process.timeouts")
	AssertEqual(2, Context.Store.Flush(300.9), "boot and process")
	AssertEqual("Phase summary [boot] over 300 s: stage n=1 mean=40.00 max=40.00 total=40.0 ms.", Context.Lines[1],
		"the core's line, byte for byte")
	AssertEqual("Phase summary [process] over 300 s: curl n=1 mean=8.00 max=8.00 total=8.0 ms"
		. " | xdotool n=1 mean=2.00 max=2.00 total=2.0 ms | #timeouts=1.", Context.Lines[2],
		"the busiest phase first, the counters after")
	AssertEqual(0, Context.Store.Figures("boot.stage"), "the flush clears the figures")
}
Test("phase stats: one evidence line per family, in the core's format (phase-stats-windows)", _TPS_OneLinePerFamily)

_TPS_QuietBelowInfo() {
	Context := _TPS_Store(false)
	Context.Store.Add("process.curl", 1)
	AssertEqual(0, Context.Store.Flush(300), "nothing is formatted below INFO")
	AssertEqual(0, Context.Lines.Length, "nothing is written")
	AssertEqual(0, Context.Store.Figures("process.curl"), "the figures are still cleared")
}
Test("phase stats: formats nothing below INFO but still clears the figures (phase-stats-windows)", _TPS_QuietBelowInfo)

_TPS_MaybeFlush() {
	Context := _TPS_Store()
	AssertFalse(PhaseStats_MaybeFlush(Context.Store, 0), "the first tick only opens the interval")
	Context.Store.Add("process.curl", 1)
	AssertFalse(PhaseStats_MaybeFlush(Context.Store, 299999), "not before the interval")
	Assert(PhaseStats_MaybeFlush(Context.Store, 300000), "once the interval elapsed")
	AssertEqual(1, Context.Lines.Length, "one family")
	AssertFalse(PhaseStats_MaybeFlush(Context.Store, 300001), "the next interval started")
}
Test("phase stats: flushes on the summary tick once an interval has elapsed (phase-stats-windows)", _TPS_MaybeFlush)

_TPS_SameIntervalAsTheCore() {
	global _SharedDir
	Core := FileRead(_SharedDir . "\lua\phase_stats_core.lua", "UTF-8")
	Assert(RegExMatch(Core, "M\.DEFAULT_FLUSH_SECONDS\s*=\s*(\d+)", &Match), "the core names its interval")
	AssertEqual(Integer(Match[1]), PhaseStatsStore.DEFAULT_INTERVAL_SEC, "one interval on the three drivers")
}
Test("phase stats: the interval is the Lua core's (phase-stats-windows)", _TPS_SameIntervalAsTheCore)





; ============================================
; ============================================
; ======= 3/ The Phases Every OS Names =======
; ============================================
; ============================================

_TPS_BootStagesAreRecorded() {
	Store := PhaseStats()
	Before := Store.Figures("boot.stage")
	BeforeN := Before ? Before.N : 0
	BootProfile_StageBegin("phase stats test stage")
	BootProfile_StageEnd("phase stats test stage")
	AssertEqual(BeforeN + 1, Store.Figures("boot.stage").N, "a closed boot stage is one occurrence of boot.stage")
	Assert(Store.Figures("boot.stage_cpu"), "its process CPU is boot.stage_cpu")
}
Test("phase stats: a boot stage records boot.stage and boot.stage_cpu (phase-stats-windows)", _TPS_BootStagesAreRecorded)

_TPS_ProcessesAreRecorded() {
	Store := PhaseStats()
	Before := Store.Figures("process.cmd.exe")
	BeforeN := Before ? Before.N : 0
	ShellRunner_Exec(A_ComSpec . " /c exit 0")
	AssertEqual(BeforeN + 1, Store.Figures("process.cmd.exe").N, "a synchronous child is one occurrence of its program")
	AssertEqual("curl.exe", _SR_ExecutableName("C:\Program Files\tools\curl.exe"), "a path with spaces names its program")
	AssertEqual("unknown", _SR_ExecutableName(""), "no executable names no program")
	Claim := Map("PhaseProgram", "phasetest.exe", "PhaseStartedTick", A_TickCount - 25, "ClaimIdentity", 0, "Finished", false,
		"CompletionBusy", false)
	Claim["ClaimIdentity"] := ObjPtr(Claim)
	Assert(_SR_CompletionBegin(Claim), "the claim opens")
	Assert(Store.Figures("process.phasetest.exe").TotalMs >= 25, "an asynchronous child is timed from its spawn")
	AssertFalse(_SR_CompletionBegin(Claim), "a claim completes once")
	AssertEqual(1, Store.Figures("process.phasetest.exe").N, "and is counted once")
}
Test("phase stats: every child process records process.<program> (phase-stats-windows)", _TPS_ProcessesAreRecorded)

_TPS_ParsesAndRebuildsAreRecorded() {
	Store := PhaseStats()
	Before := Store.Figures("toml.parse")
	BeforeN := Before ? Before.N : 0
	ParseTomlFile(A_ScriptDir . "\does_not_exist_phase_stats.toml")
	AssertEqual(BeforeN + 1, Store.Figures("toml.parse").N, "a parse is one occurrence of toml.parse")
	Body := _DriverFuncBody("RebuildTrayMenu")
	Assert(Body != "", "RebuildTrayMenu must exist")
	AssertContains(Body, 'PhaseStats_Stop("menu.rebuild"', "a tray rebuild is timed")
	Tick := _DriverFuncBody("HotPath_FlushStatistics")
	Assert(Tick != "", "HotPath_FlushStatistics must exist")
	AssertContains(Tick, "PhaseStats_MaybeFlush()", "the phases flush on the summary's tick")
}
Test("phase stats: parses and tray rebuilds record their phases (phase-stats-windows)", _TPS_ParsesAndRebuildsAreRecorded)
