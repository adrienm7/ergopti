; tests/unit/test_hotpath_profiler_exclusive.ahk

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
; driven directly here through the logger test sink. lib/hotpath_profiler.ahk is
; not part of the headless runner's include graph, so it is pulled in explicitly.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../lib/hotpath_profiler.ahk





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





; ==========================================================
; ==========================================================
; ======= 2/ A contained segment is not billed twice =======
; ==========================================================
; ==========================================================

_HPX_NestedSegmentIsNotBilledToItsParent() {
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Outer := HotPath_Now()
	Inner := HotPath_Now()
	_HPX_BurnTicks(25)
	HotPath_LogIfSlow("HpxInner", Inner, "inner")
	HotPath_LogIfSlow("HpxOuter", Outer, "outer")
	LoggerClearTestSink()

	InnerLine := _HPX_FindLine(Captured, "Slow HpxInner")
	OuterLine := _HPX_FindLine(Captured, "Slow HpxOuter")
	Assert(InnerLine != "",
		"the inner segment must be reported — it burned well past _HOTPATH_SLOW_MS")
	Assert(OuterLine != "",
		"the outer segment must be reported — it fully contains the inner one")

	InnerMs := _HPX_Number(InnerLine, "Slow HpxInner: ([\d.]+) ms", "its wall clock")
	OuterMs := _HPX_Number(OuterLine, "Slow HpxOuter: ([\d.]+) ms", "its wall clock")
	NestedMs := _HPX_Number(OuterLine, "nested ([\d.]+) ms", "how much of its time ran in nested segments")
	ExclMs := _HPX_Number(OuterLine, "excl ([\d.]+) ms", "its exclusive time")

	Assert(NestedMs >= InnerMs * 0.9,
		"a segment that fully contains another must attribute that inner segment's time to its nested total. Tooltip.Build reported 112.86 ms for roughly 7 ms of its own work because a re-entrant keystroke callback ran inside it, and the headline number gave no way to tell")
	Assert(ExclMs < InnerMs,
		"the exclusive figure must be the wall clock MINUS the nested time — if it still includes the child, the breakdown is decorative")
	Assert(Abs(OuterMs - (ExclMs + NestedMs)) <= 0.05,
		"exclusive + nested must reconstitute the wall clock, or the three numbers on the line do not describe the same interval")
}

; A leaf segment has nothing inside it, and its line must stay exactly as it was:
; the breakdown is additive diagnostics, not a reformat of every existing line.
_HPX_LeafSegmentKeepsThePlainLine() {
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Leaf := HotPath_Now()
	_HPX_BurnTicks(25)
	HotPath_LogIfSlow("HpxLeaf", Leaf, "leaf")
	LoggerClearTestSink()

	LeafLine := _HPX_FindLine(Captured, "Slow HpxLeaf")
	Assert(LeafLine != "", "the leaf segment must be reported")
	Assert(InStr(LeafLine, "nested") == 0,
		"a segment with nothing measured inside it must not grow a nested breakdown — every millisecond of it really was its own work")
	Assert(InStr(LeafLine, "(leaf)") > 0,
		"the caller-supplied detail must survive the new formatting — it is what identifies the offending character and buffer")
}

; The threshold is the whole point of the profiler: a fast segment stays silent.
_HPX_FastSegmentStaysSilent() {
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


Test("hotpath profiler: a nested segment is not billed to its parent",
	_HPX_NestedSegmentIsNotBilledToItsParent)
Test("hotpath profiler: a leaf segment keeps its plain line",
	_HPX_LeafSegmentKeepsThePlainLine)
Test("hotpath profiler: a fast segment stays silent",
	_HPX_FastSegmentStaysSilent)
