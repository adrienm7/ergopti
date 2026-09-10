; tests/unit/test_system_intervals.ahk

; ==============================================================================
; MODULE: System Passive Interval Tests
; DESCRIPTION: Exercise disjoint physical intervals before publication and lifecycle integration.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../modules/keylogger/keylogger_system_intervals.ahk

_KLSI_Sequence(Steps, Locked, Sleep) {
	Intervals := KLSystemIntervals()
	Totals := Map("lock", 0, "sleep", 0)
	for Step in Steps {
		if Step[1] == "reset" {
			Intervals.Reset()
			continue
		}
		Completed := Step[1] == "finish" ? Intervals.Finish(Step[2])
			: Intervals.Observe(Step[1], Step[2])
		if Completed
			Totals[Completed["kind"]] += Completed["duration_ms"]
	}
	AssertEqual(Locked, Totals["lock"], "locked time must exclude overlapping sleep")
	AssertEqual(Sleep, Totals["sleep"], "each observed sleep interval must be consumed once")
}

_KLSI_InvalidTransition() {
	Intervals := KLSystemIntervals()
	Intervals.Observe("sleep", 100)
	for Spec in [["wake", 99], ["unknown", 101], ["wake", 100.5], ["WAKE", 101]] {
		Rejected := false
		try Intervals.Observe(Spec[1], Spec[2])
		catch ValueError {
			Rejected := true
		}
		AssertTrue(Rejected, "invalid input must reject before moving the physical boundary")
		AssertEqual("sleep", Intervals.Kind)
		AssertEqual(100, Intervals.LastTick)
		AssertEqual(100, Intervals.Since)
	}
	Completed := Intervals.Observe("wake", 120)
	AssertEqual(20, Completed["duration_ms"])
}

_KLSI_ResetGeneration() {
	Intervals := KLSystemIntervals()
	Before := Intervals.Generation
	Intervals.Observe("lock", 0)
	Completed := Intervals.Observe("sleep", 10)
	Intervals.Reset()
	AssertTrue(Intervals.Generation > Before, "old publication tickets must detect collection invalidation")
	AssertEqual(10, Completed["duration_ms"], "detached values do not alias mutable state")
	AssertEqual(0, Intervals.Observe("unlock", 20))
	AssertEqual(0, Intervals.Observe("wake", 30))
}

Test("system intervals: paired wake notifications consume one sleep (system-intervals)",
	_KLSI_Sequence.Bind([["sleep", 10], ["wake", 40], ["wake", 80]], 0, 30))
Test("system intervals: nested lock and sleep are disjoint (system-intervals)",
	_KLSI_Sequence.Bind([["lock", 10], ["sleep", 20], ["wake", 60], ["wake", 65], ["unlock", 90]], 40, 40))
Test("system intervals: unlock during sleep does not reopen lock (system-intervals)",
	_KLSI_Sequence.Bind([["lock", 10], ["sleep", 20], ["unlock", 30], ["wake", 60]], 10, 40))
Test("system intervals: duplicate starts retain the original boundary (system-intervals)",
	_KLSI_Sequence.Bind([["lock", 10], ["lock", 15], ["sleep", 20], ["sleep", 30], ["wake", 60], ["unlock", 90]], 40, 40))
Test("system intervals: unobserved starts do not invent durations (system-intervals)",
	_KLSI_Sequence.Bind([["wake", 10], ["unlock", 20]], 0, 0))
Test("system intervals: reset excludes an unobserved pause (system-intervals)",
	_KLSI_Sequence.Bind([["lock", 10], ["reset", 20], ["unlock", 90]], 0, 0))
Test("system intervals: uptime does not wrap after 32 bits (system-intervals)",
	_KLSI_Sequence.Bind([["sleep", 0x100000001], ["wake", 0x100000051]], 0, 80))
Test("system intervals: terminal drain closes exactly once (system-intervals)",
	_KLSI_Sequence.Bind([["lock", 0], ["finish", 40], ["finish", 50]], 40, 0))
Test("system intervals: invalid observations retain ownership (system-intervals)", _KLSI_InvalidTransition)
Test("system intervals: reset invalidates tickets but not detached records (system-intervals)", _KLSI_ResetGeneration)
