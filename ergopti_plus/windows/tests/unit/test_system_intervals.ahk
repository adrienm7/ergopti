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

_KLSI_Conservation(Offset) {
	Actions := ["lock", "unlock", "sleep", "wake"]
	Ticks := [0, 0, 7, 19, 19, 31, 43]
	; Six edges enumerate every combination, including duplicates, missing starts
	; and equal-time transitions. Integrate occupancy over adjacent time slices;
	; the oracle does not reproduce the production interval emission algorithm.
	loop 4 ** 6 {
		SequenceId := A_Index - 1
		Remaining := SequenceId
		Steps := []
		Locked := false
		Sleeping := false
		ExpectedLock := 0
		ExpectedSleep := 0
		loop 6 {
			Index := A_Index
			Action := Actions[Mod(Remaining, 4) + 1]
			Remaining := Remaining // 4
			Steps.Push([Action, Offset + Ticks[Index]])
			switch Action {
				case "lock": Locked := true
				case "unlock": Locked := false
				case "sleep": Sleeping := true
				case "wake": Sleeping := false
			}
			Elapsed := Ticks[Index + 1] - Ticks[Index]
			if Sleeping
				ExpectedSleep += Elapsed
			else if Locked
				ExpectedLock += Elapsed
		}
		Steps.Push(["finish", Offset + Ticks[7]])
		try _KLSI_Sequence(Steps, ExpectedLock, ExpectedSleep)
		catch Error as Failure {
			Failure.Message := "Sequence " . SequenceId . " offset=" . Offset . ": " . Failure.Message
			throw Failure
		}
	}
}

for Offset in [0, 0x100000000]
	Test("system intervals: all six-edge combinations conserve occupancy offset=" . Offset
		. " (system-interval-conservation)", _KLSI_Conservation.Bind(Offset))
