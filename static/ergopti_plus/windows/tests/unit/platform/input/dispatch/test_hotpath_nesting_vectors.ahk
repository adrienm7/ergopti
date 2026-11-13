; tests/unit/platform/input/dispatch/test_hotpath_nesting_vectors.ahk

; ==============================================================================
; MODULE: Hot-path Nesting Vectors Replay
; DESCRIPTION:
; Replays _shared/tests/corpus/diagnostics/hotpath_nesting_vectors.json through
; the Windows tracker. macOS and Linux replay the same file through
; _shared/metrics/engine/perf/hotpath_segments.lua new_nesting, so the three drivers judge a
; segment on the same own time and name the same parent (PAR-53). Windows used
; to judge the wall clock, which billed a slow child to its parent too.
; ==============================================================================

#Requires AutoHotkey v2.0

_HPNV_Corpus() {
	static Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\diagnostics\hotpath_nesting_vectors.json", "UTF-8"))
	return Corpus
}

_HPNV_ReplayCase(Corpus, Vector) {
	Reports := []
	Tracker := HotPathNesting((Report, NowMs) => Reports.Push(Report), 1)
	Verdicts := []
	for Step in Vector["steps"] {
		if (Step[1] == "open") {
			Tracker.Open(Step[2])
			continue
		}
		Name := Step[2]
		Limit := Corpus["thresholds"].Has(Name) ? Corpus["thresholds"][Name] : ""
		Verdicts.Push(Tracker.Close(Name, Step[3], Step[4], Limit))
	}
	Id := Vector["id"]
	AssertEqual(0, Tracker.Depth, Id . ": every frame is closed")
	AssertEqual(Vector["slow"].Length, Verdicts.Length, Id . ": one verdict per close")
	for Index, Expected in Vector["slow"]
		AssertEqual(Expected ? 1 : 0, Verdicts[Index] ? 1 : 0, Id . ": verdict of close " . Index)
	AssertEqual(Vector["reports"].Length, Reports.Length, Id . ": number of reports")
	for Index, Expected in Vector["reports"] {
		AssertEqual(Expected["segment"], Reports[Index].Segment, Id . ": report " . Index . " segment")
		AssertEqual(Expected["parent"], Reports[Index].Parent, Id . ": report " . Index . " parent")
		AssertEqual(Expected["total_ms"], Reports[Index].TotalMs, Id . ": report " . Index . " total")
		AssertEqual(Expected["own_ms"], Reports[Index].OwnMs, Id . ": report " . Index . " own")
	}
}

_HPNV_EveryVectorReplays() {
	Corpus := _HPNV_Corpus()
	Assert(Corpus["cases"].Length >= 10, "the corpus must hold its cases, or this replay proves nothing")
	for Vector in Corpus["cases"]
		_HPNV_ReplayCase(Corpus, Vector)
}
Test("hotpath nesting: every shared vector replays on the Windows tracker (PAR-53)", _HPNV_EveryVectorReplays)

; The stack must survive a frame that nothing encloses: a raise at the top of a
; thread would otherwise hold every later report back for the rest of the session.
_HPNV_SweepDeliversWhatAnAbandonedFrameHolds() {
	Reports := []
	Tracker := HotPathNesting((Report, NowMs) => Reports.Push(Report), 1)
	Tracker.Open(0)
	Tracker.Open(1)
	Tracker.Close("hotstring.expand", 1, 9, 5)
	AssertEqual(0, Reports.Length, "the report waits for a parent that will never close")
	AssertEqual(1, Tracker.Sweep(), "one frame was left open")
	AssertEqual(0, Tracker.Depth)
	AssertEqual(1, Reports.Length, "the sweep delivers it")
	AssertEqual("none", Reports[1].Parent)
}
Test("hotpath nesting: a sweep delivers what an abandoned frame holds (PAR-53)", _HPNV_SweepDeliversWhatAnAbandonedFrameHolds)

_HPNV_DepthCapNeverRaisesOnTheKeystrokePath() {
	Tracker := HotPathNesting((Report, NowMs) => 0, 1)
	loop HotPathNesting.MAX_DEPTH + 1
		Tracker.Open(A_Index)
	AssertEqual(1, Tracker.Depth, "the frame past the cap starts a fresh stack")
}
Test("hotpath nesting: the depth cap sweeps instead of raising (PAR-53)", _HPNV_DepthCapNeverRaisesOnTheKeystrokePath)

_HPNV_GateMatchesTheLuaWindow() {
	Lua := FileRead(_SharedDir . "\metrics\engine\perf\hotpath_segments.lua", "UTF-8")
	Assert(RegExMatch(Lua, "M\.LOG_WINDOW_MS = (\d+)", &Match), "the Lua window must stay declared")
	AssertEqual(Match[1] + 0, HotPathSlowGate.SLOW_LINE_WINDOW_MS, "one window on the three drivers")
	Gate := HotPathSlowGate()
	Window := HotPathSlowGate.SLOW_LINE_WINDOW_MS
	AssertEqual(0, Gate.Admit("a", 100), "the first occurrence is always admitted")
	AssertEqual(-1, Gate.Admit("a", 100 + Window - 1), "inside the window it is withheld")
	AssertEqual(0, Gate.Admit("b", 200), "each segment has its own window")
	AssertEqual(-1, Gate.Admit("a", 100 + Window - 1))
	AssertEqual(2, Gate.Admit("a", 100 + Window), "the next line counts what was withheld")
	AssertEqual(-1, Gate.Admit("a", 100 + Window + 1), "and opens a new window")
}
Test("hotpath nesting: the slow line's rate gate is the Lua one (PAR-53)", _HPNV_GateMatchesTheLuaWindow)

_HPNV_SubStepIsTransparent() {
	_HotPathResetForTest()
	Marks := HotPath_BreakdownBegin()
	Depth := _HotPathNestingOwner().Tracker.Depth
	HotPath_BreakdownMark("step", HotPath_Now(), Marks)
	AssertEqual(Depth, _HotPathNestingOwner().Tracker.Depth, "a mark closes the frame its HotPath_Now opened")
}
Test("hotpath nesting: a breakdown mark closes its frame (PAR-53)", _HPNV_SubStepIsTransparent)
