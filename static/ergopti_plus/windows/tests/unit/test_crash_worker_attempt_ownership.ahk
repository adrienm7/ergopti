; tests/unit/test_crash_worker_attempt_ownership.ahk

; ==============================================================================
; MODULE: Crash Worker Attempt Ownership Tests
; DESCRIPTION:
; A refused start is not an exit receipt. Exercise primary and fallback refusal
; with real transport mappings, retaining the exact task until acknowledged exit.
; ==============================================================================

#Requires AutoHotkey v2.0

class _CWAO_Task {
	__New(Done, StartResult, StopResult) {
		this.Done := Done
		this.StartResult := StartResult
		this.StopResult := StopResult
		this.StopCalls := 0
	}

	start() {
		return this.StartResult
	}

	terminate() {
		this.StopCalls += 1
		return this.StopResult
	}
}

_CWAO_Spawn(State, Executable, Args, Done) {
	global _CrashReportWorkerOwners
	if !State.Owner {
		for _, Owner in _CrashReportWorkerOwners {
			if Owner["mapping"]["name"] == Args[Args.Length] {
				State.Owner := Owner
				break
			}
		}
		AssertTrue(State.Owner is Map, "the primary arguments must identify the exact transport owner")
	}
	Fails := State.Tasks.Length + 1 = State.FailAt
	Task := _CWAO_Task(Done, !Fails, !Fails || State.StopAcknowledged)
	State.Tasks.Push(Task)
	return Task
}

_CWAO_Done(State, ExitCode, Stdout, Stderr) {
	State.Results.Push([ExitCode, Stdout, Stderr])
}

_CWAO_AttemptRefusal(FailAt, StopAcknowledged, CompleteByCallback) {
	global _CrashReportWorkerOwners
	State := {Owner: 0, Tasks: [], Results: [], FailAt: FailAt,
		StopAcknowledged: StopAcknowledged}
	try {
		; The fake task never executes this existing path; no fixture file is needed.
		Started := CrashReportWorker_Start("{}", _CWAO_Done.Bind(State),
			_CWAO_Spawn.Bind(State), A_ScriptFullPath)
		Owner := State.Owner
		AssertTrue(Owner is Map)
		Mapping := Owner["mapping"]
		if FailAt = 2 {
			AssertTrue(Started is Map)
			State.Tasks[1].Done.Call(7, "primary output", "primary failure")
		}
		if StopAcknowledged {
			AssertEqual(2, State.Tasks.Length,
				"confirmed primary exit must permit exactly one fallback")
			if FailAt = 1 {
				AssertTrue(Started is Map)
				AssertEqual(0, State.Results.Length)
				AssertFalse(Mapping["closed"])
				State.Tasks[2].Done.Call(0, "fallback output", "")
			}
			AssertEqual(1, State.Results.Length)
			AssertEqual(FailAt = 1 ? 0 : 7, State.Results[1][1])
			AssertEqual(FailAt = 1 ? "fallback output" : "primary output", State.Results[1][2])
			AssertEqual(FailAt = 1 ? "" : "primary failure", State.Results[1][3])
		} else {
			if FailAt = 1
				AssertEqual(0, Started, "a failed primary must not publish startup success")
			AssertEqual(FailAt, State.Tasks.Length,
				"an unconfirmed task must prevent a successor attempt")
			AssertTrue(_CrashReportWorkerOwners.Has(Owner["id"]),
				"start refusal must retain the unconfirmed task's registry owner")
			AssertEqual(ObjPtr(Owner), ObjPtr(_CrashReportWorkerOwners[Owner["id"]]))
			AssertEqual(ObjPtr(State.Tasks[FailAt]), ObjPtr(Owner["task"]))
			AssertEqual(FailAt, Owner["attempt"])
			AssertFalse(Mapping["closed"], "the retained task still owns its transport")
			AssertEqual(0, State.Results.Length, "no terminal callback before confirmed exit")
			if FailAt = 2 {
				State.Tasks[1].Done.Call(9, "stale", "stale")
				AssertFalse(Mapping["closed"])
				AssertEqual(ObjPtr(State.Tasks[2]), ObjPtr(Owner["task"]))
			}
			if CompleteByCallback
				State.Tasks[FailAt].Done.Call(0, "cancelled task output", "")
			else {
				AssertFalse(_CrashReportWorkerCancelOwner(Owner))
				AssertFalse(Mapping["closed"])
				State.Tasks[FailAt].StopResult := true
				AssertTrue(_CrashReportWorkerCancelOwner(Owner))
			}
			AssertEqual(0, State.Results.Length, "cancelled failed starts must never deliver success")
		}
		AssertTrue(Mapping["closed"])
		AssertEqual(0, Mapping["handle"])
		AssertFalse(_CrashReportWorkerOwners.Has(Owner["id"]))
		ResultCount := State.Results.Length
		for Task in State.Tasks
			Task.Done.Call(0, "late duplicate", "")
		AssertEqual(ResultCount, State.Results.Length, "late callbacks cannot notify twice")
	} finally {
		for Task in State.Tasks
			Task.StopResult := true
		if State.Owner is Map
			AssertTrue(_CrashReportWorkerCancelOwner(State.Owner), "exact fixture owner cleanup must succeed")
	}
}

for FailAt in [1, 2] {
	for CompleteByCallback in [false, true]
		Test("crash worker: refused attempt=" . FailAt . " callback=" . CompleteByCallback
			. " retains ownership (crash-worker-attempt-ownership)",
			_CWAO_AttemptRefusal.Bind(FailAt, false, CompleteByCallback))
	Test("crash worker: acknowledged attempt=" . FailAt
		. " preserves fallback completion (crash-worker-attempt-ownership)",
		_CWAO_AttemptRefusal.Bind(FailAt, true, false))
}
