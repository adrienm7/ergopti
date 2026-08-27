; tests/unit/test_uia_selection_worker_deadline.ahk

; ==============================================================================
; MODULE: UIA Selection Worker Deadline Tests
; DESCRIPTION:
; Behavioral regression coverage for AHK-02. A fake worker deliberately never
; completes; the real controller must return without waiting, kill that worker
; at the 60 ms owner deadline and reject every late result. Context vectors also
; prove that HWND, focused-control HWND and physical-input generation are all
; required before a snapshot can be published.
; ==============================================================================

#Requires AutoHotkey v2.0+





; ===================================
; ===================================
; ======= 1/ Fake worker seam =======
; ===================================
; ===================================

global _UIASW_TestTerminateCount := 0
global _UIASW_TestTerminals := []
global _UIASW_TestSpawnCount := 0
global _UIASW_TestSpawnArgs := []

_UIASW_TestFakeHandle() {
	Handle := {}
	_Start(*) {
		return true
	}
	_Terminate(*) {
		global _UIASW_TestTerminateCount
		_UIASW_TestTerminateCount += 1
		return true
	}
	_ProcessId(*) {
		return 5151
	}
	Handle.start := _Start
	Handle.terminate := _Terminate
	Handle.terminateAsync := _Terminate
	Handle.processId := _ProcessId
	return Handle
}

_UIASW_TestPost(WorkerHwnd, RequestGeneration, MaxTextChars) {
	; Intentionally never completes: the real deadline owns this fake stall.
	return WorkerHwnd = 4242 && RequestGeneration > 0 && MaxTextChars > 0
}

_UIASW_TestSpawn(Executable, Args, Done, OnChunk?) {
	global _UIASW_TestSpawnCount, _UIASW_TestSpawnArgs
	_UIASW_TestSpawnCount += 1
	_UIASW_TestSpawnArgs := Args
	return _UIASW_TestFakeHandle()
}

_UIASW_TestOpenProcess(WorkerHwnd, ExpectedParentPid) {
	return WorkerHwnd && ExpectedParentPid = 5151 ? 9001 : 0
}

_UIASW_TestTerminateProcess(ProcessHandle) {
	global _UIASW_TestTerminateCount
	_UIASW_TestTerminateCount += 1
	return ProcessHandle = 9001
}

_UIASW_TestCloseProcess(ProcessHandle) {
	return ProcessHandle = 9001
}

_UIASW_TestTerminal(Status, Context, Result) {
	global _UIASW_TestTerminals
	_UIASW_TestTerminals.Push(Status)
}

_UIASW_TestQpcMs() {
	static Frequency := 0
	if !Frequency
		DllCall("QueryPerformanceFrequency", "Int64*", &Frequency)
	Counter := 0
	DllCall("QueryPerformanceCounter", "Int64*", &Counter)
	return Counter * 1000.0 / Frequency
}





; ========================================
; ========================================
; ======= 2/ Deadline behavior ==========
; ========================================
; ========================================

_UIASW_StalledWorkerCannotBlockDispatcher() {
	global _UIASW_TestTerminateCount, _UIASW_TestTerminals
	OldHandle := UIASWState.handle
	OldHwnd := UIASWState.worker_hwnd
	OldProcessHandle := UIASWState.worker_process_handle
	OldWorkerGeneration := UIASWState.worker_generation
	OldRequestGeneration := UIASWState.request_generation
	OldPending := UIASWState.pending
	OldPost := UIASWState.post_fn
	try {
		_UIASW_TestTerminateCount := 0
		_UIASW_TestTerminals := []
		UIASWState.handle := _UIASW_TestFakeHandle()
		UIASWState.worker_hwnd := 4242
		UIASWState.worker_process_handle := 0
		UIASWState.worker_generation := 73
		UIASWState.request_generation := 0
		UIASWState.pending := 0
		UIASWState.post_fn := _UIASW_TestPost
		Context := Map("Hwnd", 11, "Control", 22, "InputEpoch", 33, "ProcName", "stall.exe")

		Started := _UIASW_TestQpcMs()
		Assert(UIASW_Request(Context, _UIASW_TestTerminal),
			"the fake UIA worker request must be accepted")
		DispatchMs := _UIASW_TestQpcMs() - Started
		Assert(DispatchMs < 5.0,
			"posting a UIA request must return within 5 ms instead of executing COM on the keyboard thread (observed " . Round(DispatchMs, 3) . " ms)")

		Sleep(UIASW_DEADLINE_MS + 100)
		Assert(_UIASW_TestTerminateCount = 1,
			"the 60 ms deadline must terminate exactly one stalled worker process")
		Assert(_UIASW_TestTerminals.Length = 1 && _UIASW_TestTerminals[1] = "timeout",
			"a stalled request must receive exactly one timeout terminal")
		Assert(!IsObject(UIASWState.pending),
			"timeout must retire request ownership before terminating the worker")
		Assert(!UIASW_Complete(1, 73, "ok",
			Map("Status", "ok", "Hwnd", 11, "Control", 22, "Text", "late")),
			"a result arriving after timeout must be stale and unable to publish")
		Assert(_UIASW_TestTerminals.Length = 1,
			"a late result must not emit a second terminal")
	} finally {
		if IsObject(UIASWState.pending)
			UIASW_Stop("canceled")
		UIASWState.handle := OldHandle
		UIASWState.worker_hwnd := OldHwnd
		UIASWState.worker_process_handle := OldProcessHandle
		UIASWState.worker_generation := OldWorkerGeneration
		UIASWState.request_generation := OldRequestGeneration
		UIASWState.pending := OldPending
		UIASWState.post_fn := OldPost
	}
}

Test("UIA worker: a stalled provider is killed without blocking dispatch (uia-worker-deadline)",
	_UIASW_StalledWorkerCannotBlockDispatcher)

_UIASW_StartupDeadlineIsOwnedAndBackedOff() {
	global UIASW_START_DEADLINE_MS, UIASW_START_BACKOFF_MS
	global _UIASW_TestTerminateCount, _UIASW_TestSpawnCount, _UIASW_TestSpawnArgs
	OldHandle := UIASWState.handle
	OldHwnd := UIASWState.worker_hwnd
	OldProcessHandle := UIASWState.worker_process_handle
	OldWorkerGeneration := UIASWState.worker_generation
	OldPending := UIASWState.pending
	OldDeadlineFn := UIASWState.start_deadline_fn
	OldFailureTick := UIASWState.start_failure_tick
	OldStartDiagnostic := UIASWState.start_diagnostic
	OldSpawn := UIASWState.spawn_fn
	OldOpenProcess := UIASWState.open_process_fn
	OldTerminateProcess := UIASWState.terminate_process_fn
	OldCloseProcess := UIASWState.close_process_fn
	OldStartDeadlineMs := UIASW_START_DEADLINE_MS
	OldStartBackoffMs := UIASW_START_BACKOFF_MS
	try {
		UIASWState.handle := 0
		UIASWState.worker_hwnd := 0
		UIASWState.worker_process_handle := 0
		UIASWState.pending := 0
		UIASWState.start_deadline_fn := 0
		UIASWState.start_failure_tick := 0
		UIASWState.start_diagnostic := "test reset"
		UIASWState.spawn_fn := _UIASW_TestSpawn
		UIASWState.open_process_fn := _UIASW_TestOpenProcess
		UIASWState.terminate_process_fn := _UIASW_TestTerminateProcess
		UIASWState.close_process_fn := _UIASW_TestCloseProcess
		UIASW_START_DEADLINE_MS := 25
		UIASW_START_BACKOFF_MS := 1000
		_UIASW_TestTerminateCount := 0
		_UIASW_TestSpawnCount := 0
		_UIASW_TestSpawnArgs := []

		Assert(UIASW_Start(), "a fake UIA worker must enter its startup generation")
		Generation := UIASWState.worker_generation
		HasMinimalEntry := false
		for SpawnArg in _UIASW_TestSpawnArgs {
			if InStr(SpawnArg, "uia_selection_worker_entry.ahk") > 0 {
				HasMinimalEntry := true
				break
			}
		}
		Assert(_UIASW_TestSpawnCount = 1
			&& HasMinimalEntry,
			"source mode must launch the minimal worker entry instead of replaying the full driver")
		Assert(_UIASW_TestSpawnArgs.Length >= 2
			&& _UIASW_TestSpawnArgs[2] = "/ErrorStdOut",
			"source workers must route load/runtime failures to the captured subprocess stream instead of opening a hidden modal dialog")
		Assert(UIASW_WorkerSendReady(A_ScriptHwnd, Generation),
			"the fake worker must complete the same bounded WM_COPYDATA ready handshake as the real child")
		Assert(UIASW_IsReady(),
			"the WM_COPYDATA ready handler must claim the matching startup generation")
		Sleep(UIASW_START_DEADLINE_MS + 60)
		Assert(_UIASW_TestTerminateCount = 0 && UIASW_IsReady(),
			"readiness must cancel the startup deadline instead of killing a healthy worker")
		UIASW_Stop("canceled")

		_UIASW_TestTerminateCount := 0
		_UIASW_TestSpawnCount := 0
		Assert(UIASW_Start(), "a second fake worker must start for the timeout branch")
		Sleep(UIASW_START_DEADLINE_MS + 60)
		Assert(_UIASW_TestTerminateCount = 1 && !IsObject(UIASWState.handle),
			"a worker which never announces readiness must be terminated exactly once")
		Assert(UIASWState.start_failure_tick != 0,
			"startup timeout must publish a retry-backoff origin")
		Assert(!UIASW_Start() && _UIASW_TestSpawnCount = 1,
			"poll ticks inside the startup backoff must not create a process storm")
	} finally {
		UIASW_Stop("canceled")
		UIASWState.handle := OldHandle
		UIASWState.worker_hwnd := OldHwnd
		UIASWState.worker_process_handle := OldProcessHandle
		UIASWState.worker_generation := OldWorkerGeneration
		UIASWState.pending := OldPending
		UIASWState.start_deadline_fn := OldDeadlineFn
		UIASWState.start_failure_tick := OldFailureTick
		UIASWState.start_diagnostic := OldStartDiagnostic
		UIASWState.spawn_fn := OldSpawn
		UIASWState.open_process_fn := OldOpenProcess
		UIASWState.terminate_process_fn := OldTerminateProcess
		UIASWState.close_process_fn := OldCloseProcess
		UIASW_START_DEADLINE_MS := OldStartDeadlineMs
		UIASW_START_BACKOFF_MS := OldStartBackoffMs
	}
}

Test("UIA worker: cold startup is bounded, warmed and backoff-protected",
	_UIASW_StartupDeadlineIsOwnedAndBackedOff)

_UIASW_RealWorkerEntryStartsAndStops() {
	OldHandle := UIASWState.handle
	OldHwnd := UIASWState.worker_hwnd
	OldProcessHandle := UIASWState.worker_process_handle
	OldWorkerGeneration := UIASWState.worker_generation
	OldPending := UIASWState.pending
	OldDeadlineFn := UIASWState.start_deadline_fn
	OldFailureTick := UIASWState.start_failure_tick
	OldStartDiagnostic := UIASWState.start_diagnostic
	OldSpawn := UIASWState.spawn_fn
	OldOpenProcess := UIASWState.open_process_fn
	OldTerminateProcess := UIASWState.terminate_process_fn
	OldCloseProcess := UIASWState.close_process_fn
	WorkerPid := 0
	try {
		UIASWState.handle := 0
		UIASWState.worker_hwnd := 0
		UIASWState.worker_process_handle := 0
		UIASWState.pending := 0
		UIASWState.start_deadline_fn := 0
		UIASWState.start_failure_tick := 0
		UIASWState.start_diagnostic := "test reset"
		UIASWState.spawn_fn := 0
		UIASWState.open_process_fn := 0
		UIASWState.terminate_process_fn := 0
		UIASWState.close_process_fn := 0
		Assert(UIASW_Start(),
			"the production ShellRunner path must start the minimal UIA worker entry")
		StartedTick := A_TickCount
		while !UIASW_IsReady() && TickElapsed(StartedTick) < UIASW_START_DEADLINE_MS + 1000
			Sleep(10)
		Assert(UIASW_IsReady(),
			"the real worker must announce its hidden-window identity before the startup deadline (" . UIASWState.start_diagnostic . ")")
		DllCall("User32\GetWindowThreadProcessId", "Ptr", UIASWState.worker_hwnd,
			"UInt*", &WorkerPid, "UInt")
		Assert(WorkerPid > 0 && ProcessExist(WorkerPid),
			"the ready HWND must belong to a live disposable worker process")
		Assert(UIASW_Stop("canceled"),
			"the live worker must be claimed for asynchronous shutdown")
		StoppedTick := A_TickCount
		while ProcessExist(WorkerPid) && TickElapsed(StoppedTick) < 3000
			Sleep(10)
		Assert(!ProcessExist(WorkerPid),
			"asynchronous tree termination must actually reap the real UIA worker")
	} finally {
		UIASW_Stop("canceled")
		UIASWState.handle := OldHandle
		UIASWState.worker_hwnd := OldHwnd
		UIASWState.worker_process_handle := OldProcessHandle
		UIASWState.worker_generation := OldWorkerGeneration
		UIASWState.pending := OldPending
		UIASWState.start_deadline_fn := OldDeadlineFn
		UIASWState.start_failure_tick := OldFailureTick
		UIASWState.start_diagnostic := OldStartDiagnostic
		UIASWState.spawn_fn := OldSpawn
		UIASWState.open_process_fn := OldOpenProcess
		UIASWState.terminate_process_fn := OldTerminateProcess
		UIASWState.close_process_fn := OldCloseProcess
	}
}

Test("UIA worker process: minimal entry reaches ready and async stop reaps it",
	_UIASW_RealWorkerEntryStartsAndStops)





; ========================================
; ========================================
; ======= 3/ Context ownership ==========
; ========================================
; ========================================

_UIASW_ResultRequiresExactContext() {
	Expected := Map("Hwnd", 100, "Control", 200, "InputEpoch", 300, "ProcName", "editor.exe")
	Observed := Map("Hwnd", 100, "Control", 200)
	Live := Map("Hwnd", 100, "Control", 200, "InputEpoch", 300)
	Assert(UIASW_ContextMatches(Expected, Observed, Live),
		"an exact window/control/input-generation triple must remain publishable")

	for Vector in [
		Map("Hwnd", 101, "Control", 200, "InputEpoch", 300),
		Map("Hwnd", 100, "Control", 201, "InputEpoch", 300),
		Map("Hwnd", 100, "Control", 200, "InputEpoch", 301)
	] {
		Assert(!UIASW_ContextMatches(Expected, Observed, Vector),
			"a changed HWND, control or input generation must reject the worker result")
	}
	Observed["Control"] := 0
	Assert(!UIASW_ContextMatches(Expected, Observed, Live),
		"an unknown focused-control token must fail closed")
}

Test("UIA worker: snapshots are bound to window, control and input generation (uia-worker-context)",
	_UIASW_ResultRequiresExactContext)

_UIASW_AuditAhk009Snapshot(InputEpoch := 400) {
	return {
		Text: "secret",
		Hwnd: 100,
		Control: 200,
		InputEpoch: InputEpoch,
		CapturedAt: 300,
		Consumed: false
	}
}

_UIASW_SelectionConsumptionRejectsEveryPhysicalInvalidator() {
	for Invalidator in [
		"mouse-down", "Left", "Right", "Home", "End", "Backspace", "Delete",
		"Ctrl+X", "Ctrl+V", "Ctrl+Z"
	] {
		Snapshot := _UIASW_AuditAhk009Snapshot()
		AssertEqual("", UIASW_ConsumeSelectionSnapshot(
			Snapshot, 100, 200, 401, 10, 750),
			Invalidator . " must invalidate text captured in the previous input epoch")
		AssertFalse(Snapshot.Consumed,
			Invalidator . " must not consume or revive the stale capability")
	}
	for Fixture in [
		["foreground window", 101, 200, 401, 10],
		["focused control", 100, 201, 401, 10],
		["capture age", 100, 200, 401, 751]
	] {
		AssertEqual("", UIASW_ConsumeSelectionSnapshot(
			_UIASW_AuditAhk009Snapshot(401),
			Fixture[2], Fixture[3], Fixture[4], Fixture[5], 750),
			"a changed " . Fixture[1] . " must invalidate the selection capability")
	}

	Fresh := _UIASW_AuditAhk009Snapshot(401)
	AssertEqual("secret", UIASW_ConsumeSelectionSnapshot(
		Fresh, 100, 200, 401, 10, 750),
		"an exact current-epoch selection must remain consumable")
	AssertEqual("", UIASW_ConsumeSelectionSnapshot(
		Fresh, 100, 200, 401, 10, 750),
		"a fresh selection capability must remain one-shot")
}

Test("UIA selection: physical epoch invalidates cached caret provenance "
	. "(audit-ahk-009)",
	_UIASW_SelectionConsumptionRejectsEveryPhysicalInvalidator)
