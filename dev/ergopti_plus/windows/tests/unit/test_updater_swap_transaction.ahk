; tests/unit/test_updater_swap_transaction.ahk

; ==============================================================================
; MODULE: Updater Swap Transaction Behavior Tests
; DESCRIPTION:
; Exercises the generated PowerShell swapper through its real named-event and
; inherited exact-parent-HANDLE protocol. The fixtures prove both successful
; replacement and rollback after Current has already moved to .bak.
; ==============================================================================

#Requires AutoHotkey v2.0

global _USTX_TransactionCounter := 0
global USTX_WAIT_TIMEOUT_MS := 10000
global USTX_FIXTURE_SETTLE_MS := 1400
global USTX_PROCESS_TERMINATE := 0x0001

_USTX_WaitForEvent(Handle, TimeoutMs := unset) {
	global USTX_WAIT_TIMEOUT_MS
	if !IsSet(TimeoutMs)
		TimeoutMs := USTX_WAIT_TIMEOUT_MS
	StartedTick := A_TickCount
	while !TickExpired(StartedTick, TimeoutMs) {
		State := _Updater_WaitHandleState(Handle)
		if (State == 1)
			return true
		if (State < 0)
			return false
		Sleep(10)
	}
	return false
}

_USTX_WaitForProcessExit(Owner, TimeoutMs := unset) {
	global USTX_WAIT_TIMEOUT_MS
	if !IsSet(TimeoutMs)
		TimeoutMs := USTX_WAIT_TIMEOUT_MS
	return _USTX_WaitForEvent(Owner.Get("ProcessHandle", 0), TimeoutMs)
}

_USTX_GetExitCode(Owner) {
	ExitCode := 0xFFFFFFFF
	Handle := Owner.Get("ProcessHandle", 0)
	if !Handle
		return ExitCode
	try {
		if !DllCall("GetExitCodeProcess", "Ptr", Handle, "UInt*", &ExitCode, "Int")
			return 0xFFFFFFFF
	} catch {
		return 0xFFFFFFFF
	}
	return ExitCode
}

_USTX_WriteBatchFixture(Path, MarkerPath, Label) {
	Script := '@echo off' . "`r`n"
		. '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "$e=[Threading.EventWaitHandle]::OpenExisting($env:ERGOPTI_UPDATER_BOOT_READY);$null=$e.Set();$e.Dispose()"' . "`r`n"
		. 'echo ' . Label . '>"' . MarkerPath . '"' . "`r`n"
		. 'ping -n 2 127.0.0.1 >nul' . "`r`n"
	FileAppend(Script, Path, "UTF-8-RAW")
	return Script
}

_USTX_WriteParentGate(Path, ExitFlag) {
	Script := '@echo off' . "`r`n"
		. ':wait' . "`r`n"
		. 'if exist "' . ExitFlag . '" exit /b 0' . "`r`n"
		. 'ping -n 2 127.0.0.1 >nul' . "`r`n"
		. 'goto wait' . "`r`n"
	FileAppend(Script, Path, "UTF-8-RAW")
}

_USTX_RunSwapCase(NewExists, CurrentStartsAsBak := false) {
	global _USTX_TransactionCounter, USTX_FIXTURE_SETTLE_MS
	global UPDATER_SWAP_SYNCHRONIZE, USTX_PROCESS_TERMINATE
	TestId := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount
		. "_" . ++_USTX_TransactionCounter
	TestDir := A_Temp . "\ergopti_updater_swap_test_" . TestId
	CurrentExe := TestDir . "\current.cmd"
	NewExe := TestDir . "\new.cmd"
	BakExe := CurrentExe . ".bak"
	SwapScriptPath := TestDir . "\swap.ps1"
	ParentGatePath := TestDir . "\parent_gate.cmd"
	ParentExitFlag := TestDir . "\parent_exit.flag"
	OldMarker := TestDir . "\old.marker"
	NewMarker := TestDir . "\new.marker"
	Owner := 0
	ParentHandle := 0
	ParentCleanupHandle := 0
	ParentPid := 0
	DirCreate(TestDir)
	try {
		_USTX_WriteBatchFixture(CurrentExe, OldMarker, "OLD")
		if CurrentStartsAsBak
			FileMove(CurrentExe, BakExe)
		if NewExists
			_USTX_WriteBatchFixture(NewExe, NewMarker, "NEW")
		_USTX_WriteParentGate(ParentGatePath, ParentExitFlag)
		FileAppend(_Updater_BuildSwapWorkerScript(), SwapScriptPath, "UTF-8-RAW")

		Run(A_ComSpec . ' /d /c "' . ParentGatePath . '"', , "Hide", &ParentPid)
		Assert(ParentPid > 0 and ProcessExist(ParentPid),
			"positive control: the exact parent-gate process must be alive")
		; Keep a non-inheritable exact handle for failure cleanup. A PID can be
		; recycled after an unexpected parent exit, so ProcessClose(ParentPid)
		; would make the test capable of killing an unrelated process.
		ParentCleanupHandle := DllCall("OpenProcess", "UInt",
			UPDATER_SWAP_SYNCHRONIZE | USTX_PROCESS_TERMINATE,
			"Int", false, "UInt", ParentPid, "Ptr")
		Assert(ParentCleanupHandle != 0,
			"the behavior test must own an exact parent cleanup HANDLE")
		ParentHandle := DllCall("OpenProcess", "UInt", UPDATER_SWAP_SYNCHRONIZE,
			"Int", true, "UInt", ParentPid, "Ptr")
		Assert(ParentHandle != 0,
			"the behavior test must own an inheritable exact parent HANDLE")

		TransactionId := 1000000 + _USTX_TransactionCounter
		InheritedParentHandle := ParentHandle
		ParentHandle := 0
		Owner := _Updater_CreateSuspendedSwapOwner(
			SwapScriptPath, NewExe, CurrentExe, TransactionId,
			InheritedParentHandle)
		Assert(_Updater_ResumeSwapOwner(Owner),
			"the real PowerShell swap worker must resume from CREATE_SUSPENDED")
		Assert(_USTX_WaitForEvent(Owner.Get("ReadyHandle", 0)),
			"the real swap worker must signal Ready after opening every event and the parent handle")
		if CurrentStartsAsBak {
			Assert(!FileExist(CurrentExe),
				"Ready must not recreate an interrupted Current before authorization")
			AssertContains(FileRead(BakExe, "UTF-8-RAW"), "OLD",
				"Ready must retain the interrupted transaction's last known-good Bak")
		} else
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"Ready alone must not mutate the current executable")

		Assert(_Updater_SetSwapEvent(Owner.Get("CommitHandle", 0)),
			"the test must be able to authorize Commit")
		Assert(_USTX_WaitForEvent(Owner.Get("AckHandle", 0)),
			"the real swap worker must acknowledge Commit")
		if CurrentStartsAsBak {
			Assert(!FileExist(CurrentExe),
				"Commit and Ack must not recover Bak before FinalExit and exact-parent exit")
			AssertContains(FileRead(BakExe, "UTF-8-RAW"), "OLD",
				"Commit and Ack must preserve the interrupted Bak")
		} else
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"Commit and Ack must still leave the current executable untouched")

		Assert(_Updater_SetSwapEvent(Owner.Get("FinalExitHandle", 0)),
			"the test must be able to authorize FinalExit")
		Sleep(150)
		if CurrentStartsAsBak {
			Assert(!FileExist(CurrentExe),
				"FinalExit must not recover Bak while the exact parent HANDLE is alive")
			AssertContains(FileRead(BakExe, "UTF-8-RAW"), "OLD",
				"FinalExit must retain Bak while the exact parent is alive")
		} else
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"FinalExit must not mutate files while the exact parent HANDLE is alive")
		FileAppend("exit", ParentExitFlag, "UTF-8-RAW")
		Assert(_USTX_WaitForProcessExit(Owner),
			"the real swap worker must finish after the exact parent exits")
		ExitCode := _USTX_GetExitCode(Owner)

		if NewExists {
			AssertEqual(0, ExitCode,
				"a valid replacement must complete the real swap transaction")
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "NEW",
				"success must publish the replacement at Current")
			Assert(!FileExist(BakExe),
				"success may delete Bak only after the replacement survives probation")
			Assert(_USTX_WaitForFile(NewMarker),
				"success must relaunch the replacement fixture")
			Assert(!FileExist(OldMarker),
				"success must not relaunch the retired current fixture")
		} else {
			Assert(ExitCode != 0,
				"a missing New after Current-to-Bak must fail the swap transaction")
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"rollback must restore the old Current after New is missing")
			Assert(!FileExist(BakExe),
				"rollback must consume Bak when restoring Current")
			Assert(_USTX_WaitForFile(OldMarker),
				"rollback must explicitly relaunch the restored old fixture")
			Assert(!FileExist(NewMarker),
				"rollback must never launch a missing replacement")
		}
	} finally {
		if (Owner is Map)
			_Updater_CloseSwapOwner(Owner, true)
		if ParentHandle
			_Updater_CloseNativeSwapHandle(ParentHandle)
		if ParentCleanupHandle {
			if (_Updater_WaitHandleState(ParentCleanupHandle) == 0)
				try DllCall("TerminateProcess", "Ptr", ParentCleanupHandle,
					"UInt", 1, "Int")
			_Updater_CloseNativeSwapHandle(ParentCleanupHandle)
		}
		Sleep(USTX_FIXTURE_SETTLE_MS)
		try DirDelete(TestDir, true)
	}
}

_USTX_WaitForFile(Path, TimeoutMs := unset) {
	global USTX_WAIT_TIMEOUT_MS
	if !IsSet(TimeoutMs)
		TimeoutMs := USTX_WAIT_TIMEOUT_MS
	StartedTick := A_TickCount
	while !TickExpired(StartedTick, TimeoutMs) {
		if FileExist(Path)
			return true
		Sleep(10)
	}
	return false
}

_USTX_SuccessReplacesAndRelaunches() {
	_USTX_RunSwapCase(true)
}

Test("updater swap transaction: success waits for authorization and relaunches the replacement",
	_USTX_SuccessReplacesAndRelaunches)

_USTX_MissingNewRestoresAndRelaunchesOld() {
	_USTX_RunSwapCase(false)
}

Test("updater swap transaction: missing New after Current-to-Bak restores and relaunches old",
	_USTX_MissingNewRestoresAndRelaunchesOld)

_USTX_InterruptedCurrentBakIsAdoptedForRecovery() {
	_USTX_RunSwapCase(false, true)
}

Test("updater swap transaction: interrupted Bak without Current is restored and relaunched",
	_USTX_InterruptedCurrentBakIsAdoptedForRecovery)

_USTX_ParentExitBeforeFinalExitAbandonsWithoutMutation() {
	global _USTX_TransactionCounter, USTX_FIXTURE_SETTLE_MS
	global UPDATER_SWAP_SYNCHRONIZE, USTX_PROCESS_TERMINATE
	TestId := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount
		. "_crash_before_final_" . ++_USTX_TransactionCounter
	TestDir := A_Temp . "\ergopti_updater_swap_test_" . TestId
	CurrentExe := TestDir . "\current.cmd"
	NewExe := TestDir . "\new.cmd"
	SwapScriptPath := TestDir . "\swap.ps1"
	ParentGatePath := TestDir . "\parent_gate.cmd"
	ParentExitFlag := TestDir . "\parent_exit.flag"
	OldMarker := TestDir . "\old.marker"
	NewMarker := TestDir . "\new.marker"
	Owner := 0
	ParentHandle := 0
	ParentCleanupHandle := 0
	ParentPid := 0
	DirCreate(TestDir)
	try {
		_USTX_WriteBatchFixture(CurrentExe, OldMarker, "OLD")
		_USTX_WriteBatchFixture(NewExe, NewMarker, "NEW")
		_USTX_WriteParentGate(ParentGatePath, ParentExitFlag)
		FileAppend(_Updater_BuildSwapWorkerScript(), SwapScriptPath, "UTF-8-RAW")
		Run(A_ComSpec . ' /d /c "' . ParentGatePath . '"', , "Hide", &ParentPid)
		Assert(ParentPid > 0 and ProcessExist(ParentPid),
			"positive control: the crash-before-FinalExit parent must be alive")
		ParentCleanupHandle := DllCall("OpenProcess", "UInt",
			UPDATER_SWAP_SYNCHRONIZE | USTX_PROCESS_TERMINATE,
			"Int", false, "UInt", ParentPid, "Ptr")
		Assert(ParentCleanupHandle != 0,
			"the crash fixture must own an exact parent cleanup HANDLE")
		ParentHandle := DllCall("OpenProcess", "UInt", UPDATER_SWAP_SYNCHRONIZE,
			"Int", true, "UInt", ParentPid, "Ptr")
		Assert(ParentHandle != 0,
			"the crash fixture must own an inheritable exact parent HANDLE")
		InheritedParentHandle := ParentHandle
		ParentHandle := 0
		Owner := _Updater_CreateSuspendedSwapOwner(SwapScriptPath, NewExe,
			CurrentExe, 3000000 + _USTX_TransactionCounter,
			InheritedParentHandle)
		Assert(_Updater_ResumeSwapOwner(Owner),
			"the crash-before-FinalExit child must resume")
		Assert(_USTX_WaitForEvent(Owner.Get("ReadyHandle", 0)),
			"the child must reach Ready before the simulated parent crash")
		Assert(_Updater_SetSwapEvent(Owner.Get("CommitHandle", 0)),
			"the test must authorize Commit")
		Assert(_USTX_WaitForEvent(Owner.Get("AckHandle", 0)),
			"the child must Ack Commit before the simulated crash")

		; Simulate AHK dying while the final hotstring gate is still running:
		; parent exits, but FinalExit is deliberately never signaled.
		FileAppend("exit", ParentExitFlag, "UTF-8-RAW")
		Assert(_USTX_WaitForProcessExit(Owner),
			"parent exit before FinalExit must make the child abandon promptly")
		AssertEqual(21, _USTX_GetExitCode(Owner),
			"the exact-parent branch must win when FinalExit was never authorized")
		AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
			"a parent crash before FinalExit must not retire Current")
		AssertContains(FileRead(NewExe, "UTF-8-RAW"), "NEW",
			"a parent crash before FinalExit must not consume New")
		Assert(!FileExist(CurrentExe . ".bak")
			and !FileExist(OldMarker) and !FileExist(NewMarker),
			"the abandoned transaction must create no Bak and launch neither binary")
	} finally {
		if (Owner is Map)
			_Updater_CloseSwapOwner(Owner, true)
		if ParentHandle
			_Updater_CloseNativeSwapHandle(ParentHandle)
		if ParentCleanupHandle {
			if (_Updater_WaitHandleState(ParentCleanupHandle) == 0)
				try DllCall("TerminateProcess", "Ptr", ParentCleanupHandle,
					"UInt", 1, "Int")
			_Updater_CloseNativeSwapHandle(ParentCleanupHandle)
		}
		Sleep(USTX_FIXTURE_SETTLE_MS)
		try DirDelete(TestDir, true)
	}
}

Test("updater swap transaction: parent crash before FinalExit abandons without mutation",
	_USTX_ParentExitBeforeFinalExitAbandonsWithoutMutation)

_USTX_AbortReservationBeforePublish(State, TransactionId, Owner, ProcessId) {
	global UPDATER_SWAP_SYNCHRONIZE
	State.CallbackRan := true
	State.ObservationHandle := DllCall("OpenProcess", "UInt",
		UPDATER_SWAP_SYNCHRONIZE, "Int", false, "UInt", ProcessId, "Ptr")
	Current := _Updater_CurrentSwapOwner(TransactionId)
	State.ClaimedExact := Current is Map and Current == Owner
	State.CancelResult := _Updater_CancelSelfUpdateForSuspend()
	State.TerminatedInsideCallback := State.ObservationHandle
		and _USTX_WaitForEvent(State.ObservationHandle, 2000)
}

_USTX_CreateProcessCancellationCannotOrphanSuspendedChild() {
	global _USTX_TransactionCounter, USTX_FIXTURE_SETTLE_MS
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	global _UpdaterSelfUpdateEpoch
	SavedSwapOwner := _UpdaterSwapOwner
	SavedExitIntent := _UpdaterExitIntent
	SavedExitInvocation := _UpdaterExitInvocation
	SavedDownloadInProgress := _UpdaterDownloadInProgress
	SavedDownloadWorker := _UpdaterDownloadWorker
	SavedEpoch := _UpdaterSelfUpdateEpoch
	TestId := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount
		. "_reservation_" . ++_USTX_TransactionCounter
	TestDir := A_Temp . "\ergopti_updater_swap_test_" . TestId
	SwapScriptPath := TestDir . "\swap.ps1"
	TransactionId := 4000000 + _USTX_TransactionCounter
	State := { CallbackRan: false, ClaimedExact: false, CancelResult: false,
		TerminatedInsideCallback: false,
		ObservationHandle: 0, ErrorMessage: "" }
	DirCreate(TestDir)
	try {
		FileAppend(_Updater_BuildSwapWorkerScript(), SwapScriptPath, "UTF-8-RAW")
		_UpdaterSwapOwner := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		_UpdaterDownloadInProgress := true
		_UpdaterDownloadWorker := 0
		StagingEpoch := ++_UpdaterSelfUpdateEpoch
		Owner := _Updater_ReserveSwapOwner(TransactionId)
		Assert(Owner is Map,
			"the race fixture must reserve its Starting owner before CreateProcess")
		try _Updater_CreateSuspendedSwapOwner(
			SwapScriptPath, TestDir . "\new.exe", TestDir . "\current.exe",
			TransactionId, 0, Owner,
			_USTX_AbortReservationBeforePublish.Bind(State, TransactionId))
		catch as Err
			State.ErrorMessage := Err.Message
		Assert(State.CallbackRan and State.ClaimedExact,
			"the test seam must claim the exact Starting owner after CreateProcess and before handle publication")
		Assert(State.CancelResult,
			"the real suspend-entry cancellation seam must own the in-flight transaction")
		Assert(State.ObservationHandle != 0,
			"the test must retain an independent exact handle to the unpublished child")
		Assert(State.TerminatedInsideCallback,
			"OnExit must terminate the shared PROCESS_INFORMATION child before it can proceed")
		AssertContains(State.ErrorMessage, "reservation was canceled",
			"the creator must reject a reservation claimed while CreateProcess was in flight")
		Assert(_USTX_WaitForEvent(State.ObservationHandle),
			"a claimed Starting reservation must terminate the unpublished suspended child")
		Assert(!(_UpdaterSwapOwner is Map),
			"cancellation must leave no process-global owner behind")
		Assert(!_Updater_SelfUpdateEpochIsCurrent(StagingEpoch),
			"a queued READY callback from before Pause must stay stale after immediate Resume")
		Assert(!_Updater_CancelSelfUpdateForSuspend(),
			"a second rapid suspend transition must be an idempotent no-op")
	} finally {
		if State.ObservationHandle
			_Updater_CloseNativeSwapHandle(State.ObservationHandle)
		if (_UpdaterSwapOwner is Map
			and _UpdaterSwapOwner.Get("Id", 0) == TransactionId) {
			Claimed := _Updater_ClaimSwapOwner(TransactionId)
			_Updater_CloseSwapOwner(Claimed, true)
		}
		_UpdaterSwapOwner := SavedSwapOwner
		_UpdaterExitIntent := SavedExitIntent
		_UpdaterExitInvocation := SavedExitInvocation
		_UpdaterDownloadInProgress := SavedDownloadInProgress
		_UpdaterDownloadWorker := SavedDownloadWorker
		_UpdaterSelfUpdateEpoch := SavedEpoch
		Sleep(USTX_FIXTURE_SETTLE_MS)
		try DirDelete(TestDir, true)
	}
}

Test("updater swap transaction: canceled Starting owner kills unpublished child",
	_USTX_CreateProcessCancellationCannotOrphanSuspendedChild)

_USTX_OrdinaryQuitAfterAckTerminatesWithoutMutation() {
	global _USTX_TransactionCounter, USTX_FIXTURE_SETTLE_MS
	global UPDATER_SWAP_SYNCHRONIZE
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	SavedDownloadInProgress := _UpdaterDownloadInProgress
	SavedDownloadWorker := _UpdaterDownloadWorker
	SavedSwapOwner := _UpdaterSwapOwner
	SavedExitIntent := _UpdaterExitIntent
	SavedExitInvocation := _UpdaterExitInvocation
	TestId := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount
		. "_ordinary_" . ++_USTX_TransactionCounter
	TestDir := A_Temp . "\ergopti_updater_swap_test_" . TestId
	CurrentExe := TestDir . "\current.cmd"
	NewExe := TestDir . "\new.cmd"
	SwapScriptPath := TestDir . "\swap.ps1"
	OldMarker := TestDir . "\old.marker"
	NewMarker := TestDir . "\new.marker"
	Owner := 0
	ObservationHandle := 0
	DirCreate(TestDir)
	try {
		_USTX_WriteBatchFixture(CurrentExe, OldMarker, "OLD")
		_USTX_WriteBatchFixture(NewExe, NewMarker, "NEW")
		FileAppend(_Updater_BuildSwapWorkerScript(), SwapScriptPath, "UTF-8-RAW")
		TransactionId := 2000000 + _USTX_TransactionCounter
		Owner := _Updater_CreateSuspendedSwapOwner(SwapScriptPath, NewExe,
			CurrentExe, TransactionId)
		Assert(_Updater_ResumeSwapOwner(Owner),
			"the ordinary-exit fixture must resume its exact swap child")
		Assert(_USTX_WaitForEvent(Owner.Get("ReadyHandle", 0)),
			"positive control: the ordinary-exit fixture must reach Ready")
		Assert(_Updater_SetSwapEvent(Owner.Get("CommitHandle", 0)),
			"the fixture must authorize Commit before the ordinary exit race")
		Assert(_USTX_WaitForEvent(Owner.Get("AckHandle", 0)),
			"positive control: ordinary exit must land after Ack but before guarded ExitApp")
		ObservationHandle := DllCall("OpenProcess", "UInt", UPDATER_SWAP_SYNCHRONIZE,
			"Int", false, "UInt", Owner.Get("ProcessId", 0), "Ptr")
		Assert(ObservationHandle != 0,
			"the test needs an independent exact handle after owner cleanup")

		_UpdaterDownloadInProgress := true
		_UpdaterDownloadWorker := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		_UpdaterSwapOwner := Owner
		Assert(_Updater_PublishExitIntent(TransactionId, Owner),
			"the ordinary-exit race requires a persistent acknowledged intent")
		Assert(_Updater_SignalFinalExitForIntent()
			and _Updater_TransferExitIntentAfterShutdownGates(),
			"ordinary OnExit must remain a valid shutdown without inheriting updater authority")
		AssertEqual(0, _Updater_WaitHandleState(
			Owner.Get("FinalExitHandle", 0)),
			"Ack alone must not signal FinalExit during an ordinary user Quit")
		Assert(_UpdaterSwapOwner is Map,
			"Ack alone must leave the exact child owned for ordinary teardown")
		_Updater_AbortStagingOnExit()
		Assert(_USTX_WaitForEvent(ObservationHandle),
			"ordinary quit after Ack must terminate the exact native swap child")
		AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
			"ordinary quit after Ack must leave Current byte ownership untouched")
		AssertContains(FileRead(NewExe, "UTF-8-RAW"), "NEW",
			"ordinary quit after Ack must not consume the staged replacement")
		Assert(!FileExist(CurrentExe . ".bak")
			and !FileExist(OldMarker) and !FileExist(NewMarker),
			"ordinary exit must create no Bak and launch neither binary")
	} finally {
		if (Owner is Map)
			_Updater_CloseSwapOwner(Owner, true)
		if ObservationHandle
			_Updater_CloseNativeSwapHandle(ObservationHandle)
		_UpdaterDownloadInProgress := SavedDownloadInProgress
		_UpdaterDownloadWorker := SavedDownloadWorker
		_UpdaterSwapOwner := SavedSwapOwner
		_UpdaterExitIntent := SavedExitIntent
		_UpdaterExitInvocation := SavedExitInvocation
		Sleep(USTX_FIXTURE_SETTLE_MS)
		try DirDelete(TestDir, true)
	}
}

Test("updater swap transaction: ordinary quit after Ack kills child with zero mutation",
	_USTX_OrdinaryQuitAfterAckTerminatesWithoutMutation)

_USTX_LifecycleRecoveryRetriesWithoutBlocking() {
	global _UpdaterLifecycleRecoveryPending, _UpdaterLifecycleRecoveryNoticeShown
	global _UpdaterLifecycleRecoveryNoticeRequested
	global _UpdaterLifecycleRecoveryAttemptCount
	SavedPending := _UpdaterLifecycleRecoveryPending
	SavedNoticeShown := _UpdaterLifecycleRecoveryNoticeShown
	SavedNoticeRequested := _UpdaterLifecycleRecoveryNoticeRequested
	SavedAttemptCount := _UpdaterLifecycleRecoveryAttemptCount
	Events := []
	NotifyFn := (*) => Events.Push("notify")
	ArmRetryFn := (DelayMs) => Events.Push("arm:" . DelayMs)
	ReloadFn := (*) => (Events.Push("reload"), false)
	try {
		_UpdaterLifecycleRecoveryPending := true
		_UpdaterLifecycleRecoveryNoticeShown := false
		_UpdaterLifecycleRecoveryNoticeRequested := true
		_UpdaterLifecycleRecoveryAttemptCount := 0
		Assert(_Updater_AttemptLifecycleRecovery(
			NotifyFn, ArmRetryFn, ReloadFn),
			"a pending torn-down lifecycle must own the recovery attempt")
		AssertEqual("notify", Events[1],
			"the first recovery attempt must publish one nonblocking notice")
		AssertContains(Events[2], "arm:",
			"the next attempt must be armed before Reload can enter OnExit")
		AssertEqual("reload", Events[3],
			"Reload must run only after the retry owner is durable")
		Assert(_UpdaterLifecycleRecoveryPending,
			"a returned Reload must retain recovery ownership")

		Assert(_Updater_AttemptLifecycleRecovery(
			NotifyFn, ArmRetryFn, ReloadFn),
			"a refused Reload must remain retryable")
		AssertEqual(5, Events.Length,
			"later attempts must coalesce the notice and perform only arm plus reload")
		AssertContains(Events[4], "arm:",
			"the refused Reload must pre-arm another retry")
		AssertEqual("reload", Events[5],
			"the retry must reach Reload without a modal wait")
		Assert(_UpdaterLifecycleRecoveryPending,
			"no in-process return may claim that terminal teardown recovered")

		Events.Length := 0
		_UpdaterLifecycleRecoveryNoticeShown := false
		_UpdaterLifecycleRecoveryNoticeRequested := false
		_UpdaterLifecycleRecoveryAttemptCount := 0
		Assert(_Updater_AttemptLifecycleRecovery(
			NotifyFn, ArmRetryFn, ReloadFn),
			"ordinary terminal teardown must use the same durable recovery owner")
		AssertEqual(2, Events.Length,
			"ordinary Exit/Reload recovery must arm and reload without a false updater-error notice")
		AssertContains(Events[1], "arm:",
			"silent lifecycle recovery must still pre-arm its retry")
		AssertEqual("reload", Events[2],
			"silent lifecycle recovery must still replace the half-driver")
	} finally {
		_UpdaterLifecycleRecoveryPending := SavedPending
		_UpdaterLifecycleRecoveryNoticeShown := SavedNoticeShown
		_UpdaterLifecycleRecoveryNoticeRequested := SavedNoticeRequested
		_UpdaterLifecycleRecoveryAttemptCount := SavedAttemptCount
	}
}

Test("updater swap transaction: lifecycle recovery retries without modal half-driver",
	_USTX_LifecycleRecoveryRetriesWithoutBlocking)

_USTX_RecoveryDescriptorRequiresExactClaim() {
	global _USTX_TransactionCounter
	TestId := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount
		. "_claim_" . ++_USTX_TransactionCounter
	TestDir := A_Temp . "\ergopti_updater_swap_test_" . TestId
	Token := "0123456789abcdef0123456789abcdef"
	TargetPath := TestDir . "\Current.exe"
	RecoveryPath := TargetPath . "." . Token . ".recovery.exe"
	StagePath := TargetPath . "." . Token . ".republish.exe"
	ClaimPath := RecoveryPath . ".claim"
	DirCreate(TestDir)
	try {
		FileAppend("OLD-GOOD", RecoveryPath, "UTF-8-RAW")
		FileAppend("OLD-GOOD", StagePath, "UTF-8-RAW")
		Assert(!(_Updater_LoadRecoveryDescriptor(RecoveryPath) is Map),
			"a recovery-shaped filename alone must carry no repair authority")
		FileAppend(TargetPath . "`n" . TargetPath . ".wrong-stage.exe",
			ClaimPath, "UTF-8-RAW")
		Assert(!(_Updater_LoadRecoveryDescriptor(RecoveryPath) is Map),
			"a claim that redirects the publish stage must fail closed")
		FileDelete(ClaimPath)
		FileAppend(TargetPath . "`n" . StagePath, ClaimPath, "UTF-8-RAW")
		Descriptor := _Updater_LoadRecoveryDescriptor(RecoveryPath)
		Assert(Descriptor is Map
			and Descriptor["Target"] == TargetPath
			and Descriptor["Stage"] == StagePath,
			"the exact two-line capability must authorize only its derived sibling paths")
		FileAppend("CORRUPT", StagePath, "UTF-8-RAW")
		Assert(!(_Updater_LoadRecoveryDescriptor(RecoveryPath) is Map),
			"a changed stage length must revoke the capability before any hook starts")
	} finally {
		try DirDelete(TestDir, true)
	}
}

Test("updater recovery: stale or redirected artifact has no repair capability",
	_USTX_RecoveryDescriptorRequiresExactClaim)

_USTX_RecoveryPublishRetainsStageAcrossTargetLock() {
	global _USTX_TransactionCounter
	TestId := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount
		. "_lock_" . ++_USTX_TransactionCounter
	TestDir := A_Temp . "\ergopti_updater_swap_test_" . TestId
	TargetPath := TestDir . "\Current.exe"
	StagePath := TestDir . "\Current.republish.exe"
	LockHandle := 0
	DirCreate(TestDir)
	try {
		FileAppend("OLD-CURRENT", TargetPath, "UTF-8-RAW")
		FileAppend("KNOWN-GOOD-RECOVERY", StagePath, "UTF-8-RAW")
		ExpectedSize := FileGetSize(StagePath)
		LockHandle := DllCall("CreateFileW", "Str", TargetPath,
			"UInt", 0x80000000, "UInt", 0, "Ptr", 0, "UInt", 3,
			"UInt", 0x80, "Ptr", 0, "Ptr")
		Assert(LockHandle and LockHandle != -1,
			"positive control: the target must be held with FileShare.None")
		PublishFailed := false
		try _Updater_RepublishRecoveryExecutable(
			StagePath, TargetPath, ExpectedSize)
		catch
			PublishFailed := true
		Assert(PublishFailed,
			"MoveFileEx must report the live target lock instead of hiding it")
		Assert(FileExist(StagePath)
			and FileRead(StagePath, "UTF-8-RAW") == "KNOWN-GOOD-RECOVERY",
			"a failed atomic publish must retain the complete stage for a cheap retry")
		DllCall("CloseHandle", "Ptr", LockHandle)
		LockHandle := 0
		AssertEqual("OLD-CURRENT", FileRead(TargetPath, "UTF-8-RAW"),
			"a failed atomic publish must leave Current byte-for-byte untouched")
		Assert(_Updater_RepublishRecoveryExecutable(
			StagePath, TargetPath, ExpectedSize),
			"the same prebuilt stage must publish once the lock is released")
		Assert(!FileExist(StagePath)
			and FileRead(TargetPath, "UTF-8-RAW") == "KNOWN-GOOD-RECOVERY",
			"successful publication must atomically consume the stage into Current")
	} finally {
		if LockHandle and LockHandle != -1
			DllCall("CloseHandle", "Ptr", LockHandle)
		try DirDelete(TestDir, true)
	}
}

Test("updater recovery: target lock retains stage and retry publishes atomically",
	_USTX_RecoveryPublishRetainsStageAcrossTargetLock)

_USTX_SuspendPulseInvalidatesQueuedStagingCompletion() {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterSelfUpdateEpoch
	SavedDownloadInProgress := _UpdaterDownloadInProgress
	SavedDownloadWorker := _UpdaterDownloadWorker
	SavedSwapOwner := _UpdaterSwapOwner
	SavedExitIntent := _UpdaterExitIntent
	SavedExitInvocation := _UpdaterExitInvocation
	SavedEpoch := _UpdaterSelfUpdateEpoch
	State := { TerminateCount: 0 }
	Worker := {}
	Worker.terminate := (*) => State.TerminateCount += 1
	try {
		_UpdaterDownloadInProgress := true
		_UpdaterDownloadWorker := Worker
		_UpdaterSwapOwner := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		StagingEpoch := ++_UpdaterSelfUpdateEpoch
		Assert(_Updater_CancelSelfUpdateForSuspend(),
			"Pause must synchronously claim a staging transaction before any poll")
		Assert(!_Updater_CancelSelfUpdateForSuspend(),
			"an immediate Resume/Pause follow-up must not reclaim a retired owner")
		AssertEqual(1, State.TerminateCount,
			"the exact staging owner must be terminated once across a rapid pulse")
		Assert(!_Updater_SelfUpdateEpochIsCurrent(StagingEpoch),
			"the queued pre-Pause READY callback must remain stale after Resume")
		Assert(!_UpdaterDownloadInProgress and !IsObject(_UpdaterDownloadWorker),
			"suspend cancellation must release the transaction before returning")
	} finally {
		_UpdaterDownloadInProgress := SavedDownloadInProgress
		_UpdaterDownloadWorker := SavedDownloadWorker
		_UpdaterSwapOwner := SavedSwapOwner
		_UpdaterExitIntent := SavedExitIntent
		_UpdaterExitInvocation := SavedExitInvocation
		_UpdaterSelfUpdateEpoch := SavedEpoch
	}
}

Test("updater suspend: Pause-Resume pulse retires staging callback exactly once",
	_USTX_SuspendPulseInvalidatesQueuedStagingCompletion)

_USTX_TerminationRefusalRetainsExactSwapProcessHandle() {
	global _UpdaterSwapCleanupDebt, _UpdaterSwapCleanupDebtCounter
	global _UpdaterSwapCleanupRetryTimer, UPDATER_SWAP_SYNCHRONIZE
	global USTX_PROCESS_TERMINATE
	OldDebt := IsSet(_UpdaterSwapCleanupDebt)
		? _UpdaterSwapCleanupDebt : Map()
	OldCounter := IsSet(_UpdaterSwapCleanupDebtCounter)
		? _UpdaterSwapCleanupDebtCounter : 0
	OldTimer := IsSet(_UpdaterSwapCleanupRetryTimer)
		? _UpdaterSwapCleanupRetryTimer : 0
	_UpdaterSwapCleanupDebt := Map()
	_UpdaterSwapCleanupDebtCounter := 0
	_UpdaterSwapCleanupRetryTimer := (*) => 0
	ProcessHandle := 0
	CleanupHandle := 0
	ProcessId := 0
	try {
		PowerShell := A_WinDir
			. "\System32\WindowsPowerShell\v1.0\powershell.exe"
		Run('"' . PowerShell . '" -NoProfile -NonInteractive '
			. '-Command "Start-Sleep -Seconds 30"', , "Hide", &ProcessId)
		AssertEqual(ProcessId, ProcessWait(ProcessId, 2),
			"the exact swap-cleanup fixture process must be alive")
		CleanupHandle := DllCall("Kernel32\OpenProcess", "UInt",
			UPDATER_SWAP_SYNCHRONIZE | USTX_PROCESS_TERMINATE,
			"Int", false, "UInt", ProcessId, "Ptr")
		ProcessHandle := DllCall("Kernel32\OpenProcess", "UInt",
			UPDATER_SWAP_SYNCHRONIZE,
			"Int", false, "UInt", ProcessId, "Ptr")
		Assert(CleanupHandle && ProcessHandle,
			"the fixture must own both full-cleanup and synchronize-only handles")

		Owner := _Updater_NewSwapOwner(990001)
		Owner["ProcessHandle"] := ProcessHandle
		ProcessHandle := 0
		AssertFalse(_Updater_CloseSwapOwner(Owner, true),
			"denied termination must keep swap cleanup non-terminal")
		AssertEqual(0, Owner["ProcessHandle"],
			"the stale transaction owner must lose its recyclable numeric slot")
		AssertEqual(1, _UpdaterSwapCleanupDebt.Count,
			"process-owned debt must retain the exact denied handle")
		for _, Record in _UpdaterSwapCleanupDebt
			Assert(Record["handle"] != 0 && Record["terminate"],
				"retained process debt must preserve both capability and intent")
		AssertEqual(258, PLC_WaitHandle(CleanupHandle, 0),
			"termination through the synchronize-only handle must leave the child alive")

		Assert(DllCall("Kernel32\TerminateProcess", "Ptr", CleanupHandle,
			"UInt", 1, "Int"), "fixture cleanup must terminate the exact child")
		AssertEqual(0, PLC_WaitHandle(CleanupHandle, 5000))
		_UpdaterSwapCleanupRetryTimer := 0
		AssertTrue(_Updater_RetrySwapCleanupDebt(),
			"an exited child must make retained cleanup retryable")
		AssertEqual(0, _UpdaterSwapCleanupDebt.Count)
	} finally {
		if CleanupHandle {
			if PLC_WaitHandle(CleanupHandle, 0) != 0
				try DllCall("Kernel32\TerminateProcess", "Ptr", CleanupHandle,
					"UInt", 1, "Int")
			try PLC_WaitHandle(CleanupHandle, 5000)
		}
		for _, Record in _UpdaterSwapCleanupDebt {
			Handle := Record.Get("handle", 0)
			if Handle
				try PLC_CloseNativeHandle(Handle)
		}
		if HasMethod(_UpdaterSwapCleanupRetryTimer, "Call")
			SetTimer(_UpdaterSwapCleanupRetryTimer, 0)
		if ProcessHandle
			try PLC_CloseNativeHandle(ProcessHandle)
		if CleanupHandle
			try PLC_CloseNativeHandle(CleanupHandle)
		_UpdaterSwapCleanupDebt := OldDebt
		_UpdaterSwapCleanupDebtCounter := OldCounter
		_UpdaterSwapCleanupRetryTimer := OldTimer
	}
}

Test("updater swap cleanup: termination refusal retains exact process owner "
	. "(updater-swap-process-cleanup-debt)",
	_USTX_TerminationRefusalRetainsExactSwapProcessHandle)
