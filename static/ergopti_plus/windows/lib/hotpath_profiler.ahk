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
; ==============================================================================

#Requires AutoHotkey v2.0

; QueryPerformanceFrequency is constant for the life of the process; cache it on
; first use so the per-keystroke path never re-queries it.
global _HOTPATH_QPC_FREQ := 0
; Keystrokes whose hot-path processing exceeds this many milliseconds are logged
; at WARNING. 5 ms is below the threshold of perceptible single-keystroke lag yet
; high enough that a healthy keystroke (sub-millisecond) never trips it.
global _HOTPATH_SLOW_MS := 5.0





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

; Log a WARNING when the elapsed time since StartTicks exceeds _HOTPATH_SLOW_MS.
; Silent (and nearly free) for fast keystrokes so the hot path stays clean.
; @param Label {String} Hot-path segment name (e.g. "OnChar").
; @param StartTicks {Integer} QPC value captured by HotPath_Now at segment entry.
; @param Detail {String} Context shown when slow (typed char, buffer, …).
HotPath_LogIfSlow(Label, StartTicks, Detail := "") {
	global _HOTPATH_QPC_FREQ, _HOTPATH_SLOW_MS
	local now := 0
	if (_HOTPATH_QPC_FREQ == 0)
		DllCall("QueryPerformanceFrequency", "Int64*", &_HOTPATH_QPC_FREQ)
	DllCall("QueryPerformanceCounter", "Int64*", &now)
	ElapsedMs := (now - StartTicks) / _HOTPATH_QPC_FREQ * 1000.0
	if (ElapsedMs > _HOTPATH_SLOW_MS)
		try LoggerWarn("HotPath", "Slow {1}: {2} ms ({3}).", Label, Round(ElapsedMs, 2), Detail)
}
