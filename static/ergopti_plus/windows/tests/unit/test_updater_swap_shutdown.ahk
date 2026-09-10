; tests/unit/test_updater_swap_shutdown.ahk

; ==============================================================================
; MODULE: Native Updater Shutdown Tests
; DESCRIPTION: Preserves transaction ownership across interruption and recovery.
; ==============================================================================

#Requires AutoHotkey v2.0

_USTX_OrdinaryQuitAfterAckTerminatesWithoutMutation(BeforeCleanup := 0) {
	global _USTX_TransactionCounter
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
	Failure := 0
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
		if BeforeCleanup
			BeforeCleanup.Call(TestDir)
	} catch as Err {
		Failure := Err
		throw Err
	} finally {
		try {
			try {
				if (Owner is Map)
					Assert(_Updater_CloseSwapOwner(Owner, true), "fixture cleanup must release its exact swap owner")
				; FinalExit was never authorized, so the exited worker cannot have
				; launched a replacement descendant. No fixed settle delay is needed.
				if ObservationHandle
					Assert(_USTX_WaitForEvent(ObservationHandle), "fixture cleanup must confirm exact worker exit")
			} finally {
				if ObservationHandle
					Assert(_Updater_CloseNativeSwapHandle(ObservationHandle))
			}
			try DirDelete(TestDir, true)
			catch as CleanupErr
				throw Error("Ordinary-exit fixture directory cleanup failed: " . CleanupErr.Message)
			Assert(!DirExist(TestDir), "successful cleanup must remove the owned fixture")
		} catch as CleanupErr {
			if Failure is Error
				Failure.Message .= "`nFixture cleanup failed: " . CleanupErr.Message
			else
				throw CleanupErr
		} finally {
			_UpdaterDownloadInProgress := SavedDownloadInProgress
			_UpdaterDownloadWorker := SavedDownloadWorker
			_UpdaterSwapOwner := SavedSwapOwner
			_UpdaterExitIntent := SavedExitIntent
			_UpdaterExitInvocation := SavedExitInvocation
		}
	}
}

Test("updater swap transaction: ordinary quit after Ack kills child with zero mutation",
	_USTX_OrdinaryQuitAfterAckTerminatesWithoutMutation)

_USTX_OrdinaryCleanupFailureIsNotGreen() {
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	Saved := [_UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation,
		_UpdaterDownloadInProgress, _UpdaterDownloadWorker]
	State := { Handle: 0, TestDir: "" }
	Failure := 0
	try {
		try _USTX_OrdinaryQuitAfterAckTerminatesWithoutMutation(
			_USTX_LockCanceledFixtureForCleanup.Bind(State))
		catch as Err
			Failure := Err
		Assert(State.Handle and State.Handle != -1, "the completed transaction must reach the cleanup lock")
		Assert(Failure is Error, "ordinary-exit fixture cleanup failure must not report success")
		AssertContains(Failure.Message, "Ordinary-exit fixture directory cleanup failed:")
		Assert(_UpdaterSwapOwner == Saved[1] and _UpdaterExitIntent == Saved[2]
			and _UpdaterExitInvocation == Saved[3] and _UpdaterDownloadInProgress == Saved[4]
			and _UpdaterDownloadWorker == Saved[5], "cleanup failure must preserve restored updater globals")
		Assert(DirExist(State.TestDir), "the refused cleanup must retain its exact fixture for diagnosis")
	} finally {
		if State.Handle and State.Handle != -1
			Assert(DllCall("CloseHandle", "Ptr", State.Handle, "Int"))
		if State.TestDir != "" and DirExist(State.TestDir)
			DirDelete(State.TestDir, true)
	}
}
Test("updater fixture: ordinary quit cleanup failure is not green (updater-ordinary-cleanup)",
	_USTX_OrdinaryCleanupFailureIsNotGreen)
