; lib/hotpath_profiler.ahk

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
; A closed segment shorter than this is not remembered as a possible child. It
; cannot materially distort a parent that has to exceed _HOTPATH_SLOW_MS to be
; reported at all, and skipping it keeps normal typing allocation-free.
global _HOTPATH_NEST_MIN_MS := 1.0
; How many recently closed segments stay eligible as children. Segments nest at
; most a few deep (OnChar > HSE.FeedChar > Tooltip.Build > a re-entrant OnChar),
; so this is generous; it exists to bound both memory and the containment sweep.
global _HOTPATH_NEST_TRACK_CAP := 16





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
	global _HOTPATH_NEST_MIN_MS, _HOTPATH_NEST_TRACK_CAP
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
	if (ElapsedMs > _HOTPATH_SLOW_MS) {
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
