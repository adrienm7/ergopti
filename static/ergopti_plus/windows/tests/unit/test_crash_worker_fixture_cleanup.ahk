; tests/unit/test_crash_worker_fixture_cleanup.ahk

; ==============================================================================
; MODULE: Crash Worker Fixture Cleanup Tests
; DESCRIPTION:
; A failed integration wait must not abandon its exact worker before the outer
; fixture removes output files. Immediate wait refusal reproduces the deadline
; failure without sleeping or starting an external process.
; ==============================================================================

#Requires AutoHotkey v2.0

class _CWFC_Task {
	__New(Control, Done) {
		this.Control := Control
		this.Done := Done
		this.Stopped := false
	}

	start() {
		return !this.Stopped && this.Control.StartResult
	}

	terminate() {
		this.Control.Terminations += 1
		if IsObject(this.Control.OnTerminate)
			this.Control.OnTerminate.Call()
		if this.Control.StopResult
			this.Stopped := true
		return this.Control.StopResult
	}
}

_CWFC_State(StartResult := true, StopResult := true) {
	return {Task: 0, Owner: 0, Spawns: 0, Scope: 0, WaitError: 0,
		Control: {StartResult: StartResult, StopResult: StopResult,
			Terminations: 0, OnTerminate: 0}}
}

_CWFC_Spawn(State, Executable, Args, Done) {
	State.Spawns += 1
	State.Task := _CWFC_Task(State.Control, Done)
	return State.Task
}

_CWFC_RefuseWait(State, Predicate, TimeoutMs) {
	global _CrashReportWorkerOwners
	for _, Owner in _CrashReportWorkerOwners {
		if IsObject(Owner.Get("task", 0)) && ObjPtr(Owner["task"]) = ObjPtr(State.Task) {
			State.Owner := Owner
			break
		}
	}
	AssertTrue(State.Owner is Map, "the wait must observe its exact live worker")
	if State.Scope is _CRWF_Fixture
		AssertTrue(State.Scope.Owners.Has(ObjPtr(State.Owner)), "fixture ownership must precede the wait")
	if State.WaitError is Error
		throw State.WaitError
	return false
}

_CWFC_FailedWaitRetiresWorker() {
	global _CrashReportWorkerOwners
	State := _CWFC_State()
	Scope := _CRWF_Fixture("failed_wait")
	State.Scope := Scope
	try {
		Failure := 0
		try Scope.Run((Fixture) => _CRWT_StartAndWait(Map(), Fixture, 0,
			_CWFC_Spawn.Bind(State), _CWFC_RefuseWait.Bind(State)))
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, "integration deadline")
		AssertFalse(_CrashReportWorkerOwners.Has(State.Owner["id"]),
			"a failed wait must retire its worker before outer fixture deletion")
		AssertTrue(State.Owner["mapping"]["closed"])
	} finally {
		if State.Owner is Map
			AssertTrue(_CrashReportWorkerCancelOwner(State.Owner), "exact regression fixture cleanup must succeed")
		Scope.Finish()
	}
}

Test("crash worker fixture: failed wait retires its exact owner (crash-worker-fixture-cleanup)",
	_CWFC_FailedWaitRetiresWorker)

_CWFC_Delete(State, Path) {
	State.Calls += 1
	if !State.Allow
		return false
	return _CRWF_DeleteDirectory(Path)
}

_CWFC_WaitFailureOwnership(StopResult, ThrowWait) {
	global _CrashReportWorkerOwners, _CRWF_PendingCleanup
	DeleteState := {Calls: 0, Allow: true}
	Scope := _CRWF_Fixture("wait_matrix", _CWFC_Delete.Bind(DeleteState))
	State := _CWFC_State(true, StopResult)
	State.Scope := Scope
	if ThrowWait
		State.WaitError := Error("sentinel wait failure")
	OtherState := _CWFC_State()
	OtherOwner := 0
	try {
		OtherOwner := CrashReportWorker_Start("{}", (*) => 0,
			_CWFC_Spawn.Bind(OtherState), A_ScriptFullPath)
		Sentinel := Scope.Directory . "\sentinel.txt"
		FileAppend("retained fixture bytes", Sentinel, "UTF-8-RAW")
		Failure := 0
		try Scope.Run((Fixture) => _CRWT_StartAndWait(Map(), Fixture, 0,
			_CWFC_Spawn.Bind(State), _CWFC_RefuseWait.Bind(State)))
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		if ThrowWait
			AssertEqual(ObjPtr(State.WaitError), ObjPtr(Failure), "cleanup must preserve the original error object")
		else
			AssertContains(Failure.Message, "integration deadline")
		AssertTrue(_CrashReportWorkerOwners.Has(OtherOwner["id"]))
		AssertFalse(OtherOwner["mapping"]["closed"])
		AssertEqual(0, OtherState.Control.Terminations, "unrelated owners must not receive cancellation")
		if !StopResult {
			AssertEqual(0, DeleteState.Calls, "unconfirmed exit must block even the deletion attempt")
			AssertEqual("retained fixture bytes", FileRead(Sentinel, "UTF-8"))
			AssertFalse(State.Owner["mapping"]["closed"])
			AssertTrue(_CRWF_PendingCleanup.Has(ObjPtr(Scope)))
			AssertContains(Failure.Message, "cleanup retained")
			State.Control.StopResult := true
			AssertTrue(_CRWF_DrainPending(), "only the retained fixture may be retried")
		}
		AssertTrue(Scope.Closed)
		AssertFalse(DirExist(Scope.Directory))
		AssertTrue(State.Owner["mapping"]["closed"])
		AssertFalse(_CrashReportWorkerOwners.Has(State.Owner["id"]))
		AssertFalse(_CRWF_PendingCleanup.Has(ObjPtr(Scope)))
		AssertEqual(1, DeleteState.Calls)
		AssertEqual(StopResult ? 1 : 2, State.Control.Terminations,
			"an acknowledged owned task must not receive duplicate direct termination")
		AssertEqual(0, OtherState.Control.Terminations)
	} finally {
		State.Control.StopResult := true
		try Scope.Finish()
		finally {
			if OtherOwner is Map
				AssertTrue(_CrashReportWorkerCancelOwner(OtherOwner))
		}
	}
}

for StopResult in [false, true] {
	for ThrowWait in [false, true]
		Test("crash worker fixture: stop=" . StopResult . " throw=" . ThrowWait
			. " preserves ownership (crash-worker-fixture-cleanup)",
			_CWFC_WaitFailureOwnership.Bind(StopResult, ThrowWait))
}

_CWFC_RefusedStartStillOwned() {
	Scope := _CRWF_Fixture("start_refusal")
	State := _CWFC_State(false, false)
	try {
		AssertEqual(0, Scope.Start("{}", (*) => 0, _CWFC_Spawn.Bind(State), A_ScriptFullPath))
		AssertEqual(1, State.Spawns)
		AssertEqual(1, Scope.Owners.Count, "Start=0 must not conceal the retained owner")
		AssertFalse(Scope.Cleanup())
		AssertTrue(DirExist(Scope.Directory))
		State.Control.StopResult := true
		AssertTrue(Scope.Cleanup())
		AssertFalse(DirExist(Scope.Directory))
	} finally {
		State.Control.StopResult := true
		Scope.Finish()
	}
}
Test("crash worker fixture: start zero retains exact ownership (crash-worker-fixture-cleanup)",
	_CWFC_RefusedStartStillOwned)

_CWFC_DuringSpawn(Scope, State, Executable, Args, Done) {
	State.CleanupResult := Scope.Cleanup()
	State.DirectorySurvived := !!DirExist(Scope.Directory)
	return _CWFC_Spawn(State, Executable, Args, Done)
}

_CWFC_SpawnInFlightBlocksDeletion() {
	Scope := _CRWF_Fixture("spawn_reentry")
	State := _CWFC_State()
	try {
		Scope.Start("{}", (*) => 0, _CWFC_DuringSpawn.Bind(Scope, State), A_ScriptFullPath)
		AssertFalse(State.CleanupResult)
		AssertTrue(State.DirectorySurvived)
		AssertEqual(1, Scope.Tasks.Count, "the returned task must be published before InFlight reaches zero")
		AssertEqual(0, Scope.InFlight)
		AssertTrue(Scope.Cleanup())
		AssertTrue(State.Task.Stopped)
		AssertFalse(DirExist(Scope.Directory))
	} finally Scope.Finish()
}
Test("crash worker fixture: in-flight creation blocks deletion (crash-worker-fixture-cleanup)",
	_CWFC_SpawnInFlightBlocksDeletion)

_CWFC_TerminationClosesAdmission() {
	Scope := _CRWF_Fixture("closing_admission")
	State := _CWFC_State()
	Nested := _CWFC_State()
	try {
		Scope.Start("{}", (*) => 0, _CWFC_Spawn.Bind(State), A_ScriptFullPath)
		State.Control.OnTerminate := () => Scope.Spawn(_CWFC_Spawn.Bind(Nested), "ignored", [], (*) => 0)
		AssertTrue(Scope.Cleanup())
		AssertEqual(0, Nested.Spawns, "termination callbacks must not admit another writer")
		AssertTrue(Scope.Closed)
	} finally {
		State.Control.OnTerminate := 0
		Scope.Finish()
	}
}
Test("crash worker fixture: termination closes spawn admission (crash-worker-fixture-cleanup)",
	_CWFC_TerminationClosesAdmission)

_CWFC_ExistingDirectoryIsNotAdopted() {
	Scope := _CRWF_Fixture("exclusive_directory")
	try {
		Path := Scope.Directory . "\sentinel.txt"
		FileAppend("existing owner", Path, "UTF-8-RAW")
		Failure := 0
		try _CRWF_CreateDirectory(Scope.Directory)
		catch as Err
			Failure := Err
		AssertTrue(Failure is OSError)
		AssertEqual("existing owner", FileRead(Path, "UTF-8"))
	} finally Scope.Finish()
}
Test("crash worker fixture: existing directories are not adopted (crash-worker-fixture-cleanup)",
	_CWFC_ExistingDirectoryIsNotAdopted)

_CWFC_DeletionRefusalRemainsPending() {
	DeleteState := {Calls: 0, Allow: false}
	Scope := _CRWF_Fixture("delete_refusal", _CWFC_Delete.Bind(DeleteState))
	try {
		AssertFalse(Scope.Cleanup())
		AssertFalse(Scope.Closed)
		AssertTrue(DirExist(Scope.Directory))
		DeleteState.Allow := true
		AssertTrue(Scope.Cleanup())
		AssertEqual(2, DeleteState.Calls)
		AssertFalse(DirExist(Scope.Directory))
	} finally {
		DeleteState.Allow := true
		Scope.Finish()
	}
}
Test("crash worker fixture: deletion refusal remains pending (crash-worker-fixture-cleanup)",
	_CWFC_DeletionRefusalRemainsPending)

_CWFC_RefuseNativeWait(State, Scope, Predicate, TimeoutMs) {
	global SRTOW_WAIT_TIMEOUT
	AssertEqual(1, Scope.Owners.Count)
	for _, Owner in Scope.Owners
		State.Owner := Owner
	Task := State.Owner["task"]
	Observer := _SRTOW_OpenExactProcess(Task.processId())
	AssertTrue(Observer != 0, "the fixture must have launched a real child")
	try {
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(Observer))
		State.ObservedAlive := true
	} finally {
		; A process observer itself delays empty-job accounting: release it before
		; the fixture asks the native tree owner to prove quiescence.
		AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Observer, "Int") != 0)
	}
	return false
}

_CWFC_NativeWaitFailureStopsWriter() {
	global _ConfigDir, _CRWT_TIMEOUT_MS, _CrashReportWorkerOwners
	Scope := _CRWF_Fixture("native_timeout")
	OldConfigDir := _ConfigDir
	State := {Owner: 0, ObservedAlive: false}
	Failure := 0
	try {
		_ConfigDir := Scope.Directory . "\"
		Snapshot := _CrashReport_CheapSnapshot(Error("native fixture timeout"))
		try Scope.Run((Fixture) => _CRWT_StartAndWait(Snapshot, Fixture,
			Map("delay_ms", _CRWT_TIMEOUT_MS), 0, _CWFC_RefuseNativeWait.Bind(State, Scope)))
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, "integration deadline")
		AssertTrue(State.ObservedAlive)
		AssertTrue(Scope.Closed, "the actual native tree must acknowledge exit before directory removal")
		AssertFalse(DirExist(Scope.Directory))
		AssertTrue(State.Owner["mapping"]["closed"])
		AssertFalse(_CrashReportWorkerOwners.Has(State.Owner["id"]))
	} finally {
		_ConfigDir := OldConfigDir
		Scope.Finish(Failure)
	}
}
Test("crash worker fixture: native wait failure stops its writer (crash-worker-fixture-cleanup)",
	_CWFC_NativeWaitFailureStopsWriter)
