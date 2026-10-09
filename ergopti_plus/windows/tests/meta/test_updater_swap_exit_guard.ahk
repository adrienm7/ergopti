; tests/meta/test_updater_swap_exit_guard.ahk

; ==============================================================================
; MODULE: Updater Swap Exit Guard Meta Test
; DESCRIPTION:
; Guards the transactional replacement for the former bare Run(swap-script) then
; ExitApp gap. The native worker must be created suspended, published as the
; exact owner before ResumeThread, and acknowledged through Ready/Commit/Ack
; before an updater-specific ExitIntent can request shutdown. FinalExit remains
; an OnExit-only authorization after refusal gates accept the exit.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TUSEG_SuspendedOwnerPublishedBeforeResume() {
	CreateBody := _DriverFuncBody("_Updater_CreateSuspendedSwapOwner")
	ReserveBody := _DriverFuncBody("_Updater_ReserveSwapOwner")
	StartBody := _DriverFuncBody("_Updater_StartSwapTransaction")
	ResumeBody := _DriverFuncBody("_Updater_ResumeSwapOwner")
	TakeBody := _DriverFuncBody("_Updater_TakeSwapResumeHandles")
	Assert(CreateBody != "" and ReserveBody != "" and StartBody != ""
		and ResumeBody != "" and TakeBody != "",
		"the native suspended-worker creation and publication functions must exist")
	Assert(InStr(CreateBody, "PLC_CreateProcessWithInheritedHandles") > 0
		and InStr(CreateBody, "UPDATER_SWAP_CREATE_SUSPENDED") > 0,
		"the swapper must use the inherited-handle process adapter with CREATE_SUSPENDED, never Run")
	ReservePos := InStr(StartBody,
		"_Updater_ReserveSwapOwner(TransactionId, StagingEpoch)")
	CreatePos := InStr(StartBody, "_Updater_CreateSuspendedSwapOwner(", , ReservePos)
	ResumePos := InStr(StartBody, "_Updater_ResumeSwapOwner(Owner)")
	FailureClaimPos := InStr(StartBody, "_Updater_ClaimSwapOwner(TransactionId)", , ResumePos)
	FailureClosePos := InStr(StartBody, "_Updater_CloseSwapOwner(Claimed, true)", , FailureClaimPos)
	Assert(InStr(ReserveBody, "_UpdaterSwapOwner := Owner") > 0
		and ReservePos > 0 and CreatePos > ReservePos and ResumePos > CreatePos,
		"a Starting owner must be reserved before CreateProcess and retained through ResumeThread")
	NativeCreatePos := InStr(CreateBody,
		"PLC_CreateProcessWithInheritedHandles(PowerShellPath")
	ProcessInfoSharePos := InStr(CreateBody,
		'Owner["ProcessInfo"] := ProcessInfo')
	ReservationCheckPos := InStr(CreateBody, "_UpdaterSwapOwner == Owner", , NativeCreatePos)
	HandlePublishPos := InStr(CreateBody,
		"Owner[Name] := LocalHandles[Name]", , ReservationCheckPos)
	Assert(ProcessInfoSharePos > 0 and NativeCreatePos > ProcessInfoSharePos
		and ReservationCheckPos > NativeCreatePos
		and HandlePublishPos > ReservationCheckPos,
		"PROCESS_INFORMATION must be shared before CreateProcess, then transferred only after the live reservation is revalidated")
	TakeProcessBody := _DriverFuncBody("_Updater_TakeSwapProcessHandles")
	Assert(InStr(TakeProcessBody, 'Owner.Get("ProcessInfo"') > 0
		and InStr(TakeProcessBody, "NumGet(ProcessInfo") > 0,
		"OnExit must be able to take and terminate handles written just before the creator publishes its Map slots")
	Assert(FailureClaimPos > ResumePos and FailureClosePos > FailureClaimPos,
		"ResumeThread failure must claim and terminate the suspended exact child fail-closed")
	TakePos := InStr(ResumeBody, "_Updater_TakeSwapResumeHandles(Owner)")
	NativeResumePos := InStr(ResumeBody,
		"PLC_ResumeThreadHandle(ThreadHandle)", , TakePos)
	LocalClosePos := InStr(ResumeBody,
		"_Updater_CloseNativeSwapHandle(ThreadHandle)", , NativeResumePos)
	Assert(TakePos > 0 and NativeResumePos > TakePos and LocalClosePos > NativeResumePos,
		"ThreadHandle and ParentHandle must leave the shared Owner before ResumeThread and close only through local ownership")
	Assert(InStr(TakeBody, 'Owner["ThreadHandle"] := 0') > 0
		and InStr(TakeBody, 'Owner["ParentHandle"] := 0') > 0,
		"the paired take must zero both shared slots atomically before native use")
}

Test("updater swap: exact suspended owner is published before ResumeThread",
	_TUSEG_SuspendedOwnerPublishedBeforeResume)

_TUSEG_AckGuardsExitIntent() {
	FinalizeBody := _DriverFuncBody("_Updater_PollDownloadAsync")
	PollBody := _DriverFuncBody("_Updater_PollSwapHandshake")
	ExitBody := _DriverFuncBody("_Updater_RequestExitForIntent")
	Assert(FinalizeBody != "" and PollBody != "" and ExitBody != "",
		"the staging finalizer, handshake poller, and guarded exit request must exist")
	Assert(InStr(FinalizeBody, "Run(") = 0 and InStr(FinalizeBody, "ExitApp(") = 0,
		"staging completion must contain no launch-to-exit gap")
	ReadyPos := InStr(PollBody, 'Phase == "AwaitReady"')
	CommitPos := InStr(PollBody, '"CommitHandle"', , ReadyPos)
	AckPos := InStr(PollBody, '"AckHandle"', , CommitPos)
	IntentPos := InStr(PollBody, "_Updater_PublishExitIntent", , AckPos)
	RequestPos := InStr(PollBody, "_Updater_RequestExitForIntent", , IntentPos)
	Assert(ReadyPos > 0 and CommitPos > ReadyPos and AckPos > CommitPos
		and IntentPos > AckPos and RequestPos > IntentPos,
		"Ready must precede Commit, Ack must precede exact ExitIntent publication, and only then may shutdown be requested")
	Assert(InStr(ExitBody, "_Updater_IntentOwner(TransactionId)") > 0
		and InStr(ExitBody, "_Updater_ExitIntentStillAuthorized(Owner)") > 0
		and InStr(ExitBody, "ExitApp(0)") > 0,
		"ExitApp must revalidate suspend state plus the exact live intent owner")
	PublishPos := InStr(ExitBody,
		"_Updater_PublishExitInvocation(TransactionId, Owner)")
	ExitPos := InStr(ExitBody, "ExitApp(0)", , PublishPos)
	FinallyPos := InStr(ExitBody, "finally", , ExitPos)
	ClearPos := InStr(ExitBody,
		"_Updater_ClearExitInvocation(TransactionId, Owner)", , FinallyPos)
	Assert(InStr(ExitBody, 'Critical("On")') > 0 and PublishPos > 0
		and ExitPos > PublishPos and FinallyPos > ExitPos and ClearPos > FinallyPos,
		"only the synchronous guarded ExitApp call may own a transient invocation, and every refused exit must clear it in finally")
	for FunctionName in ["_Updater_SignalFinalExitForIntent",
		"_Updater_TransferExitIntentAfterShutdownGates",
		"_Updater_DeferExitIntentRetry"] {
		Body := _DriverFuncBody(FunctionName)
		Assert(InStr(Body, "_Updater_ExitInvocationOwner") > 0,
			FunctionName . " must reject an ordinary Quit that merely overlaps the persistent Ack intent")
	}
}

Test("updater swap: Ack and exact-child liveness guard ExitIntent",
	_TUSEG_AckGuardsExitIntent)

_TUSEG_ChildWaitsForFinalExitAndExactParent() {
	CreateBody := _DriverFuncBody("_Updater_CreateSuspendedSwapOwner")
	OpenBody := _DriverFuncBody("PLC_OpenCurrentProcessHandle")
	NativeCreateBody := _DriverFuncBody("PLC_CreateProcessWithInheritedHandles")
	Assert(CreateBody != "" and OpenBody != "" and NativeCreateBody != "",
		"the exact swap-worker creator and process adapters must exist")
	Script := _Updater_BuildSwapWorkerScript()
	ReadyPos := InStr(Script, "$R.Set()")
	CommitWaitPos := InStr(Script, '@($C,$P)')
	AckPos := InStr(Script, "$A.Set()", , CommitWaitPos)
	FinalWaitPos := InStr(Script, '@($F,$P)', , AckPos)
	ParentExitPos := InStr(Script, "$P.WaitOne()", , FinalWaitPos)
	MutationPos := InStr(Script, '$B=$CurrentExe+".bak"', , ParentExitPos)
	Assert(ReadyPos > 0 and CommitWaitPos > ReadyPos and AckPos > CommitWaitPos
		and FinalWaitPos > AckPos and ParentExitPos > FinalWaitPos
		and MutationPos > ParentExitPos,
		"the child must signal Ready, await Commit, signal Ack, await FinalExit, then await the exact parent before any mutation")
	Assert(InStr(Script, 'if($G -eq 1){exit 20}') > 0
		and InStr(Script, 'if($G -eq 1){exit 21}') > 0,
		"the child must abandon when the parent dies before Commit or FinalExit")
	Assert(InStr(CreateBody, "PLC_OpenCurrentProcessHandle(") > 0
		and InStr(CreateBody, "UPDATER_SWAP_SYNCHRONIZE") > 0
		and InStr(CreateBody, 'LocalHandles["ParentHandle"]') > 0
		and InStr(OpenBody, "OpenProcess") > 0
		and InStr(OpenBody, '"Int", true') > 0
		and InStr(NativeCreateBody, "CreateProcessW") > 0
		and InStr(NativeCreateBody, '"Int", true') > 0,
		"CreateProcessW must inherit the exact SYNCHRONIZE parent handle passed to the worker")
}

Test("updater swap: child waits for FinalExit and exact parent before mutation",
	_TUSEG_ChildWaitsForFinalExitAndExactParent)

_TUSEG_PauseBetweenAckAndOnExitRevokesEveryBoundary() {
	global UPDATER_SWAP_SYNCHRONIZE
	HelperBody := _DriverFuncBody("_Updater_ExitIntentStillAuthorized")
	Assert(HelperBody != "" and InStr(HelperBody, "SuspendedOverride") > 0
		and InStr(HelperBody, 'Owner.Get("ProcessHandle"') > 0,
		"the shared authorization seam must check injected pause state and the exact child handle")
	for FunctionName in ["_Updater_RequestExitForIntent",
		"_Updater_SignalFinalExitForIntent",
		"_Updater_TransferExitIntentAfterShutdownGates"] {
		Body := _DriverFuncBody(FunctionName)
		Assert(InStr(Body, "_Updater_ExitIntentStillAuthorized") > 0,
			FunctionName . " must revalidate pause and child liveness independently")
	}

	ProcessHandle := DllCall("OpenProcess", "UInt", UPDATER_SWAP_SYNCHRONIZE,
		"Int", false, "UInt", DllCall("GetCurrentProcessId", "UInt"), "Ptr")
	Assert(ProcessHandle != 0,
		"positive control: the test needs a live exact process handle")
	try {
		Owner := Map("ProcessHandle", ProcessHandle)
		Assert(_Updater_ExitIntentStillAuthorized(Owner, false),
			"Ack-time authorization must accept an unsuspended live exact child")
		Assert(!_Updater_ExitIntentStillAuthorized(Owner, true),
			"a Pause landing before OnExit must revoke the same owner without suspending the test suite")
	} finally {
		_Updater_CloseNativeSwapHandle(ProcessHandle)
	}
}

Test("updater swap: Pause between Ack and OnExit revokes request, signal, and transfer",
	_TUSEG_PauseBetweenAckAndOnExitRevokesEveryBoundary)
