; tests/unit/infra/dispatch/test_hotpath_profiler_exclusive.ahk

; ==============================================================================
; MODULE: Hot-path profiler exclusive-time accounting
; DESCRIPTION:
; HotPath_LogIfSlow reported the raw wall clock between two QueryPerformanceCounter
; reads, with no notion of nesting. AHK is single-threaded, but Gui creation and
; COM calls PUMP the message loop, so another driver callback can run entirely
; INSIDE a measured segment — the driver documents that re-entrancy itself, and
; the tooltip generation counter exists because of it.
;
; The consequence was diagnostic, and it misled a whole audit: the largest number
; the profiler ever produced,
;   [HotPath] Slow Tooltip.Build: 112.86 ms (1 item(s))
; was a one-row tooltip that benches at roughly 7 ms, with a physically typed
; key's entire InputHook callback billed to it. Three different events printed
; identically — real in-segment work, OS descheduling, and the driver re-entering
; itself — so a genuine 3x regression in the measured code would have been
; indistinguishable from that noise floor.
;
; ROOT CAUSE ENCODED: a wall-clock segment that can contain other measured
; segments must report how much of its time belonged to them.
;
; SCOPE: behavioural. The profiler is pure timing plus one log call, so it is
; driven directly here through the logger test sink. infra/hotpath_profiler.ahk is
; not part of the headless runner's include graph, so it is pulled in explicitly.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../../infra/hotpath_profiler.ahk
; ==========================================================
; ==========================================================
; ======= 1/ Helpers =======================================
; ==========================================================
; ==========================================================

; Burn wall-clock time without sleeping — a Sleep would yield the thread and let
; the OS deschedule us, which is one of the very events this breakdown separates.
; A_TickCount advances in ~15.6 ms steps, so waiting for N ticks guarantees at
; least one full step of real elapsed time, comfortably above _HOTPATH_SLOW_MS.
_HPX_BurnTicks(Ticks) {
	Start := A_TickCount
	while (A_TickCount - Start < Ticks) {
	}
}

_HPX_FindLine(Lines, Needle) {
	Found := ""
	for Line in Lines
		if InStr(Line, Needle)
			Found := Line
	return Found
}

_HPX_Number(Line, Pattern, What) {
	Assert(RegExMatch(Line, Pattern, &M) > 0,
		"the profiler line must report " . What . " — got: " . Line)
	return M[1] + 0
}

; Keep clock and sink evidence numeric: a missing diagnostic must be actionable
; without dumping unrelated captured messages or changing profiler thresholds.
_HPX_MissingLineEvidence(Label, StartTicks, EndTicks, Lines) {
	global _HOTPATH_QPC_FREQ, _HOTPATH_SLOW_MS, _HOTPATH_SLOW_MS_BY_SEGMENT, _LOGGER_WARN_ENABLED
	return Format(" [pre_log_ticks={1}, frequency={2}, threshold_ms={3}, warning_enabled={4}, captured={5}]",
		EndTicks - StartTicks, _HOTPATH_QPC_FREQ,
		_HOTPATH_SLOW_MS_BY_SEGMENT.Get(Label, _HOTPATH_SLOW_MS), _LOGGER_WARN_ENABLED, Lines.Length)
}





; ==========================================================
; ==========================================================
; ======= 2/ A contained segment is not billed twice =======
; ==========================================================
; ==========================================================

_HPX_NestedSegmentIsNotBilledToItsParent() {
	_HotPathResetForTest()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Outer := HotPath_Now()
	Inner := HotPath_Now()
	_HPX_BurnTicks(25)
	InnerEnd := PerfClockTicks()
	HotPath_LogIfSlow("HpxInner", Inner, "inner")
	HotPath_LogIfSlow("HpxOuter", Outer, "outer")
	LoggerClearTestSink()

	InnerLine := _HPX_FindLine(Captured, "Slow HpxInner:")
	Assert(InnerLine != "",
		"the inner segment must be reported — it burned well past _HOTPATH_SLOW_MS"
		. _HPX_MissingLineEvidence("HpxInner", Inner, InnerEnd, Captured))
	Assert(InStr(InnerLine, "parent HpxOuter") > 0,
		"the slow child must name its parent — got: " . InnerLine)
	Assert(_HPX_FindLine(Captured, "Slow HpxOuter") == "",
		"a segment whose time all went to a child is not slow. Tooltip.Build reported 112.86 ms for roughly 7 ms of its own work because a re-entrant keystroke callback ran inside it, and the headline number gave no way to tell")
}

; A parent slow on its own time reports both numbers, and they must describe the
; same interval: own + the child's total = the parent's total.
_HPX_SlowParentReportsOwnAndTotal() {
	_HotPathResetForTest()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Outer := HotPath_Now()
	_HPX_BurnTicks(25)
	Inner := HotPath_Now()
	_HPX_BurnTicks(25)
	HotPath_LogIfSlow("HpxChild", Inner, "child")
	HotPath_LogIfSlow("HpxParent", Outer, "parent")
	LoggerClearTestSink()

	ChildLine := _HPX_FindLine(Captured, "Slow HpxChild:")
	ParentLine := _HPX_FindLine(Captured, "Slow HpxParent:")
	Assert(ChildLine != "" && ParentLine != "", "both segments burned past the threshold on their own time")
	ChildTotal := _HPX_Number(ChildLine, "([\d.]+) ms total", "its total time")
	ParentOwn := _HPX_Number(ParentLine, "([\d.]+) ms own", "its own time")
	ParentTotal := _HPX_Number(ParentLine, "([\d.]+) ms total", "its total time")
	Assert(ParentOwn < ParentTotal,
		"own time must be the wall clock MINUS the nested time — if it still includes the child, the judgement is the wall clock's")
	Assert(Abs(ParentTotal - (ParentOwn + ChildTotal)) <= 0.05,
		"own + nested must reconstitute the wall clock, or the numbers do not describe the same interval")
	Assert(InStr(ParentLine, "parent none") > 0, "a top-level segment has no parent — got: " . ParentLine)
	Assert(InStr(ParentLine, "(0 similar since the last line).") > 0, "the line is the macOS and Linux one — got: " . ParentLine)
}

; A leaf segment has nothing inside it: all of its time is its own, and the
; caller's context survives on the line that follows.
_HPX_LeafSegmentKeepsThePlainLine() {
	_HotPathResetForTest()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Leaf := HotPath_Now()
	_HPX_BurnTicks(25)
	LeafEnd := PerfClockTicks()
	HotPath_LogIfSlow("HpxLeaf", Leaf, "leaf")
	LoggerClearTestSink()

	LeafLine := _HPX_FindLine(Captured, "Slow HpxLeaf:")
	Assert(LeafLine != "", "the leaf segment must be reported"
		. _HPX_MissingLineEvidence("HpxLeaf", Leaf, LeafEnd, Captured))
	AssertEqual(_HPX_Number(LeafLine, "([\d.]+) ms total", "its total time"),
		_HPX_Number(LeafLine, "([\d.]+) ms own", "its own time"),
		"a segment with nothing measured inside it owns every millisecond")
	DetailLine := _HPX_FindLine(Captured, "Slow HpxLeaf detail:")
	Assert(InStr(DetailLine, "detail: leaf.") > 0,
		"the caller-supplied detail must survive the new formatting — it is what identifies the offending character and buffer")
}

; The gate limits the line, not the judgement or the latency summaries.
_HPX_RepeatedSlowSegmentIsRateLimited() {
	_HotPathResetForTest()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Freq := PerfClockFrequency()
	loop 3
		HotPath_LogIfSlow("HpxRepeat", HotPath_Now() - Freq)
	LoggerClearTestSink()
	Lines := 0
	for Line in Captured
		Lines += InStr(Line, "Slow HpxRepeat:") ? 1 : 0
	AssertEqual(1, Lines, "one line per segment per window")
}

; The threshold is the whole point of the profiler: a fast segment stays silent.
_HPX_FastSegmentStaysSilent() {
	_HotPathResetForTest()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Fast := HotPath_Now()
	HotPath_LogIfSlow("HpxFast", Fast, "fast")
	; Non-vacuity probe: without it, a silenced WARNING level or a detached sink
	; would make "nothing was captured" pass for entirely the wrong reason.
	LoggerWarn("HpxProbe", "hpx-sink-liveness-probe")
	LoggerClearTestSink()

	Assert(_HPX_FindLine(Captured, "hpx-sink-liveness-probe") != "",
		"the test sink must be receiving WARNING lines, or the silence asserted below proves nothing")
	Assert(_HPX_FindLine(Captured, "Slow HpxFast") == "",
		"a sub-threshold segment must log nothing at all — the profiler stays on permanently only because normal typing is silent")
}

; The suite resets the tracker between cases while earlier production segments
; may still hold open frames. The reset kept the child time billed to those
; frames, and the next segment opened at the same depth subtracted it from its
; own time: the nested case above stayed silent on every CI run.
_HPX_ResetForgetsDiscardedBilling() {
	_HotPathResetForTest()
	; Three frames left open, the third slow and billed to the second, as a
	; segment that raised before its close leaves them.
	HotPath_Now()
	HotPath_Now()
	Abandoned := HotPath_Now()
	_HPX_BurnTicks(100)
	HotPath_LogIfSlow("HpxAbandoned", Abandoned, "abandoned")
	_HotPathResetForTest()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Outer := HotPath_Now()
	Inner := HotPath_Now()
	_HPX_BurnTicks(25)
	InnerEnd := PerfClockTicks()
	HotPath_LogIfSlow("HpxInner", Inner, "inner")
	HotPath_LogIfSlow("HpxOuter", Outer, "outer")
	LoggerClearTestSink()

	Assert(_HPX_FindLine(Captured, "Slow HpxInner:") != "",
		"a segment opened after a reset owns all of its time, whatever the discarded frames held"
		. _HPX_MissingLineEvidence("HpxInner", Inner, InnerEnd, Captured))
	Assert(_HPX_FindLine(Captured, "Slow HpxAbandoned") == "",
		"the discarded frames' pending report is forgotten with them")
}


Test("hotpath profiler: a nested segment is not billed to its parent",
	_HPX_NestedSegmentIsNotBilledToItsParent)
Test("hotpath profiler: a slow parent reports its own and total time",
	_HPX_SlowParentReportsOwnAndTotal)
Test("hotpath profiler: a leaf segment owns its time and keeps its detail",
	_HPX_LeafSegmentKeepsThePlainLine)
Test("hotpath profiler: a repeated slow segment is rate limited",
	_HPX_RepeatedSlowSegmentIsRateLimited)
Test("hotpath profiler: a fast segment stays silent",
	_HPX_FastSegmentStaysSilent)
Test("hotpath profiler: a reset forgets the time billed to the frames it discards",
	_HPX_ResetForgetsDiscardedBilling)
