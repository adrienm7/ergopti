; tests/unit/test_uia_worker_cleanup_debt.ahk

; ==============================================================================
; MODULE: UIA Worker Cleanup Debt Tests
; DESCRIPTION: Native cleanup refusals retain exact ownership and block admission.
; ==============================================================================

#Requires AutoHotkey v2.0

_UIASW_RefusingTerminationHandle(State) {
	Handle := {}
	_Terminate(*) {
		State["attempts"] += 1
		return State["accept"]
	}
	Handle.terminateAsync := _Terminate
	return Handle
}

_UIASW_NoOpCleanupTimer(Callback, DelayMs) {
	return true
}

_UIASW_WithTerminationDebtIsolated(TestFn) {
	OldDebt := UIASWState.cleanup_debt
	OldDraining := UIASWState.cleanup_draining
	OldRetryArmed := UIASWState.cleanup_retry_armed
	OldTimerFn := UIASWState.cleanup_timer_fn
	UIASWState.cleanup_debt := []
	UIASWState.cleanup_draining := false
	UIASWState.cleanup_retry_armed := false
	UIASWState.cleanup_timer_fn := _UIASW_NoOpCleanupTimer
	try TestFn.Call()
	finally {
		UIASWState.cleanup_debt := OldDebt
		UIASWState.cleanup_draining := OldDraining
		UIASWState.cleanup_retry_armed := OldRetryArmed
		UIASWState.cleanup_timer_fn := OldTimerFn
	}
}

_UIASW_RefusedTerminationRemainsOwned() {
	State := Map("attempts", 0, "accept", false)
	Handle := _UIASW_RefusingTerminationHandle(State)
	AssertFalse(UIASW_TerminateWorker(Handle),
		"a refused termination request must not report terminal success")
	AssertEqual(1, UIASWState.cleanup_debt.Length,
		"the exact refused handle must remain reachable for retry")
	AssertEqual(1, State["attempts"])
	State["accept"] := true
	AssertTrue(UIASW_DrainTerminationDebt(),
		"a later accepted request must discharge the retained owner")
	AssertEqual(0, UIASWState.cleanup_debt.Length)
	AssertEqual(2, State["attempts"])
}

Test("UIA worker cleanup: refused termination remains exactly owned (uia-worker-termination-debt)",
	_UIASW_WithTerminationDebtIsolated.Bind(_UIASW_RefusedTerminationRemainsOwned))

_UIASW_DebtSpawn(Executable, Args, Done, OnChunk?) {
	global _UIASW_TestSpawnCount
	_UIASW_TestSpawnCount += 1
	return _UIASW_TestFakeHandle()
}

_UIASW_TerminationDebtBlocksReplacementAdmission() {
	global _UIASW_TestSpawnCount
	OldHandle := UIASWState.handle
	OldFailureTick := UIASWState.start_failure_tick
	OldSpawnFn := UIASWState.spawn_fn
	State := Map("attempts", 0, "accept", false)
	try {
		UIASWState.handle := 0
		UIASWState.start_failure_tick := 0
		UIASWState.spawn_fn := _UIASW_DebtSpawn
		_UIASW_TestSpawnCount := 0
		UIASW_QueueTerminationDebt(
			_UIASW_RefusingTerminationHandle(State), false)
		AssertFalse(UIASW_Start(),
			"new admission must fail while an older worker can still be alive")
		AssertEqual(0, _UIASW_TestSpawnCount,
			"the replacement process must not be created before debt is discharged")
		AssertEqual(1, UIASWState.cleanup_debt.Length)
	} finally {
		UIASWState.handle := OldHandle
		UIASWState.start_failure_tick := OldFailureTick
		UIASWState.spawn_fn := OldSpawnFn
	}
}

Test("UIA worker cleanup: debt blocks replacement admission (uia-worker-termination-debt)",
	_UIASW_WithTerminationDebtIsolated.Bind(
		_UIASW_TerminationDebtBlocksReplacementAdmission))

_UIASW_ShutdownRetriesTerminationDebt() {
	State := Map("attempts", 0, "accept", false)
	Handle := _UIASW_RefusingTerminationHandle(State)
	AssertFalse(UIASW_TerminateWorker(Handle))
	AssertFalse(UIASW_Stop("canceled"),
		"shutdown must refuse a false terminal result while cleanup is denied")
	AssertEqual(1, UIASWState.cleanup_debt.Length)
	State["accept"] := true
	AssertTrue(UIASW_Stop("canceled"),
		"shutdown must retry and discharge retained termination debt")
	AssertEqual(0, UIASWState.cleanup_debt.Length)
}

Test("UIA worker cleanup: shutdown retries exact termination debt (uia-worker-termination-debt)",
	_UIASW_WithTerminationDebtIsolated.Bind(_UIASW_ShutdownRetriesTerminationDebt))

global _UIASW_ProcessCloseDebtState := 0

_UIASW_ProcessCloseDebtTerminate(ProcessHandle) {
	return ProcessHandle = 9101
}

_UIASW_ProcessCloseDebtClose(ProcessHandle) {
	global _UIASW_ProcessCloseDebtState
	_UIASW_ProcessCloseDebtState["attempts"] += 1
	return _UIASW_ProcessCloseDebtState["accept"]
}

_UIASW_ProcessCloseFailureIsNotTerminal() {
	global _UIASW_ProcessCloseDebtState
	OldTerminateProcess := UIASWState.terminate_process_fn
	OldCloseProcess := UIASWState.close_process_fn
	OldProcessDebt := UIASWState.process_cleanup_debt
	OldProcessDraining := UIASWState.process_cleanup_draining
	OldRetryArmed := UIASWState.cleanup_retry_armed
	OldTimerFn := UIASWState.cleanup_timer_fn
	try {
		_UIASW_ProcessCloseDebtState := Map("attempts", 0, "accept", false)
		UIASWState.terminate_process_fn := _UIASW_ProcessCloseDebtTerminate
		UIASWState.close_process_fn := _UIASW_ProcessCloseDebtClose
		UIASWState.process_cleanup_debt := []
		UIASWState.process_cleanup_draining := false
		UIASWState.cleanup_retry_armed := false
		UIASWState.cleanup_timer_fn := _UIASW_NoOpCleanupTimer
		AssertFalse(UIASW_TerminateWorker(_UIASW_TestFakeHandle(), 9101),
			"a refused CloseHandle receipt must keep cleanup non-terminal")
		AssertEqual(1, UIASWState.process_cleanup_debt.Length,
			"the exact refused process handle must remain reachable for retry")
		AssertEqual(1, _UIASW_ProcessCloseDebtState["attempts"])
		_UIASW_ProcessCloseDebtState["accept"] := true
		AssertTrue(UIASW_DrainProcessCleanupDebt(),
			"a later accepted close must discharge retained kernel ownership")
		AssertEqual(0, UIASWState.process_cleanup_debt.Length)
		AssertEqual(2, _UIASW_ProcessCloseDebtState["attempts"])
	} finally {
		UIASWState.terminate_process_fn := OldTerminateProcess
		UIASWState.close_process_fn := OldCloseProcess
		UIASWState.process_cleanup_debt := OldProcessDebt
		UIASWState.process_cleanup_draining := OldProcessDraining
		UIASWState.cleanup_retry_armed := OldRetryArmed
		UIASWState.cleanup_timer_fn := OldTimerFn
	}
}

Test("UIA worker cleanup: refused process close is not terminal "
	. "(uia-worker-process-close-debt)",
	_UIASW_ProcessCloseFailureIsNotTerminal)

global _UIASW_RejectedOpenCloseState := 0

_UIASW_RejectedOpenClose(ProcessHandle) {
	global _UIASW_RejectedOpenCloseState
	_UIASW_RejectedOpenCloseState["attempts"] += 1
	if !_UIASW_RejectedOpenCloseState["accept"]
		return false
	return UIAW_CloseProcessHandle(ProcessHandle)
}

_UIASW_RejectedWorkerOpenRetainsProcessCloseDebt() {
	global _UIASW_RejectedOpenCloseState
	OldOpenProcess := UIASWState.open_process_fn
	OldCloseProcess := UIASWState.close_process_fn
	OldProcessDebt := UIASWState.process_cleanup_debt
	OldProcessDraining := UIASWState.process_cleanup_draining
	OldRetryArmed := UIASWState.cleanup_retry_armed
	OldTimerFn := UIASWState.cleanup_timer_fn
	try {
		_UIASW_RejectedOpenCloseState := Map("attempts", 0, "accept", false)
		UIASWState.open_process_fn := 0
		UIASWState.close_process_fn := _UIASW_RejectedOpenClose
		UIASWState.process_cleanup_debt := []
		UIASWState.process_cleanup_draining := false
		UIASWState.cleanup_retry_armed := false
		UIASWState.cleanup_timer_fn := _UIASW_NoOpCleanupTimer
		ProcessId := DllCall("Kernel32\GetCurrentProcessId", "UInt")

		AssertEqual(0, UIASW_OpenWorkerProcess(A_ScriptHwnd, ProcessId),
			"a process cannot verify itself as its own parent")
		AssertEqual(1, _UIASW_RejectedOpenCloseState["attempts"],
			"the rejected native handle must use the resident cleanup owner")
		AssertEqual(1, UIASWState.process_cleanup_debt.Length,
			"a refused close after parent rejection must retain the exact handle")
		AssertEqual(0, UIASW_OpenWorkerProcess(A_ScriptHwnd, ProcessId),
			"retained rejection debt must block another native handle admission")
		AssertEqual(1, _UIASW_RejectedOpenCloseState["attempts"],
			"the retry timer must remain the sole owner of rejected close debt")
		AssertEqual(1, UIASWState.process_cleanup_debt.Length,
			"a repeated ready handshake must not accumulate native handles")
		_UIASW_RejectedOpenCloseState["accept"] := true
		AssertTrue(UIASW_DrainProcessCleanupDebt())
		AssertEqual(0, UIASWState.process_cleanup_debt.Length)
	} finally {
		if IsObject(_UIASW_RejectedOpenCloseState) {
			_UIASW_RejectedOpenCloseState["accept"] := true
			try UIASW_DrainProcessCleanupDebt()
		}
		UIASWState.open_process_fn := OldOpenProcess
		UIASWState.close_process_fn := OldCloseProcess
		UIASWState.process_cleanup_debt := OldProcessDebt
		UIASWState.process_cleanup_draining := OldProcessDraining
		UIASWState.cleanup_retry_armed := OldRetryArmed
		UIASWState.cleanup_timer_fn := OldTimerFn
	}
}

Test("UIA worker cleanup: rejected open retains process-close debt "
	. "(uia-worker-rejected-open-close-debt)",
	_UIASW_RejectedWorkerOpenRetainsProcessCloseDebt)

global _UIASW_TerminationDrainRaceState := 0

_UIASW_ReentrantTerminationHandle() {
	Handle := {}
	_Terminate(*) {
		global _UIASW_TerminationDrainRaceState
		_UIASW_TerminationDrainRaceState["attempts"] += 1
		if !_UIASW_TerminationDrainRaceState["reentered"] {
			_UIASW_TerminationDrainRaceState["reentered"] := true
			_UIASW_TerminationDrainRaceState["nested_result"] :=
				UIASW_DrainTerminationDebt()
		}
		return true
	}
	Handle.terminateAsync := _Terminate
	return Handle
}

_UIASW_TerminationDebtStaysVisibleDuringRetry() {
	global _UIASW_TerminationDrainRaceState
	_UIASW_TerminationDrainRaceState := Map(
		"attempts", 0, "reentered", false, "nested_result", "unset")
	UIASW_QueueTerminationDebt(_UIASW_ReentrantTerminationHandle(), false)
	AssertTrue(UIASW_DrainTerminationDebt(),
		"the outer accepted termination must discharge its exact owner")
	AssertFalse(_UIASW_TerminationDrainRaceState["nested_result"],
		"a reentrant drainer must observe the in-flight termination owner")
	AssertEqual(1, _UIASW_TerminationDrainRaceState["attempts"],
		"the same owner must not receive overlapping termination calls")
	AssertEqual(0, UIASWState.cleanup_debt.Length)
}

Test("UIA worker cleanup: termination debt stays visible during retry "
	. "(uia-worker-termination-drain-race)",
	_UIASW_WithTerminationDebtIsolated.Bind(
		_UIASW_TerminationDebtStaysVisibleDuringRetry))

global _UIASW_InitialTerminationRaceState := 0

_UIASW_InitialTerminationRaceHandle() {
	Handle := {}
	_Terminate(*) {
		global _UIASW_InitialTerminationRaceState
		_UIASW_InitialTerminationRaceState["attempts"] += 1
		_UIASW_InitialTerminationRaceState["nested_result"] :=
			UIASW_DrainTerminationDebt()
		return true
	}
	Handle.terminateAsync := _Terminate
	return Handle
}

_UIASW_InitialTerminationPublishesOwnerBeforeNativeCall() {
	global _UIASW_InitialTerminationRaceState
	_UIASW_InitialTerminationRaceState := Map(
		"attempts", 0, "nested_result", "unset")
	AssertTrue(UIASW_TerminateWorker(_UIASW_InitialTerminationRaceHandle()),
		"the accepted initial termination must complete")
	AssertFalse(_UIASW_InitialTerminationRaceState["nested_result"],
		"the initial native call must publish its owner before invoking the seam")
	AssertEqual(1, _UIASW_InitialTerminationRaceState["attempts"])
	AssertEqual(0, UIASWState.cleanup_debt.Length)
}

Test("UIA worker cleanup: initial termination publishes ownership first "
	. "(uia-worker-initial-termination-race)",
	_UIASW_WithTerminationDebtIsolated.Bind(
		_UIASW_InitialTerminationPublishesOwnerBeforeNativeCall))

global _UIASW_ProcessRetryRearmState := 0

_UIASW_ProcessRetryRearmClose(ProcessHandle) {
	global _UIASW_ProcessRetryRearmState
	_UIASW_ProcessRetryRearmState["close_attempts"] += 1
	return false
}

_UIASW_ProcessRetryRearmTimer(Callback, DelayMs) {
	global _UIASW_ProcessRetryRearmState
	_UIASW_ProcessRetryRearmState["timer_arms"] += 1
	return true
}

_UIASW_ProcessCleanupRetryRearmsAfterRepeatedRefusal() {
	global _UIASW_ProcessRetryRearmState
	OldDebt := UIASWState.cleanup_debt
	OldDraining := UIASWState.cleanup_draining
	OldProcessDebt := UIASWState.process_cleanup_debt
	OldProcessDraining := UIASWState.process_cleanup_draining
	OldRetryArmed := UIASWState.cleanup_retry_armed
	OldTimerFn := UIASWState.cleanup_timer_fn
	OldCloseProcess := UIASWState.close_process_fn
	try {
		_UIASW_ProcessRetryRearmState := Map(
			"close_attempts", 0, "timer_arms", 0)
		UIASWState.cleanup_debt := []
		UIASWState.cleanup_draining := false
		UIASWState.process_cleanup_debt := [9201]
		UIASWState.process_cleanup_draining := false
		; Model the callback of the one-shot timer which is currently firing.
		UIASWState.cleanup_retry_armed := true
		UIASWState.cleanup_timer_fn := _UIASW_ProcessRetryRearmTimer
		UIASWState.close_process_fn := _UIASW_ProcessRetryRearmClose

		AssertFalse(UIASW_RetryTerminationDebt(),
			"the repeated close refusal must remain non-terminal")
		AssertEqual(1, _UIASW_ProcessRetryRearmState["close_attempts"])
		AssertEqual(1, _UIASW_ProcessRetryRearmState["timer_arms"],
			"a consumed one-shot timer must be rearmed after another refusal")
		AssertTrue(UIASWState.cleanup_retry_armed)
	} finally {
		UIASWState.cleanup_debt := OldDebt
		UIASWState.cleanup_draining := OldDraining
		UIASWState.process_cleanup_debt := OldProcessDebt
		UIASWState.process_cleanup_draining := OldProcessDraining
		UIASWState.cleanup_retry_armed := OldRetryArmed
		UIASWState.cleanup_timer_fn := OldTimerFn
		UIASWState.close_process_fn := OldCloseProcess
	}
}

Test("UIA worker cleanup: repeated process-close refusal rearms retry "
	. "(uia-worker-process-retry-rearm)",
	_UIASW_ProcessCleanupRetryRearmsAfterRepeatedRefusal)
