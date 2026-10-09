; infra/hotpath_profiler.ahk

; ==============================================================================
; MODULE: Hot-path Profiler
; DESCRIPTION:
; Sub-millisecond timing for the per-keystroke hot path. BootProfile measures
; one-shot startup phases with A_TickCount (~15 ms resolution); that is far too
; coarse for a keystroke that should complete in well under a millisecond. This
; module uses QueryPerformanceCounter and retains numeric distributions for every
; measured callback. Slow callbacks log immediately; one-minute summaries retain
; fast samples without recording input content or writing a line per keystroke.
;
; FEATURES & RATIONALE:
; 1. QPC precision: the only way to see a 2 ms vs 0.2 ms keystroke difference.
; 2. Threshold-gated: a slow keystroke is logged, a fast one is silent — the
;    log stays useful instead of drowning in one line per character.
; 3. Bounded overhead: existing QPC reads feed numeric counters, without another
;    clock, formatting or I/O on the fast path. A fixed label limit bounds memory.
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
; _TooltipPresentStack currently emits 19 marks including transitive reveal. The cap must exceed the largest
; instrumented transaction or its tail labels are silently discarded while the
; QPC work is still paid. Guarded by test_tooltip_present_subsegmented.ahk.
global _HOTPATH_BREAKDOWN_CAP := 24





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
	; A parse-time #HotIf can reach the profiler while Bundle_Init() is pumping
	; messages, before this include's auto-execute assignments have run.
	if !IsSet(_HOTPATH_QPC_FREQ)
		return 0.0
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
; Fast callbacks update only their bounded numeric distribution.
; When other segments ran nested inside this one, the line also reports the
; exclusive time, because the raw delta alone reads as this segment's own cost.
; @param Label {String} Hot-path segment name (e.g. "OnChar").
; @param StartTicks {Integer} QPC value captured by HotPath_Now at segment entry.
; @param Detail {String} Context shown when slow (typed char, buffer, …).
HotPath_LogIfSlow(Label, StartTicks, Detail := "") {
	global _HOTPATH_QPC_FREQ, _HOTPATH_SLOW_MS
	global _HOTPATH_NEST_MIN_MS, _HOTPATH_NEST_TRACK_CAP, _HOTPATH_SLOW_MS_BY_SEGMENT
	; HotIf helpers are live at parse time. During the first message-pumping
	; Bundle_Init() call the profiler globals below are not assigned yet, so the
	; only safe behaviour is to skip this optional diagnostic sample.
	if (!IsSet(_HOTPATH_QPC_FREQ) || !IsSet(_HOTPATH_SLOW_MS)
			|| !IsSet(_HOTPATH_NEST_MIN_MS) || !IsSet(_HOTPATH_NEST_TRACK_CAP)
			|| !IsSet(_HOTPATH_SLOW_MS_BY_SEGMENT))
		return
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
	HotPath_RecordLatency(Label, ElapsedMs, SlowMs)
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
; Each presentation owns its marks so reentrant work cannot reset or consume
; an interrupted parent's measurements. Abandoned scopes die with their caller.
; @param Marks {Array} Sub-step accumulator owned by one presentation.
; @param Op {String} "mark" | "drain".
; @param Label {String} Sub-step name, for "mark".
; @param StartTicks {Integer} QPC value at sub-step entry, for "mark".
; @returns {String} For "drain", the rendered attribution; "" otherwise.
_HotPathBreakdown(Marks, Op, Label := "", StartTicks := 0) {
	global _HOTPATH_QPC_FREQ, _HOTPATH_BREAKDOWN_CAP, _HOTPATH_SLOW_MS
	if !(Marks is Array)
		throw TypeError("Hot-path breakdown requires an owned marks array.")
	if (Op == "mark") {
		if (Marks.Length >= _HOTPATH_BREAKDOWN_CAP)
			return ""
		local now := 0
		if (_HOTPATH_QPC_FREQ == 0)
			DllCall("QueryPerformanceFrequency", "Int64*", &_HOTPATH_QPC_FREQ)
		DllCall("QueryPerformanceCounter", "Int64*", &now)
		ElapsedMs := (_HOTPATH_QPC_FREQ > 0)
			? ((now - StartTicks) / _HOTPATH_QPC_FREQ * 1000.0) : 0.0
		Marks.Push({ L: Label, Ms: ElapsedMs })
		HotPath_RecordLatency("Substep." . Label, ElapsedMs, _HOTPATH_SLOW_MS)
		return ""
	}
	if Op != "drain"
		throw ValueError("Unknown hot-path breakdown operation.")
	; Render and clear only this caller's marks.
	Text := ""
	for , Mark in Marks
		Text .= (Text == "" ? "" : " + ") . Mark.L . " " . Round(Mark.Ms, 2) . " ms"
	Marks.Length := 0
	return Text
}

; Create the sub-step accumulator for one composite segment.
; @returns {Array} Caller-owned marks; pass to every mark and the final drain.
HotPath_BreakdownBegin() {
	return []
}

; Record one closed sub-step of the segment currently being measured.
; @param Label {String} Short sub-step name (e.g. "border").
; @param StartTicks {Integer} QPC value captured by HotPath_Now at sub-step entry.
; @param Marks {Array} Accumulator returned by HotPath_BreakdownBegin.
HotPath_BreakdownMark(Label, StartTicks, Marks) {
	_HotPathBreakdown(Marks, "mark", Label, StartTicks)
}

; Render the accumulated sub-steps as a Detail string and clear them. Pass the
; result straight to HotPath_LogIfSlow as its Detail argument.
; @param Marks {Array} Accumulator owned by the measured composite segment.
; @returns {String} e.g. "prepare 0.15 ms + corners 0.46 ms + border 4.33 ms".
HotPath_BreakdownDetail(Marks) {
	return _HotPathBreakdown(Marks, "drain")
}





; ================================================
; ================================================
; ======= 3/ Bounded latency distributions =======
; ================================================
; ================================================

/** Owns numeric aggregates without retaining callback detail or input text. */
class HotPathLatencyStatistics {
	__New(Limit := 128) {
		if !(Limit is Integer) || Limit < 1
			throw ValueError("Latency statistics limit must be a positive integer")
		this.Limit := Limit
		this.Series := Map()
		this.Refused := 0
	}

	/** Records all samples, including fast ones; a full label registry refuses visibly. */
	Record(Label, ElapsedMs, SlowMs) {
		if !this.Series.Has(Label) {
			if this.Series.Count >= this.Limit {
				this.Refused += 1
				return false
			}
			this.Series[Label] := { Count: 0, TotalMs: 0.0, MinMs: ElapsedMs, MaxMs: 0.0,
				Slow: 0, Ge1: 0, Ge5: 0, Ge10: 0, Ge50: 0 }
		}
		Sample := this.Series[Label]
		Sample.Count += 1
		Sample.TotalMs += ElapsedMs
		Sample.MinMs := Min(Sample.MinMs, ElapsedMs)
		Sample.MaxMs := Max(Sample.MaxMs, ElapsedMs)
		Sample.Slow += ElapsedMs > SlowMs
		Sample.Ge1 += ElapsedMs >= 1
		Sample.Ge5 += ElapsedMs >= 5
		Sample.Ge10 += ElapsedMs >= 10
		Sample.Ge50 += ElapsedMs >= 50
		return true
	}
}

/** Static ownership survives early include-order callbacks. */
_HotPathStatisticsOwner() {
	static Owner := { Stats: HotPathLatencyStatistics(), Started: false, Timer: 0 }
	return Owner
}

/** Adds a sample with no clock reads, formatting or I/O on the usual path. */
HotPath_RecordLatency(Label, ElapsedMs, SlowMs) {
	Owner := _HotPathStatisticsOwner()
	PreviousCritical := Critical("On")
	try {
		Accepted := Owner.Stats.Record(Label, ElapsedMs, SlowMs)
		FirstRefusal := !Accepted && Owner.Stats.Refused == 1
	}
	finally Critical(PreviousCritical)
	if FirstRefusal
		try LoggerWarn("HotPath", "Latency statistics label capacity reached; refused samples are counted.")
}

/** Starts one low-priority summary timer after LoggerInit; duplicate ownership is invalid. */
HotPath_StartStatistics() {
	Owner := _HotPathStatisticsOwner()
	if Owner.Started
		throw Error("Latency statistics already started")
	Owner.Started := true
	Owner.Timer := HotPath_FlushStatistics
	; One minute retains distributions without turning normal typing into log I/O.
	SetTimer(Owner.Timer, 60000, -1)
	try LoggerInfo("HotPath", "Latency statistics started (interval=60000 ms, labels={1}).", Owner.Stats.Limit)
}

/** Detaches the numeric snapshot before logging can pump callbacks into the next window. */
HotPath_FlushStatistics(*) {
	Owner := _HotPathStatisticsOwner()
	if !Owner.Started
		return
	PreviousCritical := Critical("On")
	try {
		Snapshot := Owner.Stats
		if Snapshot.Series.Count == 0 && Snapshot.Refused == 0
			return
		Owner.Stats := HotPathLatencyStatistics(Snapshot.Limit)
	} finally Critical(PreviousCritical)
	for Label, Sample in Snapshot.Series {
		; Format before emission: template repeat collapsing must retain every segment.
		try LoggerInfo("HotPath", Format(
			"Latency '{1}': count={2}, mean={3:.4f} ms, min={4:.4f} ms, max={5:.4f} ms, slow={6}, ge1={7}, ge5={8}, ge10={9}, ge50={10}.",
			Label, Sample.Count, Sample.TotalMs / Sample.Count, Sample.MinMs, Sample.MaxMs,
			Sample.Slow, Sample.Ge1, Sample.Ge5, Sample.Ge10, Sample.Ge50))
	}
	if Snapshot.Refused
		try LoggerWarn("HotPath", "Latency statistics refused {1} samples beyond its label capacity.", Snapshot.Refused)
}

/** Closes the summary timer before the logger's durable exit flush. */
HotPath_StopStatistics() {
	Owner := _HotPathStatisticsOwner()
	if !Owner.Started
		return false
	SetTimer(Owner.Timer, 0)
	Owner.Timer := 0
	HotPath_FlushStatistics()
	Owner.Started := false
	try LoggerInfo("HotPath", "Latency statistics stopped.")
	return true
}
