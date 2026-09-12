; tests/unit/test_updater_swap_cancellation.ahk

; ==============================================================================
; MODULE: Native Updater Cancellation Tests
; DESCRIPTION: Preserves transaction ownership across interruption and recovery.
; ==============================================================================

#Requires AutoHotkey v2.0

_USTX_ParentExitBeforeFinalExitAbandonsWithoutMutation(BeforeCleanup := 0) {
	global _USTX_TransactionCounter, USTX_FIXTURE_SETTLE_MS
	global UPDATER_SWAP_SYNCHRONIZE, USTX_PROCESS_TERMINATE
	Failure := 0
	ProcessesExited := false
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
		ProcessesExited := _USTX_WaitForEvent(Owner.Get("ProcessHandle", 0), 0)
			and _USTX_WaitForEvent(ParentCleanupHandle, 0)
		Assert(ProcessesExited, "both exact process handles must prove termination before cleanup")
		if BeforeCleanup
			BeforeCleanup.Call(TestDir)
	} catch as Err {
		Failure := Err
		throw Err
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
		; The proven abandoned path launches no replacement to outlive these
		; handles. Earlier failures retain the existing defensive settle period.
		if !ProcessesExited
			Sleep(USTX_FIXTURE_SETTLE_MS)
		_USTX_DeleteFixtureAfterCase(TestDir, Failure)
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

_USTX_CreateProcessCancellationCannotOrphanSuspendedChild(BeforeCleanupFn := unset) {
	global _USTX_TransactionCounter
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
	Failure := 0
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
		if IsSet(BeforeCleanupFn)
			BeforeCleanupFn.Call(TestDir)
	} catch as Err {
		Failure := Err
		throw Err
	} finally {
		try {
			try {
				if (_UpdaterSwapOwner is Map
					and _UpdaterSwapOwner.Get("Id", 0) == TransactionId) {
					Claimed := _Updater_ClaimSwapOwner(TransactionId)
					Assert(_Updater_CloseSwapOwner(Claimed, true),
						"fixture cleanup must release its exact canceled owner")
				}
				; This child never resumes, so exact process exit also proves there
				; are no fixture descendants to outlive it. A fixed sleep proves neither.
				if State.ObservationHandle
					Assert(_USTX_WaitForEvent(State.ObservationHandle),
						"fixture cleanup must confirm the unpublished child's exit")
			} finally {
				if State.ObservationHandle
					Assert(_Updater_CloseNativeSwapHandle(State.ObservationHandle),
						"fixture cleanup must release the exact observation handle")
			}
			try DirDelete(TestDir, true)
			catch as CleanupErr
				throw Error("Canceled fixture directory cleanup failed: " . CleanupErr.Message)
			Assert(!DirExist(TestDir),
				"successful fixture cleanup must remove its owned directory")
		} catch as CleanupErr {
			if Failure is Error
				Failure.Message .= "`nFixture cleanup failed: " . CleanupErr.Message
			else
				throw CleanupErr
		} finally {
			_UpdaterSwapOwner := SavedSwapOwner
			_UpdaterExitIntent := SavedExitIntent
			_UpdaterExitInvocation := SavedExitInvocation
			_UpdaterDownloadInProgress := SavedDownloadInProgress
			_UpdaterDownloadWorker := SavedDownloadWorker
			_UpdaterSelfUpdateEpoch := SavedEpoch
		}
	}
}

Test("updater swap transaction: canceled Starting owner kills unpublished child",
	_USTX_CreateProcessCancellationCannotOrphanSuspendedChild)

_USTX_LockCanceledFixtureForCleanup(State, TestDir) {
	State.TestDir := TestDir
	State.Handle := DllCall("CreateFileW", "Str", TestDir . "\swap.ps1",
		"UInt", 0x80000000, "UInt", 1, "Ptr", 0, "UInt", 3,
		"UInt", 0x80, "Ptr", 0, "Ptr")
	Assert(State.Handle and State.Handle != -1,
		"positive control: the canceled fixture file must deny delete sharing")
}

_USTX_CanceledFixtureCleanupFailureIsNotGreen() {
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterSelfUpdateEpoch
	SavedSwapOwner := _UpdaterSwapOwner
	SavedExitIntent := _UpdaterExitIntent
	SavedExitInvocation := _UpdaterExitInvocation
	SavedDownloadInProgress := _UpdaterDownloadInProgress
	SavedDownloadWorker := _UpdaterDownloadWorker
	SavedEpoch := _UpdaterSelfUpdateEpoch
	State := { Handle: 0, TestDir: "" }
	Failure := 0
	try {
		try _USTX_CreateProcessCancellationCannotOrphanSuspendedChild(
			_USTX_LockCanceledFixtureForCleanup.Bind(State))
		catch as Err
			Failure := Err
		Assert(State.Handle and State.Handle != -1,
			"the transaction must reach its controlled cleanup lock")
		Assert(Failure is Error,
			"a canceled fixture must not report success when directory cleanup fails")
		AssertContains(Failure.Message, "Canceled fixture directory cleanup failed:",
			"the refusal must originate from directory cleanup, not transaction setup")
		Assert(_UpdaterSwapOwner == SavedSwapOwner
			and _UpdaterExitIntent == SavedExitIntent
			and _UpdaterExitInvocation == SavedExitInvocation
			and _UpdaterDownloadInProgress == SavedDownloadInProgress
			and _UpdaterDownloadWorker == SavedDownloadWorker
			and _UpdaterSelfUpdateEpoch == SavedEpoch,
			"cleanup refusal must still restore every saved updater global")
		Assert(DirExist(State.TestDir),
			"the refused cleanup must retain the exact fixture directory for diagnosis")
	} finally {
		if State.Handle and State.Handle != -1
			Assert(DllCall("CloseHandle", "Ptr", State.Handle, "Int"),
				"the test must release its exact file lock")
		if State.TestDir != "" and DirExist(State.TestDir)
			DirDelete(State.TestDir, true)
	}
}

Test("updater fixture: canceled child cleanup failure is not green (updater-canceled-cleanup)",
	_USTX_CanceledFixtureCleanupFailureIsNotGreen)
