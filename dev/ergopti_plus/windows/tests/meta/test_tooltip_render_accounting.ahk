; tests/meta/test_tooltip_render_accounting.ahk

; ==============================================================================
; MODULE: Tooltip Render Accounting Meta Test
; DESCRIPTION:
; The hot-path profiler only ever prints a segment that exceeded 5 ms, which
; leaves the log with a numerator and no denominator: "Slow Tooltip.Present, 342
; events" over four days cannot be read as healthy or catastrophic without
; knowing whether those sessions rendered four hundred previews or forty
; thousand. Every performance argument made about the tooltip so far has had to
; guess at that ratio.
;
; The same hole existed one level down. _TooltipResolvePosition is a five-stage
; cascade — native caret, position cache, UIA rect, window frame, mouse — and
; the log recorded which stage answered exactly never. "The position cache never
; hits on the preview path" and "UIA never answers in this app" produce
; identical logs and want opposite fixes; one of them was in fact a real,
; shipped bug (the cache TTL sat below the debounce that gated its only reader)
; and it was found by reasoning, not by measurement, because no measurement
; existed.
;
; ROOT CAUSE ENCODED: a threshold-gated profiler needs a total to be readable,
; and a branching resolver needs per-exit counts. Both are cheap; neither is
; recoverable after the fact. The failure mode this guards is the one that
; actually happens — a new cascade exit added without a counter, which does not
; break anything visible and silently makes the distribution wrong.
;
; SCOPE: source introspection via the move-resilient driver-source helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ Every cascade exit is counted =======
; ================================================
; ================================================

; Count occurrences of Needle in Haystack. AHK has no built-in for this and three
; assertions below need it.
; @param Haystack {String} Text to scan.
; @param Needle {String} Literal substring.
; @returns {Integer} Number of (possibly overlapping) occurrences.
_TRA_Count(Haystack, Needle) {
	Found := 0
	Pos := 1
	while (Pos := InStr(Haystack, Needle, , Pos)) {
		Found += 1
		Pos += 1
	}
	return Found
}

_TRA_EveryResolveExitIsCounted() {
	Body := _DriverFuncBody("_TooltipResolvePosition")
	Assert(Body != "", "_TooltipResolvePosition() must exist in the driver source")

	Returns := _TRA_Count(Body, "return ")
	Counted := _TRA_Count(Body, "_TooltipCountResolveExit(")
	Assert(Returns >= 5,
		"_TooltipResolvePosition must still be the multi-stage cascade this guard is about (found " . Returns . " exit(s))")
	Assert(Counted == Returns,
		"_TooltipResolvePosition has " . Returns . " exit(s) but only " . Counted . " of them record which stage answered. An uncounted exit does not break anything visible — it just makes the distribution in the log quietly wrong, which is how the previous cache-TTL defect stayed invisible until someone reasoned it out from the constants")

	; Distinct stage names, not one shared counter: the whole value is telling
	; the exits apart.
	Stages := Map()
	Pos := 1
	while (Pos := RegExMatch(Body, "_TooltipCountResolveExit\(" . Chr(0x22) . "([a-z_]+)" . Chr(0x22), &M, Pos + 1))
		Stages[M[1]] := true
	Assert(Stages.Count == Counted,
		"each _TooltipResolvePosition exit must report a DISTINCT stage name (" . Stages.Count . " distinct name(s) for " . Counted . " exit(s)) — two exits sharing a label are indistinguishable in the log, which is the state this test exists to end")
}





; ==============================================
; ==============================================
; ======= 2/ The denominator is recorded =======
; ==============================================
; ==============================================

_TRA_PresentedRendersAreCounted() {
	Body := _DriverFuncBody("_TooltipShowNow")
	Assert(Body != "", "_TooltipShowNow() must exist in the driver source")

	NotePos := InStr(Body, "_TooltipNoteRenderPresented(")
	PresentPos := InStr(Body, "_TooltipPresentStack(")
	Assert(PresentPos > 0, "_TooltipShowNow must still present the stack")
	Assert(NotePos > PresentPos,
		"_TooltipShowNow must count the render AFTER the present succeeds. Counted before, the total would include renders that threw and painted nothing, and the slow-render ratio it exists to make computable would be diluted by them")

	Counter := _DriverFuncBody("_TooltipNoteRenderPresented")
	Assert(Counter != "", "_TooltipNoteRenderPresented() must exist in the driver source")
	Assert(InStr(Counter, "_TOOLTIP_STATS_LOG_EVERY") > 0,
		"the render counter must flush periodically — a total that is only ever held in memory is lost with the process and can never be read next to the slow-segment warnings it explains")
	Assert(InStr(Counter, "_TooltipResolveExits") > 0,
		"the accounting line must carry the cascade exit distribution: the two numbers are only useful together, and emitting them separately means correlating two log lines by timestamp")
	Assert(InStr(Counter, "LoggerInfo(") > 0,
		"the accounting line must be INFO — it is the context for WARNING-level slow lines, so it has to survive the default log level they are read at")
}


Test("meta tooltip-accounting: every position-cascade exit records which stage answered",
	_TRA_EveryResolveExitIsCounted)
Test("meta tooltip-accounting: presented renders are counted so the slow-render ratio is computable",
	_TRA_PresentedRendersAreCounted)
