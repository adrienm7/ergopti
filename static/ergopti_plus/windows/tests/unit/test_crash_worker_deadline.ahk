; tests/unit/test_crash_worker_deadline.ahk

; ==============================================================================
; MODULE: Crash Worker Deadline Tests
; DESCRIPTION:
; Optional enrichment must not retain the crash snapshot forever. Exercise an
; unresponsive primary through the same task contract as native workers.
; ==============================================================================

#Requires AutoHotkey v2.0

_CWDL_RejectTimer(State, Callback, Period) {
	State.TimerAttempts += 1
	throw Error("Injected deadline timer arm failure")
}

_CWDL_Spawn(State, Executable, Args, Done) {
	Task := _CWAO_Spawn(State, Executable, Args, Done)
	if State.Tasks.Length = 1 && State.RefusePrimary
		Task.StopResult := false
	return Task
}

_CWDL_PrimaryDeadline(Mode := "fallback") {
	State := {Owner: 0, Tasks: [], Results: [], FailAt: 0, StopAcknowledged: true, TimerAttempts: 0,
		RefusePrimary: Mode = "refused" || Mode = "timer-error"}
	PreviousSuspend := A_IsSuspended
	try {
		Suspend(Mode = "suspended")
		PreviousCritical := Critical("On")
		try {
			Owner := CrashReportWorker_Start("{}", _CWAO_Done.Bind(State),
				_CWDL_Spawn.Bind(State), A_ScriptFullPath, Map("primary_budget_ms", 50))
			AssertTrue(Owner is Map, "the primary must publish its retained owner")
			Deadline := Owner["deadline_callback"]
			if Mode = "normal" || Mode = "cancel" || Mode = "timer-error"
				SetTimer(Deadline, 0)
		} finally Critical(PreviousCritical)
		if Mode = "normal" || Mode = "cancel" {
			if Mode = "normal"
				State.Tasks[1].Done.Call(0, "primary report", "")
			else
				AssertTrue(_CrashReportWorkerCancelOwner(Owner))
			Deadline.Call()
			AssertEqual(1, State.Tasks.Length, "retirement must revoke a stale deadline")
			AssertEqual(Mode = "normal" ? 1 : 0, State.Results.Length)
			if Mode = "normal"
				AssertEqual("primary report", State.Results[1][2])
			AssertTrue(Owner["mapping"]["closed"])
			return
		}
		if Mode = "suspended" {
			Sleep(150)
			AssertEqual(0, State.Tasks[1].StopCalls, "suspension must defer the deadline action")
			AssertEqual(1, State.Tasks.Length)
			Suspend(false)
		}
		if Mode = "refused" || Mode = "timer-error" {
			if Mode = "timer-error" {
				_CrashReportWorkerDeadlineTick(Owner, 1, _CWDL_RejectTimer.Bind(State))
				AssertEqual(1, State.TimerAttempts)
				AssertTrue(Owner["deadline_arm_failed"], "timer refusal must remain observable")
				_CrashReportWorkerDeadlineTick(Owner, 1)
				AssertFalse(Owner["deadline_arm_failed"], "an explicit retry must restore scheduling")
			} else
				AssertTrue(_CRWT_WaitUntil(() => State.Tasks[1].StopCalls > 0, 2000))
			AssertEqual(1, State.Tasks.Length, "a refused stop must prevent a concurrent successor")
			AssertEqual(0, State.Results.Length)
			AssertFalse(Owner["mapping"]["closed"])
			AssertEqual(ObjPtr(State.Tasks[1]), ObjPtr(Owner["task"]))
			State.Tasks[1].StopResult := true
		}
		AssertTrue(_CRWT_WaitUntil(() => State.Tasks.Length = 2, 2000),
			"an unresponsive primary must reach the isolated fallback within its budget")
		AssertTrue(State.Tasks[1].StopCalls > 0, "the primary must be stopped before its successor")
		if Mode = "fallback"
			AssertEqual(1, State.Tasks[1].StopCalls, "the successful first stop must not be repeated")
		AssertEqual(ObjPtr(State.Tasks[2]), ObjPtr(Owner["task"]))
		AssertFalse(Owner["mapping"]["closed"], "fallback still owns the original snapshot")
		AssertEqual(0, State.Results.Length, "expiration alone is not a successful report")
		Deadline.Call()
		AssertEqual(0, State.Tasks[2].StopCalls, "a stale primary deadline cannot terminate the fallback")
		State.Tasks[1].Done.Call(0, "late primary", "")
		AssertEqual(0, State.Results.Length, "a retired primary cannot publish success")
		State.Tasks[2].Done.Call(0, "fallback report", "")
		AssertEqual(1, State.Results.Length)
		AssertEqual("fallback report", State.Results[1][2])
		AssertTrue(Owner["mapping"]["closed"])
		AssertFalse(_CrashReportWorkerOwners.Has(Owner["id"]))
	} finally {
		try {
			for Task in State.Tasks
				Task.StopResult := true
			if State.Owner is Map
				AssertTrue(_CrashReportWorkerCancelOwner(State.Owner), "exact deadline fixture cleanup must succeed")
		} finally Suspend(PreviousSuspend)
	}
}

Test("crash worker: primary deadline preserves fallback ownership (crash-worker-primary-deadline)",
	_CWDL_PrimaryDeadline)
for Mode in ["normal", "cancel", "suspended", "refused", "timer-error"]
	Test("crash worker: primary deadline handles " . Mode . " (crash-worker-primary-deadline)",
		_CWDL_PrimaryDeadline.Bind(Mode))

_CWDL_InvalidBudget(Budget) {
	State := {Owner: 0, Tasks: [], Results: [], FailAt: 0, StopAcknowledged: true}
	OwnersBefore := _CrashReportWorkerOwners.Count
	Failure := 0
	try {
		try CrashReportWorker_Start("{}", _CWAO_Done.Bind(State),
			_CWAO_Spawn.Bind(State), A_ScriptFullPath, Map("primary_budget_ms", Budget))
		catch as Err
			Failure := Err
		AssertTrue(Failure is ValueError, "invalid budgets must fail before native ownership begins")
		AssertEqual(0, State.Tasks.Length, "invalid budgets must not reach the spawn port")
		AssertEqual(OwnersBefore, _CrashReportWorkerOwners.Count)
	} finally {
		if State.Owner is Map
			AssertTrue(_CrashReportWorkerCancelOwner(State.Owner))
	}
}

for Budget in [0, -1, "50", 1.5, CRASH_REPORT_WORKER_PRIMARY_BUDGET_MS + 1]
	Test("crash worker: rejects primary budget " . Type(Budget) . " " . Budget
		. " (crash-worker-primary-deadline)", _CWDL_InvalidBudget.Bind(Budget))
