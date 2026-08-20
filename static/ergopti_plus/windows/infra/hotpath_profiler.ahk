; infra/hotpath_profiler.ahk

; ==============================================================================
; MODULE: Hot-path Profiler
; DESCRIPTION:
; Sub-millisecond timing for the per-keystroke hot path. BootProfile measures
; one-shot startup phases with A_TickCount (~15 ms resolution); that is far too
; coarse for a keystroke that should complete in well under a millisecond. This
; module uses QueryPerformanceCounter (sub-microsecond) and logs ONLY keystrokes
; that exceed a threshold, so normal typing produces zero log noise while any
; real hitch surfaces with the offending character and buffer for diagnosis.
;
; FEATURES & RATIONALE:
; 1. QPC precision: the only way to see a 2 ms vs 0.2 ms keystroke difference.
; 2. Threshold-gated: a slow keystroke is logged, a fast one is silent — the
;    log stays useful instead of drowning in one line per character.
; 3. Near-zero overhead: two QPC reads and a subtraction per keystroke (~100 ns),
;    negligible against the HSE match + tooltip work it wraps, so it can stay on
;    permanently as a latency tripwire.
; 4. Nesting-aware: a segment reports how much of its wall clock was spent inside
;    OTHER segments that opened and closed within it. AHK is single-threaded but
;    Gui creation and COM calls PUMP the message loop, so a physically typed key's
;    whole InputHook callback can run nested inside Tooltip.Build — and the raw
;    wall-clock delta then bills that keystroke to the tooltip. The driver
;    documents that re-entrancy itself (ui/tooltip/core.ahk, the generation
;    counter exists because of it), and the largest number this profiler has ever
;    reported was produced by it: "Slow Tooltip.Build: 112.86 ms (1 item(s))" for
;    a one-row tooltip that benches at ~7 ms. Without the breakdown, real work,
;    OS descheduling and driver re-entry are three different events that print
;    identically, and a genuine 3x regression would be invisible in the noise.
; ==============================================================================

#Requires AutoHotkey v2.0

; QueryPerformanceFrequency is constant for the life of the process; cache it on
; first use so the per-keystroke path never re-queries it.
global _HOTPATH_QPC_FREQ := 0
; Keystrokes whose hot-path processing exceeds this many milliseconds are logged
; at WARNING. 5 ms is below the threshold of perceptible single-keystroke lag yet
; high enough that a healthy keystroke (sub-millisecond) never trips it.
global _HOTPATH_SLOW_MS := 5.0
; Per-segment overrides of the threshold above, for segments whose NORMAL cost is
; already past it. The global 5 ms is calibrated for per-keystroke work, where
; 5 ms is alarming. Applied to a repeating background probe whose healthy cost is
; an order of magnitude higher, it fires on almost every tick: the tripwire then
; reports "this ran", not "this is slow", and stops being able to signal
; anything. Measured 2026-07-29 over one 31-minute session, the errors-only sink
; — the maintainer's triage channel — was 85.5 % ONE segment and 0.3 % actual
; signal, which is how a real user-visible defect sat in it unnoticed for a day.
;
; Every entry MUST carry its measured normal cost in a comment: an override
; without a measurement behind it is indistinguishable from hiding a regression,
; and tests/unit/test_hotpath_per_segment_threshold.ahk enforces the comment.
global _HOTPATH_SLOW_MS_BY_SEGMENT := Map(
	; 2 Hz unattended cross-process UIA/COM round trip on the message thread.
	; Measured 2026-07-29 21:15-21:46: n=2993, mean 14.3 ms, max 301.0 ms, ~80 %
	; of all possible ticks over 5 ms. 60 ms keeps every >100 ms event and the one
	; 301 ms breach of Windows' ~300 ms LowLevelHooksTimeout, while dropping ~99 %
	; of the volume.
	"UIA.SelectionPoll", 60.0
)
; A closed segment shorter than this is not remembered as a possible child. It
; cannot materially distort a parent that has to exceed _HOTPATH_SLOW_MS to be
; reported at all, and skipping it keeps normal typing allocation-free.
global _HOTPATH_NEST_MIN_MS := 1.0
; How many recently closed segments stay eligible as children. Segments nest at
; most a few deep (OnChar > HSE.FeedChar > Tooltip.Build > a re-entrant OnChar),
; so this is generous; it exists to bound both memory and the containment sweep.
global _HOTPATH_NEST_TRACK_CAP := 16
; Upper bound on the sub-steps one segment may attribute. A segment with more
; parts than this is not a segment any more, and the cap keeps the accumulator
; allocation-free in the steady state.
; _TooltipPresentStack currently emits 15 marks. The cap must exceed the largest
; instrumented transaction or its tail labels are silently discarded while the
; QPC work is still paid. Guarded by test_tooltip_present_subsegmented.ahk.
global _HOTPATH_BREAKDOWN_CAP := 16





; ==================================================
; ==================================================
; ======= 1/ Hot-path keystroke profiler API =======
; ==================================================
; ==================================================

; Read the current high-resolution performance counter.
; @returns {Integer} Raw QPC tick value; pass to HotPath_LogIfSlow as the start.
HotPath_Now() {
	local counter := 0
	DllCall("QueryPerformanceCounter", "Int64*", &counter)
	return counter
}

; Sum the wall clock of the segments in ``Closed`` that opened AND closed inside
; [StartTicks, EndTicks] — i.e. the time a parent spent running OTHER measured
; work rather than its own. Only the OUTERMOST contained segments are counted, so
; a grandchild is never added twice.
; @param Closed {Array} Recently closed segments, each { S, E } in QPC ticks.
; @param StartTicks {Integer} Parent segment start, in QPC ticks.
; @param EndTicks {Integer} Parent segment end, in QPC ticks.
; @returns {Float} Nested milliseconds (0 when nothing ran inside).
_HotPathNestedMs(Closed, StartTicks, EndTicks) {
	global _HOTPATH_QPC_FREQ
	Inside := []
	for , Seg in Closed
		if (Seg.S >= StartTicks and Seg.E <= EndTicks)
			Inside.Push(Seg)
	Ticks := 0
	for i, Child in Inside {
		Enclosed := false
		for j, Other in Inside {
			if (j == i)
				continue
			; Strictly enclosing, or an exact duplicate — which is kept once, by
			; the lowest index, so identical intervals cannot both be counted.
			if (Other.S <= Child.S and Other.E >= Child.E
				and (Other.S < Child.S or Other.E > Child.E or j < i)) {
				Enclosed := true
				break
			}
		}
		if !Enclosed
			Ticks += Child.E - Child.S
	}
	return (_HOTPATH_QPC_FREQ > 0) ? (Ticks / _HOTPATH_QPC_FREQ * 1000.0) : 0.0
}

; Log a WARNING when the elapsed time since StartTicks exceeds _HOTPATH_SLOW_MS.
; Silent (and nearly free) for fast keystrokes so the hot path stays clean.
; When other segments ran nested inside this one, the line also reports the
; exclusive time, because the raw delta alone reads as this segment's own cost.
; @param Label {String} Hot-path segment name (e.g. "OnChar").
; @param StartTicks {Integer} QPC value captured by HotPath_Now at segment entry.
; @param Detail {String} Context shown when slow (typed char, buffer, …).
HotPath_LogIfSlow(Label, StartTicks, Detail := "") {
	global _HOTPATH_QPC_FREQ, _HOTPATH_SLOW_MS
	global _HOTPATH_NEST_MIN_MS, _HOTPATH_NEST_TRACK_CAP, _HOTPATH_SLOW_MS_BY_SEGMENT
	; Ring of recently closed segments, oldest first. Deliberately a static local
	; rather than a module global: this file otherwise holds no mutable state.
	; A segment that closed before this one started can never be contained in it,
	; so stale entries are inert and the ring needs no time-based pruning.
	static Closed := []
	local now := 0
	if (_HOTPATH_QPC_FREQ == 0)
		DllCall("QueryPerformanceFrequency", "Int64*", &_HOTPATH_QPC_FREQ)
	DllCall("QueryPerformanceCounter", "Int64*", &now)
	ElapsedMs := (now - StartTicks) / _HOTPATH_QPC_FREQ * 1000.0
	; .Get, never a bracket read: an absent key THROWS in AHK v2, and this runs on
	; the keystroke path where a throw would take the hook down.
	SlowMs := _HOTPATH_SLOW_MS_BY_SEGMENT.Get(Label, _HOTPATH_SLOW_MS)
	if (ElapsedMs > SlowMs) {
		; Computed before this segment joins the ring, or it would contain itself.
		NestedMs := _HotPathNestedMs(Closed, StartTicks, now)
		Breakdown := ""
		if (NestedMs > 0)
			Breakdown := " [excl " . Round(ElapsedMs - NestedMs, 2) . " ms, nested " . Round(NestedMs, 2) . " ms]"
		try LoggerWarn("HotPath", "Slow {1}: {2} ms{3} ({4}).",
			Label, Round(ElapsedMs, 2), Breakdown, Detail)
	}
	if (ElapsedMs >= _HOTPATH_NEST_MIN_MS) {
		Closed.Push({ S: StartTicks, E: now })
		while (Closed.Length > _HOTPATH_NEST_TRACK_CAP)
			Closed.RemoveAt(1)
	}
}





; =======================================
; =======================================
; ======= 2/ Sub-step attribution =======
; =======================================
; =======================================

; A segment only prints once it exceeds _HOTPATH_SLOW_MS, which means a composite
; segment built out of sub-steps that are each BELOW that threshold reports a
; number with no attribution at all. Tooltip.Present is exactly that shape: six
; sub-steps of 0.02–4.4 ms that add up to a reported 6–53 ms, and no log line
; says which of them moved. Instrumenting each sub-step with its own
; HotPath_LogIfSlow does not help — every one of them is censored by the same
; 5 ms floor.
;
; So sub-steps accumulate into a buffer instead of logging, and the PARENT
; renders them into its own (already gated) line. Cost when the parent is fast:
; one array push per sub-step and one discarded string build — no I/O, no log.
;
; Deliberately a static local rather than a module global, matching the nesting
; ring above: this file's mutable state stays inside the functions that own it.
; @param Op {String} "reset" | "mark" | "drain".
; @param Label {String} Sub-step name, for "mark".
; @param StartTicks {Integer} QPC value at sub-step entry, for "mark".
; @returns {String} For "drain", the rendered attribution; "" otherwise.
_HotPathBreakdown(Op, Label := "", StartTicks := 0) {
	global _HOTPATH_QPC_FREQ, _HOTPATH_BREAKDOWN_CAP
	static Marks := []
	if (Op == "reset") {
		Marks := []
		return ""
	}
	if (Op == "mark") {
		if (Marks.Length >= _HOTPATH_BREAKDOWN_CAP)
			return ""
		local now := 0
		if (_HOTPATH_QPC_FREQ == 0)
			DllCall("QueryPerformanceFrequency", "Int64*", &_HOTPATH_QPC_FREQ)
		DllCall("QueryPerformanceCounter", "Int64*", &now)
		Marks.Push({ L: Label,
			Ms: (_HOTPATH_QPC_FREQ > 0)
				? ((now - StartTicks) / _HOTPATH_QPC_FREQ * 1000.0) : 0.0 })
		return ""
	}
	; "drain" — render and clear, so a parent that never drains cannot leak its
	; sub-steps into the next segment's line.
	Text := ""
	for , Mark in Marks
		Text .= (Text == "" ? "" : " + ") . Mark.L . " " . Round(Mark.Ms, 2) . " ms"
	Marks := []
	return Text
}

; Discard any sub-steps left over from an earlier segment. Call at the top of the
; composite segment, never at the top of a sub-step.
HotPath_BreakdownBegin() {
	_HotPathBreakdown("reset")
}

; Record one closed sub-step of the segment currently being measured.
; @param Label {String} Short sub-step name (e.g. "border").
; @param StartTicks {Integer} QPC value captured by HotPath_Now at sub-step entry.
HotPath_BreakdownMark(Label, StartTicks) {
	_HotPathBreakdown("mark", Label, StartTicks)
}

; Render the accumulated sub-steps as a Detail string and clear them. Pass the
; result straight to HotPath_LogIfSlow as its Detail argument.
; @returns {String} e.g. "prepare 0.15 ms + corners 0.46 ms + border 4.33 ms".
HotPath_BreakdownDetail() {
	return _HotPathBreakdown("drain")
}
