; tests/unit/test_hotpath_per_segment_threshold.ahk

; ==============================================================================
; MODULE: Hot-Path Per-Segment Threshold Regression Test
; DESCRIPTION:
; Regression guard for hotpath-threshold-floods-the-errors-sink.
;
; ROOT CAUSE ENCODED: one global _HOTPATH_SLOW_MS served two populations with
; different NORMAL costs. 5 ms is right for per-keystroke work, where it is
; alarming. Applied to a 2 Hz unattended cross-process COM probe whose healthy
; cost is ~14 ms, it fired on roughly 80 % of ticks — so the tripwire reported
; "this ran" rather than "this is slow" and lost its signal value entirely.
; Measured 2026-07-29 over one 31-minute session: the errors-only sink, which is
; the maintainer's triage channel, was 85.5 % that one segment and 0.3 % actual
; signal. A real user-visible defect sat in it unnoticed for a day.
;
; Three properties must hold together or the fix is undone:
;   1. a segment WITH an override is judged against it, not against the global;
;   2. a segment WITHOUT one still uses the global (an override map must not
;      become a silencer for everything);
;   3. every override carries its measured normal cost in a comment — an
;      override with no measurement behind it is indistinguishable from hiding a
;      regression, which is the way this fix could be abused later.
;
; SCOPE: behavioural for 1 and 2 (real HotPath_LogIfSlow calls with synthesised
; elapsed times, observed through the logger ring); source-level for 3, which is
; the only level at which "the author justified this number" is observable.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================
; =========================================================
; ======= 1/ The threshold that is actually applied =======
; =========================================================
; =========================================================

; Blank the sinks and clear the ring so each case observes only its own line.
_HPT_Reset() {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_PENDING := []
	_LOGGER_PENDING_ERRORS := []
	LOGGER_LOG_PATH := ""
	LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LoggerRefreshFastFlags()
}

; Report a segment as if it had taken ElapsedMs, and return whatever the logger
; captured. The start tick is back-dated from the real counter, so the elapsed
; time HotPath_LogIfSlow measures is ElapsedMs plus a few microseconds of call
; overhead — every value used below is far enough from its threshold that the
; overhead cannot flip a verdict.
_HPT_ReportAndCapture(Label, ElapsedMs) {
	global LOGGER_RING_BUFFER
	_HPT_Reset()
	Freq := 0
	DllCall("QueryPerformanceFrequency", "Int64*", &Freq)
	Now := HotPath_Now()
	HotPath_LogIfSlow(Label, Now - Round(ElapsedMs * Freq / 1000), "threshold-test")
	Out := ""
	for _, Line in LOGGER_RING_BUFFER
		Out .= Line . "`n"
	return Out
}

_HPT_OverriddenSegmentUsesItsOwnThreshold() {
	global _HOTPATH_SLOW_MS, _HOTPATH_SLOW_MS_BY_SEGMENT
	Assert(_HOTPATH_SLOW_MS_BY_SEGMENT.Has("UIA.SelectionPoll"),
		"UIA.SelectionPoll must carry a per-segment threshold — it is the driver's only unattended repeating "
		. "cross-process COM round trip, and its NORMAL cost is several times the per-keystroke floor "
		. "(hotpath-threshold-floods-the-errors-sink)")
	Override := _HOTPATH_SLOW_MS_BY_SEGMENT["UIA.SelectionPoll"]
	Assert(Override > _HOTPATH_SLOW_MS,
		"the override must be ABOVE the global floor — an override at or below it would change nothing")

	; Comfortably between the global floor and the override: this is the band that
	; produced ~99 % of the flood.
	Quiet := _HPT_ReportAndCapture("UIA.SelectionPoll", (_HOTPATH_SLOW_MS + Override) / 2)
	Assert(InStr(Quiet, "UIA.SelectionPoll") == 0,
		"a UIA.SelectionPoll tick between the global floor and its own threshold must emit NOTHING. Judging it "
		. "against the 5 ms per-keystroke floor makes the probe log on ~80 % of its ticks, which is what turned "
		. "the errors-only sink into 85.5 % one segment and buried the real signal "
		. "(hotpath-threshold-floods-the-errors-sink)")

	; Past its own threshold it must still speak — silencing the segment would
	; throw away the 301 ms breach of Windows' low-level-hook timeout.
	Loud := _HPT_ReportAndCapture("UIA.SelectionPoll", Override * 2)
	Assert(InStr(Loud, "UIA.SelectionPoll") > 0,
		"a UIA.SelectionPoll tick past its own threshold MUST still be logged — the override raises the bar, it "
		. "does not mute the segment, and the >300 ms events are exactly what it exists to surface")
}

_HPT_UnlistedSegmentKeepsTheGlobalFloor() {
	global _HOTPATH_SLOW_MS
	; A segment with no override must still trip at the per-keystroke floor, or
	; the override map has become a blanket silencer.
	Loud := _HPT_ReportAndCapture("HPTUnlistedSegment", _HOTPATH_SLOW_MS * 3)
	Assert(InStr(Loud, "HPTUnlistedSegment") > 0,
		"a segment with no per-segment override must still be judged against the global floor")

	Quiet := _HPT_ReportAndCapture("HPTUnlistedSegment", _HOTPATH_SLOW_MS / 5)
	Assert(InStr(Quiet, "HPTUnlistedSegment") == 0,
		"a fast segment must stay silent — the hot path must not pay for a log line on a healthy keystroke")
}




; ========================================================
; ===== 1.1) Every override states its measured cost =====
; ========================================================

; The abuse this fix opens: raising a threshold to make a regression stop
; printing. The defence is that the number must be justified in the source, so a
; reviewer can tell a measurement from a silencer.
_HPT_EveryOverrideIsJustified() {
	global _HOTPATH_SLOW_MS_BY_SEGMENT
	Src := _DriverSourceConcat()
	DeclPos := InStr(Src, "_HOTPATH_SLOW_MS_BY_SEGMENT := Map(")
	Assert(DeclPos > 0,
		"the per-segment threshold map must still be declared in the driver source — without the declaration this "
		. "scan silently measures nothing")

	; The declaration block runs to its closing paren at the start of a line.
	Tail := SubStr(Src, DeclPos)
	EndPos := InStr(Tail, "`n)")
	Assert(EndPos > 0, "the per-segment threshold map declaration must close on its own line")
	Block := SubStr(Tail, 1, EndPos)

	Count := 0
	for Segment, Threshold in _HOTPATH_SLOW_MS_BY_SEGMENT {
		Count++
		KeyPos := InStr(Block, Chr(34) . Segment . Chr(34))
		Assert(KeyPos > 0,
			"override '" . Segment . "' must appear in the declaration block that this test scans")
		; The comment lines immediately above the key are its justification.
		Preamble := SubStr(Block, 1, KeyPos - 1)
		Assert(InStr(Preamble, "Measured") > 0 or InStr(Preamble, "measured") > 0,
			"override '" . Segment . "' must state its MEASURED normal cost in a comment above it. A threshold "
			. "raised without a measurement behind it is indistinguishable from silencing a regression, which is "
			. "the one way this mechanism can be abused (hotpath-threshold-floods-the-errors-sink)")
	}
	Assert(Count >= 1,
		"the override map must not be empty — an empty map makes every assertion above vacuous")
}


Test("hotpath: an overridden segment is judged against its own threshold, not the keystroke floor (hotpath-threshold-floods-the-errors-sink)",
	_HPT_OverriddenSegmentUsesItsOwnThreshold)
Test("hotpath: a segment with no override still uses the global floor (hotpath-threshold-floods-the-errors-sink)",
	_HPT_UnlistedSegmentKeepsTheGlobalFloor)
Test("hotpath: every per-segment threshold override states its measured normal cost (hotpath-threshold-floods-the-errors-sink)",
	_HPT_EveryOverrideIsJustified)
