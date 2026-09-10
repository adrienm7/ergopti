; tests/unit/test_system_event_owner.ahk

; ==============================================================================
; MODULE: System Event Delivery Tests
; DESCRIPTION: Exercise append refusal, committed failures and reentrant lifecycle ownership.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../modules/keylogger/keylogger_system_event_owner.ahk

class _KLSO_Fixture {
	__New() {
		this.Tick := 0
		this.Allowed := true
		this.Mode := "ok"
		this.Events := []
		this.Reenter := 0
		this.Owner := KLSystemEventOwner(this.Frame.Bind(this), this.Append.Bind(this), () => this.Allowed)
	}
	Frame() {
		return Map("tick", this.Tick, "timestamp", "2026-01-01 10:00:00." . Format("{:03}", this.Tick))
	}
	Append(Entry, Guard, Commit) {
		if HasMethod(this.Reenter, "Call") {
			Reenter := this.Reenter
			this.Reenter := 0
			Reenter.Call()
		}
		if this.Mode = "throw-before"
			throw Error("synthetic append failure")
		if this.Mode = "refuse"
			return false
		if this.Mode = "lie"
			return true
		if !Guard.Call()
			return false
		this.Events.Push(Entry.Clone())
		Commit.Call()
		if this.Mode = "throw-after"
			throw Error("synthetic post-commit failure")
		return true
	}
	Step(Action, Tick) {
		this.Tick := Tick
		return this.Owner.Observe(Action)
	}
	Measures() {
		Rows := []
		for Entry in this.Events
			if Entry["action"] = "passive_period"
				Rows.Push(Entry)
		return Rows
	}
}

_KLSO_Normal() {
	F := _KLSO_Fixture()
	for Step in [["lock", 10], ["sleep", 20], ["wake", 60], ["wake", 65], ["unlock", 90]]
		AssertTrue(F.Step(Step[1], Step[2]))
	Rows := F.Measures()
	AssertEqual(3, Rows.Length)
	for Index, Expected in [["lock", 10], ["sleep", 40], ["lock", 30]] {
		AssertEqual(Expected[1], Rows[Index]["kind"])
		AssertEqual(Expected[2], Rows[Index]["duration_ms"])
	}
	AssertEqual(8, F.Events.Length, "raw transitions remain alongside three disjoint measurements")
}

_KLSO_PrivacyDrop() {
	F := _KLSO_Fixture()
	F.Step("sleep", 10)
	F.Mode := "refuse"
	AssertTrue(F.Step("wake", 40), "privacy refusal is terminal, not technical delivery debt")
	AssertEqual(0, F.Owner.Pending.Length)
	F.Mode := "ok"
	F.Step("sleep", 100)
	F.Step("wake", 130)
	Rows := F.Measures()
	AssertEqual(1, Rows.Length, "a later public context must not replay the refused interval")
	AssertEqual(30, Rows[1]["duration_ms"])
}

_KLSO_AppendFailure(Mode) {
	F := _KLSO_Fixture()
	F.Step("lock", 10)
	F.Mode := Mode
	AssertFalse(F.Step("unlock", 30))
	AssertEqual("append-exception", F.Owner.LastFailure)
	AssertEqual(Mode = "throw-before" ? 2 : 1, F.Owner.Pending.Length)
	F.Tick := 900
	F.Mode := "ok"
	AssertTrue(F.Owner.Drain())
	Rows := F.Measures()
	AssertEqual(1, Rows.Length)
	AssertEqual(20, Rows[1]["duration_ms"], "retry must not extend a physically completed interval")
	AssertEqual("2026-01-01 10:00:00.030", Rows[1]["timestamp"])
	AssertEqual(3, F.Events.Length, "a post-commit exception must not duplicate the accepted raw row")
}

_KLSO_StopDebt() {
	F := _KLSO_Fixture()
	F.Step("lock", 10)
	F.Tick := 40
	F.Mode := "throw-before"
	AssertFalse(F.Owner.Stop())
	F.Tick := 900
	F.Mode := "ok"
	AssertTrue(F.Owner.Stop())
	AssertTrue(F.Owner.Stop())
	AssertEqual(1, F.Measures().Length)
	AssertEqual(30, F.Measures()[1]["duration_ms"])
	Rejected := false
	try F.Step("lock", 901)
	catch Error {
		Rejected := true
	}
	AssertTrue(Rejected, "stopped owners must reject new observations")
}

_KLSO_ResetDuringAppend() {
	F := _KLSO_Fixture()
	F.Reenter := ResetAndObserve
	AssertTrue(F.Step("lock", 10))
	AssertEqual(1, F.Events.Length)
	AssertEqual("sleep", F.Events[1]["action"], "an obsolete attempt must not remove the new head")
	F.Step("wake", 80)
	AssertEqual(1, F.Measures().Length)
	AssertEqual(30, F.Measures()[1]["duration_ms"])
	ResetAndObserve() {
		F.Owner.Reset()
		F.Step("sleep", 50)
	}
}

_KLSO_StopDuringAppend() {
	F := _KLSO_Fixture()
	InnerResult := true
	F.Reenter := StopDuringAppend
	AssertTrue(F.Step("lock", 10))
	AssertFalse(InnerResult, "a nested stop cannot declare the active outer drain complete")
	AssertFalse(F.Owner.Stopped)
	AssertTrue(F.Owner.Stop())
	AssertEqual(1, F.Measures().Length)
	AssertEqual(30, F.Measures()[1]["duration_ms"])
	StopDuringAppend() {
		F.Tick := 40
		InnerResult := F.Owner.Stop()
	}
}

_KLSO_PauseEmptyQueue() {
	F := _KLSO_Fixture()
	F.Step("lock", 10)
	F.Allowed := false
	AssertTrue(F.Owner.Drain())
	F.Allowed := true
	F.Step("unlock", 90)
	AssertEqual(0, F.Measures().Length, "pause must invalidate an open interval even with no pending rows")
}

_KLSO_BrokenCommitPort() {
	F := _KLSO_Fixture()
	F.Mode := "lie"
	AssertFalse(F.Step("lock", 10))
	AssertEqual("append-contract", F.Owner.LastFailure)
	AssertEqual(1, F.Owner.Pending.Length, "claimed success without commit is not delivery")
}

Test("system owner: raw and measured events retain disjoint durations (system-event-owner)", _KLSO_Normal)
Test("system owner: privacy refusals never become retry debt (system-event-owner)", _KLSO_PrivacyDrop)
for Mode in ["throw-before", "throw-after"]
	Test("system owner: " . Mode . " retains exact delivery ownership (system-event-owner)", _KLSO_AppendFailure.Bind(Mode))
Test("system owner: stop retries the original closing interval (system-event-owner)", _KLSO_StopDebt)
Test("system owner: reset during append preserves the new queue head (system-event-owner)", _KLSO_ResetDuringAppend)
Test("system owner: reentrant stop waits for the active drain (system-event-owner)", _KLSO_StopDuringAppend)
Test("system owner: pause invalidates intervals without pending rows (system-event-owner)", _KLSO_PauseEmptyQueue)
Test("system owner: append success requires its commit callback (system-event-owner)", _KLSO_BrokenCommitPort)
