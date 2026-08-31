; tests/meta/test_updater_worker_terminated_on_exit.ahk

; ==============================================================================
; MODULE: Update Staging Worker Exit-Teardown Meta Test
; DESCRIPTION:
; Static source guard for updater-staging-worker-orphaned-on-exit.
;
; Updater_DownloadAndInstall first spawns a tree-owned staging child through
; ShellRunner and writes the staged executable plus `swap_update.ps1`, then
; publishes a native exact-HANDLE swap child. Ordinary
; Reload/quit must terminate whichever owner is live. Only an acknowledged
; updater ExitIntent may transfer the swap child after all refusal gates.
;
; Ergopti_OnShutdown is the driver's single OnExit handler, and AHK's Reload()
; and ExitApp() run nothing else on the way out. Reload is the driver's standard
; "apply settings" mechanism and also fires automatically from the keyboard-
; layout watcher, so a Reload landing mid-download used to leave the child alive
; with nobody able to complete it: it finished, wrote ErgoptiPlus_new.exe and
; the staged executable and swap script, then exited while the fresh instance re-zeroed
; _UpdaterDownloadInProgress and performed no residue scan. The user who clicked
; "Update now" got no update, no error, and not one log line in the new
; instance's log — and the next explicit attempt deletes the staged files first,
; erasing the evidence. The Job's kill-on-close flag is a kernel backstop, while
; this explicit exit seam provides deterministic termination, timer cleanup and
; the warning that makes the interrupted update visible.
;
; The codebase had already recognised this hazard once and guarded exactly ONE
; Reload site (Updater_SetChannel, updater-channel-switch-download-race). This
; guard pins the seam that covers ALL of them: the process-exit handler.
;
; Meta-static because reproducing it needs a real multi-megabyte download racing
; a real Reload.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================================
; ======= 1/ The exit seam tears the worker down =======
; ======================================================
; ======================================================

_UWTE_ShutdownAbortsStagingWorker() {
	Body := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(Body != "", "Ergopti_OnShutdown() must exist in the driver source")

	Assert(InStr(Body, "_UpdaterDownloadWorker") > 0 or InStr(Body, "_Updater_AbortStagingOnExit") > 0,
		"the driver's single OnExit handler must tear down an in-flight update staging worker: Reload and ExitApp run no per-module destructor, and the staged swap script is launched only from _Updater_PollDownloadAsync, so an orphaned worker means the user's 'Update now' click silently installs nothing (updater-staging-worker-orphaned-on-exit)")

	; The exit handler must never throw — AHK swallows an OnExit exception and
	; can hang the exit — so the teardown has to be try-wrapped like its siblings.
	Assert(RegExMatch(Body, "try\s+_Updater_AbortStagingOnExit\(\)") > 0,
		"the staging teardown must be try-wrapped, like every other step of Ergopti_OnShutdown: an OnExit callback that throws is swallowed by AHK and can hang the exit")
}
Test("updater: process exit tears down an in-flight staging worker (updater-staging-worker-orphaned-on-exit)", _UWTE_ShutdownAbortsStagingWorker)





; =================================================
; =================================================
; ======= 2/ The teardown actually kills it =======
; =================================================
; =================================================

_UWTE_AbortHelperTerminatesAndLogs() {
	Body := _DriverFuncBody("_Updater_AbortStagingOnExit")
	CancelBody := _DriverFuncBody("_Updater_CancelSelfUpdateTransaction")
	Assert(Body != "", "_Updater_AbortStagingOnExit() must exist in the driver source")
	Assert(InStr(Body, "_Updater_CancelSelfUpdateTransaction") > 0,
		"ordinary exit must route through the same atomic take used by suspend entry")
	Assert(InStr(CancelBody, "Worker.terminate()") > 0,
		"ordinary exit must explicitly terminate the Job-owned ShellRunner tree before process teardown, rather than relying silently on kill-on-close")
	TakePos := InStr(CancelBody, "Owner := (_UpdaterSwapOwner is Map)")
	ClearPos := InStr(CancelBody, "_UpdaterSwapOwner := 0", , TakePos)
	ExactClosePos := InStr(CancelBody, "_Updater_CloseSwapOwner(Owner, true)", , ClearPos)
	Assert(TakePos > 0 and ClearPos > TakePos and ExactClosePos > ClearPos,
		"ordinary exit must atomically claim and terminate the exact native swap child")
	Assert(InStr(CancelBody, "SetTimer(_Updater_MonitorStagingWorker, 0)") > 0,
		"_Updater_AbortStagingOnExit must disarm the staging monitor timer, so the teardown leaves no armed callback behind")
	Assert(InStr(CancelBody, "LoggerError") > 0,
		"an interrupted update must be VISIBLE and close its START lifecycle at ERROR rather than exit quietly")
}
Test("updater: the exit teardown kills the staging child and logs it (updater-staging-worker-orphaned-on-exit)", _UWTE_AbortHelperTerminatesAndLogs)

_UWTE_CloseOwnerTakesHandleBeforeTermination() {
	Body := _DriverFuncBody("_Updater_CloseSwapOwner")
	ReleaseBody := _DriverFuncBody("_Updater_ReleaseSwapHandle")
	TryBody := _DriverFuncBody("_Updater_TrySwapCleanupRecord")
	WaitBody := _DriverFuncBody("_Updater_WaitSwapOwnerHandleState")
	SetBody := _DriverFuncBody("_Updater_SetSwapOwnerEvent")
	Assert(Body != "" and ReleaseBody != "" and TryBody != "",
		"the exact-owner close and cleanup-debt helpers must exist")
	TakePos := InStr(Body,
		'_Updater_TakeSwapProcessHandles(Owner)')
	ReleasePos := InStr(Body,
		"_Updater_ReleaseSwapHandle(ProcessHandle, TerminateChild)", , TakePos)
	QueuePos := InStr(ReleaseBody, "_Updater_QueueSwapCleanupDebt(Handle, Terminate)")
	DrainPos := InStr(ReleaseBody, "_Updater_DrainSwapCleanupRecord(DebtId)", , QueuePos)
	TerminatePos := InStr(TryBody, "PLC_TerminateProcessHandle(Handle)")
	ClosePos := InStr(TryBody, "PLC_CloseNativeHandle(Handle)", , TerminatePos)
	Assert(TakePos > 0 and ReleasePos > TakePos
		and QueuePos > 0 and DrainPos > QueuePos
		and TerminatePos > 0 and ClosePos > TerminatePos,
		"ProcessHandle must be taken, published as debt, then terminated and closed")
	Assert(InStr(Body, 'Owner.Get("ProcessHandle"') = 0
		and InStr(Body, 'Owner.Get("ProcessInfo"') = 0,
		"a stale callback must never read a closed ProcessHandle value from the shared Owner Map")
	for GuardBody in [WaitBody, SetBody]
		Assert(InStr(GuardBody, 'Critical("On")') > 0
			and InStr(GuardBody, "Owner.Get(Name, 0)") > 0,
			"every non-owning shared HANDLE call must keep its Map read and Win32 use in one Critical span")
}

Test("updater: exact swap handle is take-and-zero before TerminateProcess",
	_UWTE_CloseOwnerTakesHandleBeforeTermination)

_UWTE_UpdaterIntentTransfersBeforeOrdinaryAbort() {
	ShutdownBody := _DriverFuncBody("Ergopti_OnShutdown")
	SignalBody := _DriverFuncBody("_Updater_SignalFinalExitForIntent")
	TransferBody := _DriverFuncBody("_Updater_TransferExitIntentAfterShutdownGates")
	Assert(ShutdownBody != "" and SignalBody != "" and TransferBody != "",
		"shutdown, FinalExit authorization, and transfer helpers must exist")
	TapGatePos := InStr(ShutdownBody, "TapHoldShutdownReleaseGate")
	HotstringGatePos := InStr(ShutdownBody,
		"HotstringPrefixWatcherPrepareShutdown", , TapGatePos)
	SignalPos := InStr(ShutdownBody, "_Updater_SignalFinalExitForIntent")
	TransferPos := InStr(ShutdownBody,
		"_Updater_TransferExitIntentAfterShutdownGates", , SignalPos)
	RecoveryGatePos := InStr(ShutdownBody,
		"_Updater_CompleteRecoveryHandoffOnExit", , TransferPos)
	ProducerStopPos := InStr(ShutdownBody,
		"HotstringPrefixWatcherStop", , RecoveryGatePos)
	AbortPos := InStr(ShutdownBody, "_Updater_AbortStagingOnExit", , TransferPos)
	Assert(TapGatePos > 0 and HotstringGatePos > TapGatePos
		and SignalPos > HotstringGatePos and TransferPos > SignalPos
		and RecoveryGatePos > TransferPos && ProducerStopPos > RecoveryGatePos
		and AbortPos > ProducerStopPos,
		"all reversible drains and authority gates must precede producer teardown; only accepted ownership transfer may precede ordinary abort")
	Assert(InStr(SignalBody, 'Current.Get("FinalExitHandle"') > 0
		and InStr(SignalBody, "_Updater_ExitIntentStillAuthorized(Current)") > 0
		and InStr(SignalBody, "_Updater_FailSwapTransaction(") > 0,
		"FinalExit must revalidate pause plus the exact intent owner immediately before SetEvent and fail the exact transaction on refusal")
	Assert(InStr(TransferBody, "_Updater_ExitIntentStillAuthorized(Current)") > 0
		and InStr(TransferBody, "_UpdaterSwapOwner := 0") > 0
		and InStr(TransferBody, "_UpdaterExitIntent := 0") > 0
		and InStr(TransferBody, "_Updater_FailSwapTransaction(") > 0,
		"transfer must revalidate the child, fail its exact transaction on refusal, and clear both parent-side owners only on success")
}

Test("updater: acknowledged ExitIntent transfers only after all shutdown refusal gates",
	_UWTE_UpdaterIntentTransfersBeforeOrdinaryAbort)

_UWTE_AssertRetryableRefusalRearms(ShutdownBody, BranchNeedle) {
	BranchPos := InStr(ShutdownBody, BranchNeedle, true)
	Assert(BranchPos > 0,
		"shutdown refusal branch must remain source-visible: " . BranchNeedle)
	ReturnPos := InStr(ShutdownBody, "return 1", true, BranchPos)
	Assert(ReturnPos > BranchPos,
		"shutdown refusal branch must return nonzero: " . BranchNeedle)
	Branch := SubStr(ShutdownBody, BranchPos, ReturnPos - BranchPos)
	Assert(InStr(Branch, "_Updater_DeferExitIntentRetry()", true) > 0,
		"an updater ExitApp that returns from this refusal must be re-armed: " . BranchNeedle)
	Assert(InStr(Branch, "_Updater_DeferRecoveryHandoffRetry()", true) > 0,
		"a recovery handoff ExitApp that returns from this refusal must be re-armed: " . BranchNeedle)
}

_UWTE_EveryRetryablePreflightRefusalRearms() {
	ShutdownBody := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(ShutdownBody != "", "shutdown must remain source-visible")
	for Needle in [
		"if !(ShutdownOwners is Object)",
		"if !SyntheticReleased",
		"if !((FullSaveSettled is Integer)",
		"if !((TriggerJournalCanExit is Integer)",
		"if !RecoveryCanExit",
		"if !FireDrainComplete",
		"if !TerminalCommitted"
	]
		_UWTE_AssertRetryableRefusalRearms(ShutdownBody, Needle)

	FirstIrreversiblePos := InStr(ShutdownBody,
		'GestureScreenshotCancelAll("shutdown")', true)
	Assert(FirstIrreversiblePos > 0,
		"the accepted shutdown tail must remain source-visible")
	Assert(InStr(SubStr(ShutdownBody, FirstIrreversiblePos),
		"_Updater_DeferExitIntentRetry", true) == 0,
		"a retry must never be armed after irreversible producer teardown starts")
	Assert(InStr(ShutdownBody,
		"_Updater_CancelExitIntentAfterLifecycleTeardown", true) == 0,
		"shutdown must not rely on post-teardown repair now that every refusal gate precedes teardown")
}

Test("updater: every retryable preflight refusal re-arms terminal ownership",
	_UWTE_EveryRetryablePreflightRefusalRearms)
