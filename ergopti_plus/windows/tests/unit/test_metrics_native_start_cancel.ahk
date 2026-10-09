; tests/unit/test_metrics_native_start_cancel.ahk

; ==============================================================================
; MODULE: Metrics Native Start Cancellation Tests
; DESCRIPTION: Recover scheduler ownership after canceling a real suspended worker.
; ==============================================================================

#Requires AutoHotkey v2.0

_MNSC_CancelDuringCreation(Range) {
	global _KLPF_CLEANUP_TIMER, _KLPF_CLEANUP_DEBTS
	Saved := [KLPFWorker.jobs, KLPFWorker.spawn_fn, KLPFWorker.generation,
		KLPFWorker.cleanup_schedule_fn, _KLPF_CLEANUP_TIMER, _KLPF_CLEANUP_DEBTS]
	_KLRDC_Reset()
	Handle := 0
	Observation := 0
	Timers := []
	Terminals := []
	StartingObserved := false
	CancelResult := true
	JobKey := Range ? "range:typing" : "typing"
	Root := _KLRDC_Root()
	Script := Root . "suspended_worker.ahk"
	Marker := Root . "resumed.txt"
	Schedule(Callback, Delay) {
		Timers.Push(Callback)
		return true
	}
	BeforeAdopt(State, Native) {
		StartingObserved := State["Starting"] && Native["Assigned"]
		Observation := _SRTOW_DuplicateNativeHandle(Native["ProcessHandle"])
		AssertTrue(Observation != 0)
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(Observation))
		AssertTrue(FSWriteCreateDurable(KLPFWorker.jobs[JobKey]["stage"], "synthetic stage") != 0)
		CancelResult := KLPF_CancelBuild(JobKey)
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(Observation),
			"the unconfirmed stop must precede finalization of the private process")
	}
	Spawn(Executable, Args, Done) {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut", Script, Marker], Done, 0, BeforeAdopt)
		return Handle
	}
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . "#Requires AutoHotkey v2.0`n"
			. 'FileAppend("resumed", A_Args[1], "UTF-8-RAW")' . "`nExitApp(0)`n") != 0)
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := Spawn
		KLPFWorker.cleanup_schedule_fn := Schedule
		_KLPF_CLEANUP_TIMER := 0
		_KLPF_CLEANUP_DEBTS := Map()
		Terminal := (Status, *) => Terminals.Push(Status)
		Started := Range
			? KLPF_RequestRange("typing", Root, Map("apps", [], "start_date", "2026-01-01",
				"end_date", "2026-01-01"), 91, Terminal)
			: KLPF_RequestBuild("typing", Root, "full", 91, Terminal)
		AssertTrue(StartingObserved, "cancellation must exercise native creation, not a fake handle")
		AssertFalse(CancelResult)
		AssertFalse(Started)
		AssertEqual(SRTOW_WAIT_OBJECT_0, _SRTOW_ExactProcessWait(Observation),
			"the interrupted start stack must finish the exact child before returning")
		AssertFalse(FSExists(Marker), "the suspended child must never execute its script")
		AssertEqual(0, Terminals.Length, "terminate suppresses the native completion callback")
		AssertTrue(KLPFWorker.jobs.Has(JobKey))
		Stage := KLPFWorker.jobs[JobKey]["stage"]
		AssertTrue(FSExists(Stage), "cleanup must retain the stage until its scheduler owner acknowledges termination")
		AssertEqual(1, Timers.Length, "the real STARTING refusal must arm automatic recovery")
		Timers[1].Call()
		AssertFalse(KLPFWorker.jobs.Has(JobKey))
		AssertFalse(FSExists(Stage))
		AssertEqual(1, Terminals.Length)
		AssertEqual("canceled", Terminals[1])
		AssertEqual(0, _KLPF_CLEANUP_TIMER)
		Timers[1].Call()
		AssertEqual(1, Terminals.Length, "a stale retry cannot deliver twice")
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "the fixture must confirm native teardown")
		if Observation
			AssertTrue(DllCall("CloseHandle", "Ptr", Observation, "Int"))
		KLPFWorker.jobs := Saved[1]
		KLPFWorker.spawn_fn := Saved[2]
		KLPFWorker.generation := Saved[3]
		KLPFWorker.cleanup_schedule_fn := Saved[4]
		_KLPF_CLEANUP_TIMER := Saved[5]
		_KLPF_CLEANUP_DEBTS := Saved[6]
		_KLRDC_Cleanup()
	}
}
for Range in [false, true]
	Test("Metrics native start: canceled worker releases scheduler range=" . Range . " (metrics-native-start-cancel)",
		_KLRDC_CheckTeardown.Bind(_MNSC_CancelDuringCreation.Bind(Range)))
