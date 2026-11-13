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
; 4. Judged on own time: a segment is slow when its wall clock MINUS the segments
;    that opened and closed inside it exceeds the threshold, and a slow child is
;    reported with its parent instead of being billed to it. AHK is
;    single-threaded but Gui creation and COM calls PUMP the message loop, so a
;    physically typed key's whole InputHook callback can run nested inside
;    Tooltip.Build, and the wall clock then bills that keystroke to the tooltip.
;    The driver documents that re-entrancy itself (ui/tooltip/core.ahk, the
;    generation counter exists because of it), and the largest number this
;    profiler ever reported was produced by it: 112.86 ms for a one-row tooltip
;    that benches at ~7 ms. The attribution and the line are those of macOS and
;    Linux (_shared/metrics/engine/perf/hotpath_segments.lua new_nesting); the shared vectors in
;    _shared/tests/corpus/diagnostics/hotpath_nesting_vectors.json bind all three.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../adapters/boot_clock.ahk
#Include phase_stats.ahk

; QueryPerformanceFrequency is constant for the life of the process; cache it on
; first use so the per-keystroke path never re-queries it.
global _HOTPATH_QPC_FREQ := 0
; Keystrokes whose hot-path processing exceeds this many milliseconds are logged
; at WARNING. 5 ms is below the threshold of perceptible single-keystroke lag yet
; high enough that a healthy keystroke (sub-millisecond) never trips it.
; Single source: _shared/core/timing/data/constants.toml [logger] hotpath_slow_ms,
; assigned by HotPath_LoadTimings. Declared unset on purpose: every reader already
; skips an unset threshold (a message-pumping Bundle_Init reaches the profiler
; before this file's initializers), so a sample taken before the registry is read
; is not judged against a guessed number.
global _HOTPATH_SLOW_MS
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
; and tests/unit/infra/dispatch/test_hotpath_per_segment_threshold.ahk enforces the comment.
global _HOTPATH_SLOW_MS_BY_SEGMENT := Map(
	; 2 Hz unattended cross-process UIA/COM round trip on the message thread.
	; Measured 2026-07-29 21:15-21:46: n=2993, mean 14.3 ms, max 301.0 ms, ~80 %
	; of all possible ticks over 5 ms. 60 ms keeps every >100 ms event and the one
	; 301 ms breach of Windows' ~300 ms LowLevelHooksTimeout, while dropping ~99 %
	; of the volume.
	"UIA.SelectionPoll", 60.0,
	; The preview tooltip's layered Gui and DWM border, painted from a deferred
	; timer, never inside a keystroke: a keystroke it delays still reports under
	; its own segment with the nested time. Measured 2026-10-03..17 from the
	; one-minute summaries: n=1315, mean 11.5 ms, 95 % over 5 ms, 52 % over 10 ms,
	; 2 over 50 ms, max 106 ms; it was 81 of the 218 errors-sink lines of
	; 2026-10-17. 30 ms keeps every stall a typist can see.
	"Tooltip.Present", 30.0,
	; The same tooltip's row build. Measured 2026-10-03..17: n=1319, mean 7.1 ms,
	; 58 % over 5 ms, 15 % over 10 ms, 2 over 50 ms, max 208 ms.
	"Tooltip.Build", 30.0
)
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

; Assign the slow-segment threshold from the shared registry. AHK v2 runs global
; initializers before the auto-execute body, so infra/boot.ahk calls this right
; after TimingsLoadShared(). Fail-fast: TimingsGet throws on a missing key, and a
; threshold of zero would report every keystroke as slow.
HotPath_LoadTimings() {
	global _HOTPATH_SLOW_MS
	SlowMs := TimingsGet("logger", "hotpath_slow_ms")
	if (SlowMs <= 0)
		throw ValueError(Format("[logger] hotpath_slow_ms must be positive, got {1}.", SlowMs))
	_HOTPATH_SLOW_MS := SlowMs
}

; Read the current high-resolution performance counter and open a frame: every
; call is closed by HotPath_LogIfSlow or, for a sub-step, HotPath_BreakdownMark.
; @returns {Integer} Raw QPC tick value; pass to the closing call as the start.
HotPath_Now() {
	static Tracker := _HotPathNestingOwner().Tracker, Starts := Tracker.Starts, MaxDepth := Tracker.MaxDepth
	Now := PerfClockTicks()
	; Tracker.Open inlined for the usual case: this runs on every segment of every
	; keystroke, and a method call costs more than the rest of the frame.
	if ((Depth := Tracker.Depth) >= MaxDepth)
		return Tracker.Open(Now)
	Tracker.Depth := ++Depth, Starts[Depth] := Now
	return Now
}

; Close the segment opened by HotPath_Now and log a WARNING when its own time
; exceeds its threshold. Fast callbacks update only their numeric distribution,
; which keeps the wall clock: it answers "how long did the user wait".
; @param Label {String} Hot-path segment name (e.g. "OnChar").
; @param StartTicks {Integer} QPC value captured by HotPath_Now at segment entry.
; @param Detail {String} Context shown when slow (typed char, buffer, …).
HotPath_LogIfSlow(Label, StartTicks, Detail := "") {
	global _HOTPATH_QPC_FREQ, _HOTPATH_SLOW_MS, _HOTPATH_SLOW_MS_BY_SEGMENT
	static Tracker := _HotPathNestingOwner().Tracker, Starts := Tracker.Starts
	static Pending := Tracker.Pending, NestMinMs := Tracker.NestMinMs
	local now := PerfClockTicks()
	; HotIf helpers are live at parse time. During the first message-pumping
	; Bundle_Init() call the profiler globals below are not assigned yet, so this
	; optional diagnostic sample is skipped; its frame still closes, as a span.
	if (!IsSet(_HOTPATH_QPC_FREQ) || !IsSet(_HOTPATH_SLOW_MS)
			|| !IsSet(_HOTPATH_SLOW_MS_BY_SEGMENT)) {
		Tracker.Close(Label, StartTicks, now, "")
		return
	}
	if (_HOTPATH_QPC_FREQ == 0)
		_HOTPATH_QPC_FREQ := PerfClockFrequency()
	ElapsedMs := (now - StartTicks) / _HOTPATH_QPC_FREQ * 1000.0
	; .Get, never a bracket read: an absent key THROWS in AHK v2, and this runs on
	; the keystroke path where a throw would take the hook down.
	SlowMs := _HOTPATH_SLOW_MS_BY_SEGMENT.Get(Label, _HOTPATH_SLOW_MS)
	HotPath_RecordLatency(Label, ElapsedMs, SlowMs)
	; The fast path of Tracker.Close inlined, for the reason HotPath_Now gives.
	if (ElapsedMs < NestMinMs && ElapsedMs <= SlowMs && (Depth := Tracker.Depth) > 0
			&& Starts[Depth] == StartTicks && !Pending[Depth]) {
		Tracker.Depth := Depth - 1
		return
	}
	Tracker.Close(Label, StartTicks, now, SlowMs, Detail)
}

/**
 * The open segments of the one AutoHotkey thread stack; the port of
 * _shared/metrics/engine/perf/hotpath_segments.lua new_nesting. Threads interrupt one another
 * last in, first out, so a stack fits even when a pump runs a whole callback
 * inside a segment. A span closed without a limit (a sub-step, or a sample taken
 * before the thresholds exist) is transparent: its time stays its enclosing
 * segment's own time. A frame left open by a raise closes with its enclosing
 * frame. One with no enclosing frame would hold back every later report, so
 * Sweep empties the stack at the depth cap and on the one-minute timer, whose
 * priority -1 cannot interrupt a keystroke's thread.
 */
class HotPathNesting {
	; Segments nest a few levels deep; a deeper stack is a clock read never closed.
	static MAX_DEPTH := 32
	; Parent token of a slow segment that no segment encloses.
	static NO_PARENT := "none"
	; A closed segment shorter than this is not billed to its parent: it cannot
	; distort a parent that has to pass a 5 ms threshold to be reported, and
	; skipping it keeps normal typing from writing the stack twice per segment.
	static NEST_MIN_MS := 1.0

	/**
	 * @param {Func} Emit Receives (Report, NowMs); Report holds Segment, Parent,
	 *   TotalMs, OwnMs and Detail.
	 * @param {Number} MsPerUnit Milliseconds per unit of the stamps passed in.
	 */
	__New(Emit, MsPerUnit) {
		this.Emit := Emit
		this.MsPerUnit := MsPerUnit
		this.Starts := []
		this.Nested := []
		this.Pending := []
		loop HotPathNesting.MAX_DEPTH {
			this.Starts.Push(0)
			this.Nested.Push(0)
			this.Pending.Push("")
		}
		this.Depth := 0
		this.MaxDepth := HotPathNesting.MAX_DEPTH
		this.NestMinMs := HotPathNesting.NEST_MIN_MS
	}

	/**
	 * Opens a frame. One statement on purpose: AutoHotkey checks for an
	 * interrupting thread between lines, never inside one.
	 * @param {Number} Now The stamp to pass to Close.
	 * @returns {Number} Now.
	 */
	Open(Now) {
		if ((Depth := this.Depth) >= this.MaxDepth)
			Depth := (this.Sweep(), 0)
		this.Depth := ++Depth, this.Starts[Depth] := Now
		return Now
	}

	/**
	 * Closes the frame opened at Started.
	 * @param {String} Name Segment name.
	 * @param {Number} Started The stamp Open returned.
	 * @param {Number} Now The current stamp.
	 * @param {Number|String} LimitMs Slow threshold, "" for a transparent span.
	 * @param {String} Detail Context carried by this segment's report.
	 * @returns {Boolean} Whether this close judged the segment slow.
	 */
	Close(Name, Started, Now, LimitMs, Detail := "") {
		; The usual keystroke: under NEST_MIN_MS and under its limit, this frame on
		; top. Nothing that short can hold a billed child, so its slot is clean. No
		; transaction: a thread that interrupts here leaves the stack as it found it.
		Depth := this.Depth
		Ms := (Now - Started) * this.MsPerUnit
		if (Ms < this.NestMinMs && LimitMs != "" && Ms <= LimitMs && Depth > 0
				&& this.Starts[Depth] == Started && !this.Pending[Depth]) {
			this.Depth := Depth - 1
			return false
		}
		Ready := ""
		Slow := false
		PreviousCritical := Critical("On")
		try {
			; Frames opened after this span started and still open were abandoned.
			while (this.Depth > 0 && this.Starts[this.Depth] > Started) {
				ChildUnits := this.Nested[this.Depth]
				this.Nested[this.Depth] := 0
				Reports := this.Pending[this.Depth]
				this.Pending[this.Depth] := ""
				this.Depth -= 1
				if (this.Depth > 0)
					this.Nested[this.Depth] += ChildUnits
				this._HandDown(Reports, "", &Ready)
			}
			ChildUnits := 0
			Reports := ""
			if (this.Depth > 0 && this.Starts[this.Depth] == Started) {
				ChildUnits := this.Nested[this.Depth]
				this.Nested[this.Depth] := 0
				Reports := this.Pending[this.Depth]
				this.Pending[this.Depth] := ""
				this.Depth -= 1
			}
			if (LimitMs == "") {
				if (this.Depth > 0)
					this.Nested[this.Depth] += ChildUnits
				this._HandDown(Reports, "", &Ready)
			} else {
				TotalUnits := Now - Started
				if (this.Depth > 0)
					this.Nested[this.Depth] += TotalUnits
				this._HandDown(Reports, Name, &Ready)
				OwnMs := (TotalUnits - ChildUnits) * this.MsPerUnit
				if (OwnMs > LimitMs) {
					Slow := true
					this._HandDown([{ Segment: Name, Parent: "", TotalMs: TotalUnits * this.MsPerUnit,
						OwnMs: OwnMs, Detail: Detail }], "", &Ready)
				}
			}
		} finally Critical(PreviousCritical)
		; Outside the transaction: logging can pump callbacks into this tracker.
		if Ready
			for Report in Ready
				(this.Emit)(Report, Now * this.MsPerUnit)
		return Slow
	}

	/**
	 * Delivers the reports waiting on every open frame and forgets the frames.
	 * @returns {Integer} How many frames were left open.
	 */
	Sweep() {
		Ready := ""
		Left := 0
		PreviousCritical := Critical("On")
		try {
			Left := this.Depth
			; The newest stamp known here: the sweep is not handed a clock.
			Stamp := Left ? this.Starts[Left] : 0
			while (this.Depth > 0) {
				Reports := this.Pending[this.Depth]
				this.Pending[this.Depth] := ""
				this.Nested[this.Depth] := 0
				this.Depth -= 1
				this._HandDown(Reports, HotPathNesting.NO_PARENT, &Ready)
			}
		} finally Critical(PreviousCritical)
		if Ready
			for Report in Ready
				(this.Emit)(Report, Stamp * this.MsPerUnit)
		return Left
	}

	; Moves a frame's reports to Ready once their parent is known, else to the frame below.
	_HandDown(Reports, Parent, &Ready) {
		if !Reports
			return
		if (Parent == "" && this.Depth > 0) {
			if !this.Pending[this.Depth]
				this.Pending[this.Depth] := []
			this.Pending[this.Depth].Push(Reports*)
			return
		}
		if !Ready
			Ready := []
		for Report in Reports {
			Report.Parent := (Parent == "") ? HotPathNesting.NO_PARENT : Parent
			Ready.Push(Report)
		}
	}
}

/**
 * The rate limiter of the slow-segment WARNING, as in metrics/engine/perf/hotpath_segments.lua
 * new_slow_gate: a segment that stays slow is slow on every keystroke, so one
 * line per segment per window keeps the first occurrence and the log readable.
 * The latency summaries keep counting every occurrence.
 */
class HotPathSlowGate {
	; The window of LOG_WINDOW_MS in _shared/metrics/engine/perf/hotpath_segments.lua, which
	; AutoHotkey cannot load; test_hotpath_nesting_vectors.ahk compares the two.
	static SLOW_LINE_WINDOW_MS := 10000

	__New() {
		this.Reset()
	}

	Reset() {
		this.LastLogged := Map()
		this.Withheld := Map()
	}

	/**
	 * Admits or withholds one slow occurrence.
	 * @param {String} Name Segment name.
	 * @param {Number} NowMs Monotonic milliseconds.
	 * @returns {Integer} The occurrences withheld since the last line, -1 to withhold this one.
	 */
	Admit(Name, NowMs) {
		if (this.LastLogged.Has(Name) && NowMs - this.LastLogged[Name] < HotPathSlowGate.SLOW_LINE_WINDOW_MS) {
			this.Withheld[Name] := this.Withheld.Get(Name, 0) + 1
			return -1
		}
		Skipped := this.Withheld.Get(Name, 0)
		this.LastLogged[Name] := NowMs
		this.Withheld[Name] := 0
		return Skipped
	}
}

/** Static ownership: a message-pumping Bundle_Init reaches the profiler before this file's initializers. */
_HotPathNestingOwner() {
	static Owner := { Tracker: HotPathNesting(_HotPathReportSlow, 1000.0 / PerfClockFrequency()),
		Gate: HotPathSlowGate() }
	return Owner
}

; Writes one slow segment, in the line macOS and Linux write. The caller's context
; (the sub-steps of Tooltip.Present, a redacted trigger) follows on its own line.
_HotPathReportSlow(Report, NowMs) {
	Skipped := _HotPathNestingOwner().Gate.Admit(Report.Segment, NowMs)
	if (Skipped < 0)
		return
	try LoggerWarn("HotPath", "Slow {1}: {2:.2f} ms own, {3:.2f} ms total, parent {4} ({5} similar since the last line).",
		Report.Segment, Report.OwnMs, Report.TotalMs, Report.Parent, Skipped)
	if (Report.Detail != "")
		try LoggerWarn("HotPath", "Slow {1} detail: {2}.", Report.Segment, Report.Detail)
}

/**
 * Forgets every open frame and the rate limiter. Tests only. A discarded frame's
 * billed child time goes with it: Open reuses the slot as it finds it, so a
 * stale count would be subtracted from the next segment opened at that depth.
 */
_HotPathResetForTest() {
	Owner := _HotPathNestingOwner()
	Owner.Tracker.Depth := 0
	loop HotPathNesting.MAX_DEPTH {
		Owner.Tracker.Pending[A_Index] := ""
		Owner.Tracker.Nested[A_Index] := 0
	}
	Owner.Gate.Reset()
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
		local now := PerfClockTicks()
		; A sub-step is a transparent span: it closes the frame HotPath_Now opened,
		; and its time stays the composite segment's own time.
		_HotPathNestingOwner().Tracker.Close(Label, StartTicks, now, "")
		if (Marks.Length >= _HOTPATH_BREAKDOWN_CAP)
			return ""
		if (_HOTPATH_QPC_FREQ == 0)
			_HOTPATH_QPC_FREQ := PerfClockFrequency()
		ElapsedMs := (_HOTPATH_QPC_FREQ > 0)
			? ((now - StartTicks) / _HOTPATH_QPC_FREQ * 1000.0) : 0.0
		Marks.Push({ L: Label, Ms: ElapsedMs })
		if IsSet(_HOTPATH_SLOW_MS)
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
		; Nested so a sub-millisecond keystroke, nearly all of them, pays one
		; comparison here: this method runs once per segment on the hot path.
		if (ElapsedMs >= 1) {
			Sample.Ge1 += 1
			Sample.Ge5 += ElapsedMs >= 5
			Sample.Ge10 += ElapsedMs >= 10
			Sample.Ge50 += ElapsedMs >= 50
		}
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
	static Owner := _HotPathStatisticsOwner()
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
	; Runs at priority -1, so no keystroke's frame is open: what is, was abandoned.
	Abandoned := _HotPathNestingOwner().Tracker.Sweep()
	if Abandoned
		PerfCount("hotpath.frames_swept", Abandoned)
	; Counted operations and process state share the minute: a stalled latency
	; window must not hide a leaking handle or a parse storm.
	try PerfCounters_Flush()
	catch as PerfErr
		try LoggerError("Perf", "Interval counters could not be published: {1}.", PerfErr.Message)
	try PhaseStats_MaybeFlush()
	catch as PhaseErr
		try LoggerError("Perf", "Phase summary could not be published: {1}.", PhaseErr.Message)
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





; ======================================================
; ======================================================
; ======= 4/ Interval counters and process state =======
; ======================================================
; ======================================================

; Counted operations (parses, rebuilds, hook events) complement timings: under a
; loaded host a wall-clock figure moves with the machine, while "this interval
; parsed 3 TOML files and rebuilt the menu twice" does not. Names are closed
; code literals, never typed text, paths or user content. Increments are plain
; Map arithmetic with no clock read, formatting or I/O; one evidence record per
; flush interval publishes and resets them, so it is never collapsed.

/** Owns the bounded counter registry; static so early include-order callers are safe. */
_PerfCountersOwner() {
	static Owner := { Counts: Map(), Refused: 0, Limit: 192, WindowStartMs: 0 }
	return Owner
}

/** Adds to a named interval counter; a full registry refuses visibly through the flush. */
PerfCount(Name, Amount := 1) {
	Owner := _PerfCountersOwner()
	Counts := Owner.Counts
	if Counts.Has(Name) {
		Counts[Name] += Amount
		return true
	}
	if Counts.Count >= Owner.Limit {
		Owner.Refused += 1
		return false
	}
	Counts[Name] := Amount
	return true
}

/** Opens a stage measurement; pair with PerfStage_End. Two QPC reads in total. */
PerfStage_Begin() {
	return PerfClockTicks()
}

/** Microseconds since PerfStage_Begin, without recording anything; for per-name counters. */
PerfElapsedUs(StartTicks) {
	global _HOTPATH_QPC_FREQ
	if !IsSet(_HOTPATH_QPC_FREQ)
		return 0
	local now := 0
	if (_HOTPATH_QPC_FREQ == 0)
		_HOTPATH_QPC_FREQ := PerfClockFrequency()
	now := PerfClockTicks()
	return Round((now - StartTicks) / _HOTPATH_QPC_FREQ * 1000000)
}

/** Records a stage's duration into the latency summaries; the debug line is built only when enabled. */
PerfStage_End(Label, StartTicks, Count := -1) {
	global _HOTPATH_QPC_FREQ, _HOTPATH_SLOW_MS
	if !IsSet(_HOTPATH_QPC_FREQ) || !IsSet(_HOTPATH_SLOW_MS)
		return 0.0
	local now := 0
	if (_HOTPATH_QPC_FREQ == 0)
		_HOTPATH_QPC_FREQ := PerfClockFrequency()
	now := PerfClockTicks()
	ElapsedMs := (now - StartTicks) / _HOTPATH_QPC_FREQ * 1000.0
	HotPath_RecordLatency(Label, ElapsedMs, _HOTPATH_SLOW_MS)
	; Total microseconds per stage ride the interval counter record, so a stage's cost
	; is visible even where the repeat collapser folds its debug lines.
	PerfCount("us." . Label, Round(ElapsedMs * 1000))
	if LoggerIsDebugEnabled()
		try LoggerDebug("Perf", "Stage '{1}' took {2} ms (count={3}).", Label, Round(ElapsedMs, 3), Count)
	return ElapsedMs
}

/** Reads this process's memory and kernel-object counts; every field is -1 when its call fails. */
PerfProcessState() {
	State := { WorkingSetMb: -1, PeakWorkingSetMb: -1, PrivateMb: -1, Handles: -1, GdiObjects: -1, UserObjects: -1 }
	ProcessResourceState(State)
	return State
}

/** Renders the counters as "name=n" pairs in name order so consecutive records diff cleanly. */
PerfCountersText(Counts) {
	Names := []
	for Name in Counts
		Names.Push(Name)
	Names := StrSplit(Sort(_PerfJoin(Names), "D|"), "|")
	Text := ""
	for Name in Names
		if Name != ""
			Text .= (Text == "" ? "" : " ") . Name . "=" . Counts[Name]
	return Text
}

_PerfJoin(Names) {
	Text := ""
	for Name in Names
		Text .= (Text == "" ? "" : "|") . Name
	return Text
}

/** Publishes and resets the interval counters, then the process state; one evidence record each. */
PerfCounters_Flush() {
	Owner := _PerfCountersOwner()
	PreviousCritical := Critical("On")
	try {
		Counts := Owner.Counts
		Refused := Owner.Refused
		Started := Owner.WindowStartMs
		Owner.Counts := Map()
		Owner.Refused := 0
		Owner.WindowStartMs := A_TickCount
	} finally Critical(PreviousCritical)
	IntervalMs := Started ? ((A_TickCount - Started) & 0xFFFFFFFF) : 0
	if Counts.Count > 0
		try LoggerEvidence("Perf", "Interval counters ({1} ms): {2}.", IntervalMs, PerfCountersText(Counts))
	if Refused > 0
		try LoggerWarn("Perf", "Interval counters refused {1} increment(s) beyond the registry capacity.", Refused)
	if IsSet(TOML_DocumentParseOwnersTake) {
		ParseOwners := TOML_DocumentParseOwnersTake()
		if ParseOwners.Count > 0
			try LoggerEvidence("Perf", "Document parses by owner ({1} ms): {2}.", IntervalMs, PerfCountersText(ParseOwners))
	}
	State := PerfProcessState()
	; The log-volume figures ride on this record as they ride on the macOS memory
	; record: both are process-wide and one record per interval is what is read back.
	try LoggerEvidence("Perf",
		"Process state: working_set_mb={1} peak_working_set_mb={2} private_mb={3} handles={4} gdi_objects={5} user_objects={6}. Log volume over {7} s: {8}.",
		State.WorkingSetMb, State.PeakWorkingSetMb, State.PrivateMb, State.Handles,
		State.GdiObjects, State.UserObjects, IntervalMs // 1000, LoggerVolumeText(LoggerVolumeInterval()))
}
