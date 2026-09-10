; tests/unit/test_updater_swap_recovery.ahk

; ==============================================================================
; MODULE: Updater Recovery and Cleanup Ownership Tests
; DESCRIPTION: Preserves transaction ownership across interruption and recovery.
; ==============================================================================

#Requires AutoHotkey v2.0

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
