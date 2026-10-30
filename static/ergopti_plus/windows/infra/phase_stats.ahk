; infra/phase_stats.ahk

; ==============================================================================
; MODULE: Phase Stats
; DESCRIPTION:
; Open-named phase timing for work PerfStage's fixed labels do not cover: one phase
; per child program (process.<program>), boot sub-stages (boot.stage,
; boot.stage_cpu), config parses (toml.parse), tray rebuilds (menu.rebuild). The
; AutoHotkey port of _shared/lua/phase_stats_core.lua: the same phases and the same
; evidence line, so one search reads a log from any OS.
;
; FEATURES & RATIONALE:
; 1. Near-zero cost: recording is one clock read and three Map updates, no string
;    is built; the flush formats text only when INFO is enabled.
; 2. Closed names only: a phase name is a source constant or a program basename.
;    The command line, which can carry user text, never reaches it.
; 3. No timer of its own: the one-minute latency summary calls PhaseStats_MaybeFlush,
;    so there is nothing more to stop at shutdown.
; 4. Includable anywhere: the owner is a function static, valid before any
;    #Include's top-level code has run, and the file depends only on the boot clock.
; 5. Windows has no Lua heap to report: the core's memory line has its counterpart
;    in the Perf process-state record, which also carries the log-volume figures.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../adapters/boot_clock.ahk





; ===========================
; ===========================
; ======= 1/ Instance =======
; ===========================
; ===========================

class PhaseStatsStore {
	; Phases at least this long also enter the attribution ring. The ring holds the
	; last slow phases a held callback can name, not keystrokes.
	static RING_MIN_MS => 2
	static ATTRIBUTION_RING_SIZE => 32
	; A family line lists at most this many phases, busiest first by total time.
	static MAX_PHASES_PER_LINE => 24
	; The report names at most this many phases.
	static MAX_ATTRIBUTED => 5
	; The interval of the summary, in seconds: DEFAULT_FLUSH_SECONDS of the Lua core.
	static DEFAULT_INTERVAL_SEC => 300

	; @param InfoEnabledFn {Func} Whether INFO lines are written.
	; @param EvidenceFn {Func} Writes one never-collapsed record: fn(Format, Args*).
	; @param NowMsFn {Func} The monotonic clock, in milliseconds.
	__New(InfoEnabledFn, EvidenceFn, NowMsFn) {
		this.InfoEnabledFn := InfoEnabledFn
		this.EvidenceFn := EvidenceFn
		this.NowMsFn := NowMsFn
		this.Reset()
	}

	; Clears every phase, counter and ring entry.
	Reset() {
		this.Phases := Map()
		this.Counters := Map()
		this.Ring := []
		this.RingHead := 0
	}

	; @returns {Float} The monotonic clock, in milliseconds.
	Now() => this.NowMsFn.Call()

	; Adds one occurrence of Name that lasted ElapsedMs.
	; @param Name {String} Closed phase name, family.phase.
	; @param ElapsedMs {Number}
	Add(Name, ElapsedMs) {
		PreviousCritical := Critical("On")
		try {
			if !this.Phases.Has(Name)
				this.Phases[Name] := { N: 0, Total: 0, Max: 0 }
			Phase := this.Phases[Name]
			Phase.N += 1
			Phase.Total += ElapsedMs
			if (ElapsedMs > Phase.Max)
				Phase.Max := ElapsedMs
			if (ElapsedMs >= PhaseStatsStore.RING_MIN_MS) {
				this.RingHead := Mod(this.RingHead, PhaseStatsStore.ATTRIBUTION_RING_SIZE) + 1
				Entry := { Name: Name, End: this.Now(), Ms: ElapsedMs }
				if (this.RingHead > this.Ring.Length)
					this.Ring.Push(Entry)
				else
					this.Ring[this.RingHead] := Entry
			}
		} finally Critical(PreviousCritical)
	}

	; Closes a phase opened with Now.
	; @param Name {String} Closed phase name.
	; @param StartMs {Number} From Now.
	; @returns {Float} The duration, in milliseconds.
	Stop(Name, StartMs) {
		ElapsedMs := this.Now() - StartMs
		this.Add(Name, ElapsedMs)
		return ElapsedMs
	}

	; Adds Amount to a plain event counter.
	; @param Name {String} Closed counter name, family.counter.
	; @param Amount {Number}
	Count(Name, Amount := 1) {
		this.Counters[Name] := this.Counters.Get(Name, 0) + Amount
	}

	; The live figures of a phase, for tests and diagnostics.
	; @param Name {String}
	; @returns {Object|Integer} { N, TotalMs, MaxMs }, 0 when never recorded.
	Figures(Name) {
		if !this.Phases.Has(Name)
			return 0
		Phase := this.Phases[Name]
		return { N: Phase.N, TotalMs: Phase.Total, MaxMs: Phase.Max }
	}

	; @param Name {String}
	; @returns {Number} A counter's value.
	Counter(Name) => this.Counters.Get(Name, 0)

	; Names the long phases that ended at or after SinceMs, longest first.
	; @param SinceMs {Number} From Now, when the held callback began.
	; @returns {String} "name=12.3 ms, name=4.1 ms", "" when none ran.
	RecentSince(SinceMs) {
		Found := []
		for Entry in this.Ring {
			if (Entry.End >= SinceMs)
				Found.Push(Entry)
		}
		_PhaseStatsSortDescending(Found, "Ms")
		Text := ""
		for Index, Entry in Found {
			if (Index > PhaseStatsStore.MAX_ATTRIBUTED)
				break
			Text .= (Text == "" ? "" : ", ") . Format("{1}={2:.1f} ms", Entry.Name, Entry.Ms)
		}
		return Text
	}

	; Emits one evidence line per family, then clears the figures. Text is formatted
	; only when INFO is enabled.
	; @param IntervalSec {Number} Seconds the figures cover, shown in the line.
	; @returns {Integer} Evidence lines emitted.
	Flush(IntervalSec) {
		PreviousCritical := Critical("On")
		try {
			Phases := this.Phases
			Counters := this.Counters
			this.Reset()
		} finally Critical(PreviousCritical)
		if !this.InfoEnabledFn.Call()
			return 0

		Families := Map()
		_PhaseStatsFamilies(Families, Phases, "Phases")
		_PhaseStatsFamilies(Families, Counters, "Counters")
		Names := ""
		for Family in Families
			Names .= (Names == "" ? "" : "`n") . Family
		Lines := 0
		for Family in StrSplit(Sort(Names), "`n") {
			if (Family == "")
				continue
			Entry := Families[Family]
			Rows := []
			for Name, Value in Entry.Phases
				Rows.Push({ Name: Name, Total: Value.Total, Phase: Value })
			_PhaseStatsSortDescending(Rows, "Total")
			Parts := ""
			for Index, Row in Rows {
				if (Index > PhaseStatsStore.MAX_PHASES_PER_LINE)
					break
				Parts .= (Parts == "" ? "" : " | ") . Format("{1} n={2} mean={3:.2f} max={4:.2f} total={5:.1f} ms",
					_PhaseStatsLeaf(Row.Name), Row.Phase.N, Row.Total / Row.Phase.N, Row.Phase.Max, Row.Total)
			}
			; A Map enumerates its keys in order: the counters print sorted by name.
			for Name, Value in Entry.Counters
				Parts .= (Parts == "" ? "" : " | ") . "#" . _PhaseStatsLeaf(Name) . "=" . Value
			this.EvidenceFn.Call("Phase summary [{1}] over {2} s: {3}.", Family, Floor(IntervalSec), Parts)
			Lines += 1
		}
		return Lines
	}
}

; The family of a phase name: the text before its first dot.
; @param Name {String}
; @returns {String}
_PhaseStatsFamily(Name) {
	Dot := InStr(Name, ".")
	return Dot ? SubStr(Name, 1, Dot - 1) : "misc"
}

; A phase name without its family.
; @param Name {String}
; @returns {String}
_PhaseStatsLeaf(Name) {
	Dot := InStr(Name, ".")
	return Dot ? SubStr(Name, Dot + 1) : Name
}

; Files each entry of Source under its family.
; @param Families {Map} Family name to { Phases: Map, Counters: Map }.
; @param Source {Map} Name to figures.
; @param Slot {String} "Phases" or "Counters".
_PhaseStatsFamilies(Families, Source, Slot) {
	for Name, Value in Source {
		Family := _PhaseStatsFamily(Name)
		if !Families.Has(Family)
			Families[Family] := { Phases: Map(), Counters: Map() }
		Families[Family].%Slot%[Name] := Value
	}
}

; Sorts a short Array of objects in place, largest Field first.
; @param Items {Array}
; @param Field {String}
_PhaseStatsSortDescending(Items, Field) {
	for Index, Item in Items {
		Slot := Index
		while (Slot > 1 && Items[Slot - 1].%Field% < Item.%Field%) {
			Items[Slot] := Items[Slot - 1]
			Slot -= 1
		}
		Items[Slot] := Item
	}
}





; ============================
; ============================
; ======= 2/ The Owner =======
; ============================
; ============================

; The driver's instance. A function static: a phase can be recorded before this
; file's include position, while a file-level global would still be unset.
; @returns {PhaseStatsStore}
PhaseStats() {
	static Owner := PhaseStatsStore(
		() => IsSet(_LOGGER_INFO_ENABLED) && _LOGGER_INFO_ENABLED,
		_PhaseStatsEvidence,
		BootClockWallMs)
	return Owner
}

_PhaseStatsEvidence(Template, Args*) {
	try LoggerEvidence("phase_stats", Template, Args*)
}

; @returns {Float} The clock to pass to PhaseStats_Stop.
PhaseStats_Now() => PhaseStats().Now()

; Closes a phase opened with PhaseStats_Now.
; @returns {Float} The duration, in milliseconds.
PhaseStats_Stop(Name, StartMs) => PhaseStats().Stop(Name, StartMs)

; Adds one occurrence of a phase already measured in milliseconds.
PhaseStats_AddMs(Name, ElapsedMs) => PhaseStats().Add(Name, ElapsedMs)

; Called from the one-minute latency summary: emits the summary when an interval
; has elapsed and starts the next one. The first call only opens the interval.
; @param Store {PhaseStatsStore} The instance; the driver's own by default.
; @param NowMs {Number} The clock, read when absent.
; @returns {Boolean} Whether the figures were flushed.
PhaseStats_MaybeFlush(Store := 0, NowMs := unset) {
	static IntervalStarts := Map()
	Target := IsObject(Store) ? Store : PhaseStats()
	Now := IsSet(NowMs) ? NowMs : Target.Now()
	Key := ObjPtr(Target)
	if !IntervalStarts.Has(Key) {
		IntervalStarts[Key] := Now
		return false
	}
	ElapsedSec := (Now - IntervalStarts[Key]) / 1000
	if (ElapsedSec < PhaseStatsStore.DEFAULT_INTERVAL_SEC)
		return false
	IntervalStarts[Key] := Now
	Target.Flush(ElapsedSec)
	return true
}
