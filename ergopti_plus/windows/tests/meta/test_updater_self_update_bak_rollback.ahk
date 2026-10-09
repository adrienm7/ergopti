; tests/meta/test_updater_self_update_bak_rollback.ahk

; ==============================================================================
; MODULE: Updater Self-Update Bak Rollback Meta Test
; DESCRIPTION:
; Guards the generated PowerShell transaction that replaces the executable.
; New and old-good candidates must be completed off-path before one atomic
; Replace publishes Current. Fallbacks survive until the replacement signals
; the post-_DriverReady event and passes probation. Rollback terminates by exact
; process handle and restores from an independent old-good stage, not Bak alone.
; ==============================================================================

#Requires AutoHotkey v2.0


_USBR_SwapScript() {
	Body := _DriverFuncBody("_Updater_BuildSwapWorkerScript")
	Assert(Body != "", "_Updater_BuildSwapWorkerScript must exist")
	Script := _Updater_BuildSwapWorkerScript()
	Assert(Script != "", "the generated swap worker must not be empty")
	return Script
}

_USBR_CheckPowerShellTransactionOrder() {
	Script := _USBR_SwapScript()
	CandidatePos := InStr(Script, 'PublishCopy $NewExe $Candidate')
	RecoveryPos := InStr(Script, 'PublishCopy $OldSource $RecoveryPath', , CandidatePos)
	StagePos := InStr(Script, 'PublishCopy $OldSource $RecoveryStage', , RecoveryPos)
	ClaimPos := InStr(Script, 'WriteClaim $RecoveryClaim', , StagePos)
	ReplacePos := InStr(Script,
		'[IO.File]::Replace($Candidate,$CurrentExe,$B,$true)', , ClaimPos)
	StartReadyPos := InStr(Script,
		'$Child=StartReady $CurrentExe', , ReplacePos)
	ReadyWaitPos := InStr(Script, '$Event.WaitOne($TimeoutMs)')
	ProbationPos := InStr(Script,
		'Start-Sleep -Milliseconds $Probation', , ReadyWaitPos)
	ClaimCleanupPos := InStr(Script,
		'RemoveBest $RecoveryClaim "success-claim-cleanup"', , StartReadyPos)
	BakCleanupPos := InStr(Script,
		'RemoveBest $B "success-bak-cleanup"', , ClaimCleanupPos)
	Assert(CandidatePos > 0 and RecoveryPos > CandidatePos
		and StagePos > RecoveryPos and ClaimPos > StagePos
		and ReplacePos > ClaimPos,
		"complete new, recovery, republish-stage, and capability artifacts must exist before atomic Current replacement")
	Assert(StartReadyPos > ReplacePos and ReadyWaitPos > 0
		and ProbationPos > ReadyWaitPos and ClaimCleanupPos > StartReadyPos
		and BakCleanupPos > ClaimCleanupPos,
		"fallbacks may be retired only after the replacement signals boot-ready and survives probation")
	Assert(InStr(Script, '[IO.File]::Copy($NewExe,$CurrentExe') = 0,
		"the primary executable must never be copied directly over Current")
	Assert(InStr(Script, ".cmd") = 0 and InStr(Script, "Encoding]::ASCII") = 0,
		"the updater must persist and execute UTF-8 PowerShell, never an ASCII batch swapper")
}

Test("updater swap: atomic candidate publication retains fallbacks through boot-ready",
	_USBR_CheckPowerShellTransactionOrder)

_USBR_CheckRollbackRestoresAndRelaunches() {
	Script := _USBR_SwapScript()
	StopBodyPos := InStr(Script, 'function StopExact')
	KillPos := InStr(Script, '$Process.Kill()', , StopBodyPos)
	WaitCheckedPos := InStr(Script,
		'if(!$Process.WaitForExit(5000))', , KillPos)
	UnsafeGatePos := InStr(Script,
		'if($Failure.Exception.Message.StartsWith("UNSAFE_CHILD:"))')
	RetryPos := InStr(Script, 'for($I=0;$I -lt $RestoreAttempts', , UnsafeGatePos)
	StageFirstPos := InStr(Script,
		'if([IO.File]::Exists($RecoveryStage))', , RetryPos)
	AtomicRestorePos := InStr(Script,
		'[IO.File]::Replace($Source,$CurrentExe,$Bad,$true)', , StageFirstPos)
	RelaunchPos := InStr(Script,
		'$RestoredChild=StartReady $CurrentExe', , AtomicRestorePos)
	RecoveryLoopPos := InStr(Script,
		'for($RecoveryAttempt=0;', , RelaunchPos)
	RethrowPos := InStr(Script, 'throw $Failure', , RecoveryLoopPos)
	Assert(StopBodyPos > 0 and KillPos > StopBodyPos
		and WaitCheckedPos > KillPos and UnsafeGatePos > WaitCheckedPos
		and RetryPos > UnsafeGatePos and StageFirstPos > RetryPos
		and AtomicRestorePos > StageFirstPos and RelaunchPos > AtomicRestorePos
		and RecoveryLoopPos > RelaunchPos and RethrowPos > RecoveryLoopPos,
		"rollback must confirm exact-handle termination, restore atomically from the independent stage, and fall back to Recovery when Current cannot relaunch")
	Assert(InStr(Script, "Stop-Process -Id") = 0
		and InStr(Script, "rollback-restore-") > 0
		and InStr(Script, "rollback-relaunch:") > 0,
		"rollback must never target a recycled PID and every restore/relaunch failure must remain explicit")
}

Test("updater swap: failure restores and relaunches Current explicitly",
	_USBR_CheckRollbackRestoresAndRelaunches)

_USBR_CheckRecoveryExecutableFallback() {
	Script := _USBR_SwapScript()
	AdoptInterruptedBakPos := InStr(Script,
		'$Retired=(!$Had -and [IO.File]::Exists($B))')
	GuidPos := InStr(Script, '$Token=[Guid]::NewGuid().ToString("N")')
	RecoveryPos := InStr(Script, '".recovery.exe"', , GuidPos)
	StagePos := InStr(Script, '".republish.exe"', , RecoveryPos)
	ClaimWritePos := InStr(Script,
		'WriteClaim $RecoveryClaim $CurrentExe $RecoveryStage', , StagePos)
	MutationPos := InStr(Script,
		'[IO.File]::Replace($Candidate,$CurrentExe,$B,$true)', , ClaimWritePos)
	RecoveryLoopPos := InStr(Script, 'for($RecoveryAttempt=0;', , MutationPos)
	RecoveryStartPos := InStr(Script,
		'StartReady $Recovery $BootReadyTimeoutMs', , RecoveryLoopPos)
	DiagnosticPos := InStr(Script,
		'Diag("rollback-recovery:"', , RecoveryStartPos)
	Assert(AdoptInterruptedBakPos > 0 and GuidPos > AdoptInterruptedBakPos
		and RecoveryPos > GuidPos and StagePos > RecoveryPos
		and ClaimWritePos > StagePos and MutationPos > ClaimWritePos
		and RecoveryLoopPos > MutationPos and RecoveryStartPos > RecoveryLoopPos
		and DiagnosticPos > RecoveryStartPos,
		"a unique validated recovery, independent publish stage, and capability must predate mutation; fallback stays supervised through canonical boot-ready")
	Assert(InStr(Script, "AppendAllText($DiagnosticPath") > 0,
		"native swap failures need durable diagnostics because the AHK logger has exited")
	DescriptorBody := _DriverFuncBody("_Updater_LoadRecoveryDescriptor")
	BoundedReadBody := _DriverFuncBody("FSReadBounded")
	PollBody := _DriverFuncBody("_Updater_RecoveryRepublishPoll")
	Assert(InStr(DescriptorBody, 'RecoveryPath . ".claim"') > 0
		and InStr(DescriptorBody, "ExpectedStage") > 0,
		"a recovery-shaped filename without its exact same-directory claim must never authorize repair")
	Assert(InStr(BoundedReadBody, 'FileOpen(Path, "r", "UTF-8-RAW")') > 0
		and InStr(BoundedReadBody, "FH.Read(MaxBytes + 1)") > 0
		and InStr(BoundedReadBody, "FSRead(Path)") = 0,
		"the untrusted recovery claim must stay bounded on one open handle instead of stat-then-unbounded-read TOCTOU")
	PublishBody := _DriverFuncBody("_Updater_RepublishRecoveryExecutable")
	MovePos := InStr(PublishBody, "FSAtomicMoveReplace(StagePath, TargetPath)")
	Assert(MovePos > 0
		and InStr(SubStr(PublishBody, MovePos), "FSSize(TargetPath)") = 0,
		"atomic rename success must be the commit point; a fallible post-rename probe would consume the only retry stage")
	Assert(InStr(PollBody, "FileCopy(") = 0
		and InStr(PollBody, "_Updater_RepublishRecoveryExecutable") > 0,
		"post-ready recovery may retry only the prebuilt atomic stage, never copy a full executable on the keyboard thread")

	CreateBody := _DriverFuncBody("_Updater_CreateSuspendedSwapOwner")
	Assert(InStr(CreateBody, "UPDATER_SWAP_RESTORE_ATTEMPTS") > 0
		and InStr(CreateBody, "UPDATER_SWAP_RESTORE_RETRY_MS") > 0
		and InStr(CreateBody, "UPDATER_SWAP_BOOT_READY_TIMEOUT_MS") > 0,
		"bounded rollback and boot-ready constants must be passed explicitly to the native worker")
}

Test("updater swap: failed restore launches a capability-owned supervised recovery",
	_USBR_CheckRecoveryExecutableFallback)

_USBR_RecoveryBootLeaseAndPauseHandoff() {
	WindowsDir := RegExReplace(A_ScriptDir, "\\tests$")
	Entry := FileRead(WindowsDir . "\ErgoptiPlus.ahk", "UTF-8")
	DescriptorPos := InStr(Entry, "_Updater_LoadRecoveryDescriptor")
	StaleExitPos := InStr(Entry, "ExitApp(0)", , DescriptorPos)
	MutexPos := InStr(Entry, "DRIVER_MUTEX_NAME", , StaleExitPos)
	BundlePos := InStr(Entry, "Bundle_Init()", , MutexPos)
	DriverReadyPos := InStr(Entry, "_DriverReady := true", , BundlePos)
	MaintenancePos := InStr(Entry,
		"_Updater_ArmRecoveryMaintenanceAfterReady()", , DriverReadyPos)
	Assert(DescriptorPos > 0 and StaleExitPos > DescriptorPos
		and MutexPos > StaleExitPos and BundlePos > MutexPos
		and DriverReadyPos > BundlePos and MaintenancePos > DriverReadyPos,
		"recovery capability must be claimed before mutex/first pump, while repair and ready signaling may start only after the full driver is ready")
	MaintenanceBody := _DriverFuncBody("_Updater_ArmRecoveryMaintenanceAfterReady")
	Assert(InStr(MaintenanceBody, "_Updater_SignalInheritedBootReady") > 0,
		"a canonical replacement must acknowledge the worker only from the post-_DriverReady maintenance gate")

	InstallBody := _DriverFuncBody("Updater_DownloadAndInstall")
	RecoveryGatePos := InStr(InstallBody,
		'_UpdaterRecoveryPublishTarget != ""')
	BeginPos := InStr(InstallBody,
		"_Updater_BeginDownloadTransaction(", , RecoveryGatePos)
	ReserveBody := _DriverFuncBody(
		"_Updater_TryReserveDownloadTransaction")
	ReserveRecoveryPos := InStr(ReserveBody,
		'_UpdaterRecoveryPublishTarget != ""')
	DownloadClaimPos := InStr(ReserveBody,
		"_UpdaterDownloadInProgress := true", , ReserveRecoveryPos)
	Assert(RecoveryGatePos > 0 and BeginPos > RecoveryGatePos
		and ReserveRecoveryPos > 0 and DownloadClaimPos > ReserveRecoveryPos,
		"Update now must visibly refuse before it can target the running recovery executable")

	RequestBody := _DriverFuncBody("_Updater_RequestRecoveryHandoffExit")
	PreparePos := InStr(RequestBody, "_Updater_PrepareRecoverySuspendHandoff")
	InvocationPos := InStr(RequestBody,
		"_UpdaterRecoveryExitInvocation := true", , PreparePos)
	ExitPos := InStr(RequestBody, "ExitApp(0)", , InvocationPos)
	PrepareBody := _DriverFuncBody("_Updater_PrepareRecoverySuspendHandoff")
	Assert(PreparePos > 0 and InvocationPos > PreparePos and ExitPos > InvocationPos
		and InStr(PrepareBody, "_SuspendMarkerPath()") > 0
		and InStr(PrepareBody, "_SuspendHandoffPrepareMarker(Path)") > 0,
		"a suspended recovery must prepare inert pause intent before it can own the transient ExitApp handoff")

	CompleteBody := _DriverFuncBody("_Updater_CompleteRecoveryHandoffOnExit")
	ReadyEnvPos := InStr(CompleteBody,
		'EnvSet("ERGOPTI_UPDATER_BOOT_READY"')
	RunPos := InStr(CompleteBody, "Run('", , ReadyEnvPos)
	CommitPos := InStr(CompleteBody, "_SuspendHandoffCommitMarker(Path)", , RunPos)
	Assert(ReadyEnvPos > 0 and RunPos > ReadyEnvPos and CommitPos > RunPos,
		"the canonical child must inherit boot-ready authority and block on the mutex before terminal pause publication")
}

Test("updater recovery: pre-pump lease and paused handoff preserve driver state",
	_USBR_RecoveryBootLeaseAndPauseHandoff)
