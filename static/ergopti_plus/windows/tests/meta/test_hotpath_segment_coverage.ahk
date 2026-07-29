; tests/meta/test_hotpath_segment_coverage.ahk

; ==============================================================================
; MODULE: Hot-path Segment Coverage Meta Test
; DESCRIPTION:
; HotPath_Now() opens a measurement; HotPath_LogIfSlow() (or, for a sub-step,
; HotPath_BreakdownMark()) closes it. A segment that is opened and never closed
; costs the two QueryPerformanceCounter reads and reports nothing, and — because
; the profiler is deliberately silent below 5 ms — it looks exactly like a
; segment that was measured and found fast. The two are indistinguishable from
; the log, so the gap survives indefinitely once introduced.
;
; That is not hypothetical. The driver ran for months with three unmeasured
; stages that each turned out to matter: _RemapEmit (the FIRST thing every
; remapped keystroke does, so a slow SendEvent was billed to whatever segment
; happened to be open next), the LLM tooltip's present (identical work to the
; preview present, which was reported), and the 500 ms UIA selection poll (an
; unattended cross-process COM round-trip on the keystroke-dispatch thread).
;
; ROOT CAUSE ENCODED:
; 1. Opens must be balanced by closes, checked over the whole driver rather than
;    at the sites someone remembered — the recurring defect in this repo is the
;    forgotten sibling, so the guard derives its own subject list from source.
; 2. A segment must be opened before the cost it is meant to measure. _RemapEmit
;    serialises on Critical("On") precisely because that wait can be long; a
;    segment opened after it would report zero for the case that matters.
; 3. A segment whose function returns from inside a try must be closed in a
;    finally. A trailing close silently stops measuring exactly the early-exit
;    paths, which are the ones a slow provider takes.
;
; SCOPE: source introspection via the move-resilient driver-source helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================
; =============================================
; ======= 1/ Opened segments are closed =======
; =============================================
; =============================================

; Per-function counts of opened and closed hot-path segments, built in ONE pass
; over the driver source (a per-function regex sweep over a multi-megabyte concat
; is quadratic and takes seconds). Attribution is by the nearest preceding
; column-0 function definition, which is where every profiler token in this
; driver lives.
; @returns {Map} Function name → { Opens, Closes }.
_HSC_SegmentTable() {
	static Table := ""
	if IsObject(Table)
		return Table
	Table := Map()
	Current := ""
	for Line in StrSplit(_DriverSourceNoComments(), "`n", "`r") {
		if RegExMatch(Line, "^([_A-Za-z][_A-Za-z0-9]*)\([^\r\n]*\)\s*\{\s*$", &M) {
			Current := M[1]
			if !Table.Has(Current)
				Table[Current] := { Opens: 0, Closes: 0 }
			; The profiler's own definition lines carry its token names; counting
			; them would make HotPath_Now() look like an unbalanced call site.
			continue
		}
		if (Current == "")
			continue
		if InStr(Line, "HotPath_Now(")
			Table[Current].Opens += 1
		if (InStr(Line, "HotPath_LogIfSlow(") or InStr(Line, "HotPath_BreakdownMark("))
			Table[Current].Closes += 1
	}
	return Table
}

_HSC_EveryOpenedSegmentIsClosed() {
	Instrumented := 0
	for Name, Counts in _HSC_SegmentTable() {
		if (Counts.Opens == 0)
			continue
		Instrumented += 1
		Assert(Counts.Closes >= Counts.Opens,
			Name . " opens " . Counts.Opens . " hot-path segment(s) but closes only " . Counts.Closes . ". An unclosed segment pays for its two QueryPerformanceCounter reads and reports nothing, and because the profiler is silent below 5 ms it is indistinguishable in the log from a segment that was measured and found fast")
	}
	Assert(Instrumented >= 8,
		"the hot-path segment scan must reach the whole driver (found only " . Instrumented . " instrumented function(s)) — a derivation that finds nothing cannot fail and is worse than no guard")
}





; =================================================
; =================================================
; ======= 2/ Segments bracket the real cost =======
; =================================================
; =================================================

_HSC_RemapEmitMeasuresItsSerialisation() {
	Body := _DriverFuncBody("_RemapEmit")
	Assert(Body != "", "_RemapEmit() must exist in the driver source")

	OpenPos := InStr(Body, "HotPath_Now(")
	CritPos := InStr(Body, 'Critical("On")')
	SendPos := InStr(Body, "SendEvent(")
	ClosePos := InStr(Body, "HotPath_LogIfSlow(")
	Assert(CritPos > 0 and SendPos > 0,
		"_RemapEmit must still serialise its send behind Critical — this test would otherwise be pinning a function that no longer exists in that shape")
	Assert(OpenPos > 0 and ClosePos > 0,
		"_RemapEmit must be profiled: it is the first stage of every remapped keystroke and was for a long time the only stage of the keystroke path with no segment at all, so a slow send was billed to whichever segment opened next")
	Assert(OpenPos < CritPos,
		'_RemapEmit must open its segment BEFORE Critical("On"). The whole reason that call is there is that the serialised wait can be long; a segment opened after it reports zero for exactly the case worth reporting')
	Assert(ClosePos > SendPos,
		"_RemapEmit must close its segment after the send it measures")
}

; A segment closed by a trailing statement only measures the fall-through path.
; _UIA_SelectionPollTick returns from four places inside its try — an
; unresponsive provider, an app with no TextPattern, a cached miss — and those
; early exits are precisely the slow ones.
_HSC_SelectionPollClosesOnEveryExit() {
	Body := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(Body != "", "_UIA_SelectionPollTick() must exist in the driver source")
	Assert(InStr(Body, "HotPath_Now(") > 0,
		"_UIA_SelectionPollTick must be profiled — it is the driver's only unattended repeating cross-process COM round-trip, and it runs on the thread that dispatches keystrokes")
	Assert(RegExMatch(Body, "s)finally\s*\{[^}]*HotPath_LogIfSlow\(") > 0,
		"_UIA_SelectionPollTick must close its segment in a finally block. Its try returns from several places, so a trailing close would silently stop measuring the early-exit paths — which are the ones a slow or hostile UIA provider takes")
}


Test("meta hotpath: every opened hot-path segment is closed",
	_HSC_EveryOpenedSegmentIsClosed)
Test("meta hotpath: the remap emit segment covers its own serialisation wait",
	_HSC_RemapEmitMeasuresItsSerialisation)
Test("meta hotpath: the UIA selection poll closes its segment on every exit",
	_HSC_SelectionPollClosesOnEveryExit)
