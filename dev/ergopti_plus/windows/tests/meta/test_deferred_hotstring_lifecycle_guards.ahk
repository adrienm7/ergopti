; tests/meta/test_deferred_hotstring_lifecycle_guards.ahk

; ==============================================================================
; MODULE: AHK-22 Deferred Hotstring Lifecycle Whole-Class Guard
; DESCRIPTION:
; A 90 ms fire-log timer crossed native Suspend, emptied the typing buffer, then
; reached the only pause guard in KL_AppendLog too late. The same subsystem also
; has captured near-miss state and a delayed render. This guard pins the entire
; deferred callback class to one generation gate, pins the three independent
; fire sinks before their first mutation, and pins suspend/resume/shutdown to the
; ownership transfer. A one-site guard in KL_AppendLog is deliberately rejected.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ Every captured callback owns a generation =======
; ============================================================
; ============================================================

_DHLC_CapturedCallbacksAreLifecycleOwned() {
	Callbacks := ["_HSE_DrainFireLog", "_CheckNearMiss", "_PrefixRenderFlush"]
	for CallbackName in Callbacks {
		Body := _DriverFuncBody(CallbackName)
		Assert(Body != "", CallbackName . "() must exist in the driver source")
		Assert(InStr(Body, "_PrefixDeferredCanPublish") > 0,
			"AHK-22: " . CallbackName . " carries deferred hotstring state and must pass the shared pause+generation ownership gate before publishing")
	}
	RenderArmBody := _DriverFuncBody("_PrefixScheduleRender")
	Assert(InStr(RenderArmBody, "_PrefixRenderFlush.Bind(_PrefixDeferredGeneration)") > 0,
		"AHK-22: the render timer must freeze its lifecycle generation instead of reading a mutable scheduled-generation cache when it eventually fires")

	DrainBody := _DriverFuncBody("_HSE_DrainFireLog")
	GatePos := InStr(DrainBody, "_PrefixDeferredCanPublish")
	SwapPos := InStr(DrainBody, "Batch := _HSE_FireLogQueue")
	SinkPos := InStr(DrainBody, "KL_LogHotstring(")
	Assert(SwapPos > 0 && SinkPos > 0,
		"AHK-22: the drain guard must inspect the real queue swap and hotstring sink")
	Assert(GatePos > 0 && GatePos < SwapPos && GatePos < SinkPos,
		"AHK-22: ownership must be checked before the queue is cleared or any sink can mutate state")
	Assert(InStr(DrainBody, "PublishGuard") > 0
		&& InStr(DrainBody, "Rec.IsPrivate, PublishGuard") > 0,
		"AHK-22: the drain must carry its exact generation owner into the sink so a pause/reset landing mid-call is still observable")
	ArmBody := _DriverFuncBody("_HSE_ArmFireLogDrain")
	Assert(InStr(ArmBody, "_HSE_DrainFireLog.Bind(_PrefixDeferredGeneration)") > 0,
		"AHK-22: SetTimer must carry an immutable generation argument; a mutable scheduled-generation global lets an old queued callback impersonate the resume owner")

	QueueBody := _DriverFuncBody("_HSE_QueueFireLog")
	Assert(QueueBody != "", "_HSE_QueueFireLog() must exist in the driver source")
	Assert(InStr(QueueBody, "A_IsSuspended") > 0
		&& InStr(QueueBody, "A_IsSuspended") < InStr(QueueBody, "_HSE_FireLogQueue.Push"),
		"AHK-22: no callback that bypasses Suspend may enqueue a new fire after the pause boundary")
}





; =======================================================
; =======================================================
; ======= 2/ Every mutation sink fails closed too =======
; =======================================================
; =======================================================

_DHLC_AllFireSinksGuardBeforeMutation() {
	LogBody := _DriverFuncBody("KL_LogHotstring")
	Assert(LogBody != "", "KL_LogHotstring() must exist in the driver source")
	PausePos := InStr(LogBody, "A_IsSuspended")
	FlushPos := InStr(LogBody, "KL_FlushBuffer(")
	Assert(PausePos > 0 && FlushPos > 0 && PausePos < FlushPos,
		"AHK-22: KL_LogHotstring must guard pause before KL_FlushBuffer clears pre-pause typing state")
	Assert(InStr(LogBody, "KL_FlushBuffer(publish_guard, &FlushDeferred)") > 0,
		"AHK-22: KL_LogHotstring must pass the timer's generation owner through the destructive flush boundary")
	Assert(InStr(LogBody, "if FlushDeferred") > 0,
		"AHK-22: a re-entrant flush must retain the fire instead of overtaking its older typing snapshot")
	Assert(InStr(LogBody, "&FireRejectedBySuspend") > 0,
		"AHK-22: the sink must distinguish a retryable suspend refusal from a terminal privacy/validation drop")

	FlushBody := _DriverFuncBody("KL_FlushBuffer")
	Assert(FlushBody != "", "KL_FlushBuffer() must exist in the driver source")
	FlushGatePos := InStr(FlushBody, "PublishGuard.Call")
	SnapshotPos := InStr(FlushBody, "Snapshot := {")
	Assert(FlushGatePos > 0 && SnapshotPos > 0 && FlushGatePos < SnapshotPos,
		"AHK-22: KL_FlushBuffer must verify generation inside its Critical snapshot transaction before clearing shared typing state")
	PublishBody := _DriverFuncBody("_KL_PublishBufferSnapshot")
	Assert(PublishBody != "", "_KL_PublishBufferSnapshot() must exist in the driver source")
	Assert(InStr(PublishBody, "_KL_RestoreBufferSnapshot") > 0,
		"AHK-22: a lifecycle loss observed after the snapshot must restore the pre-pause buffer instead of destroying it")
	LatchPos := InStr(FlushBody, "if Keylogger._flush_in_progress")
	ClaimPos := InStr(FlushBody, "Keylogger._flush_in_progress := true")
	Assert(LatchPos > 0 && ClaimPos > LatchPos && LatchPos < SnapshotPos,
		"AHK-22: detached snapshots must be serialised before the destructive swap so rejected restores cannot reverse typing order")
	Assert(InStr(PublishBody, "KL_AppendLog(entry, &RejectedBySuspend)") > 0
		&& InStr(PublishBody, "if RejectedBySuspend") > 0,
		"AHK-22: typing restoration must depend on the append's explicit suspend outcome, never on an ambiguous false shared with privacy filtering")

	AppendBody := _DriverFuncBody("KL_AppendLog")
	Assert(AppendBody != "", "KL_AppendLog() must exist in the driver source")
	Assert(InStr(AppendBody, "RejectedBySuspend := true") > 0,
		"AHK-22: KL_AppendLog must identify its native-Suspend rejection for detached-state callers")
	AppendCriticalPos := InStr(AppendBody, 'AppendCritical := Critical("On")')
	AppendFinalPausePos := InStr(AppendBody, "A_IsSuspended", , AppendCriticalPos)
	AppendMutationPos := InStr(AppendBody, "Keylogger._pending_entries.Push")
	Assert(AppendCriticalPos > 0 && AppendFinalPausePos > AppendCriticalPos
		&& AppendMutationPos > AppendFinalPausePos,
		"AHK-22: KL_AppendLog must pair its post-filter pause recheck and pending-queue mutation in one short Critical transaction")

	RoiBody := _DriverFuncBody("KL_Roi_OnHotstring")
	Assert(RoiBody != "", "KL_Roi_OnHotstring() must exist in the driver source")
	RoiCriticalPos := InStr(RoiBody, 'RoiCritical := Critical("On")')
	RoiFinalPausePos := InStr(RoiBody, "A_IsSuspended", , RoiCriticalPos)
	RoiMutationPos := InStr(RoiBody, "KLRoi.session_saved_chars +=")
	Assert(RoiCriticalPos > 0 && RoiFinalPausePos > RoiCriticalPos
		&& RoiMutationPos > RoiFinalPausePos,
		"AHK-22: the ROI sink must pair its post-helper pause recheck and session mutation in one short Critical transaction")

	WpmBody := _DriverFuncBody("WPMWidget_Push")
	Assert(WpmBody != "", "WPMWidget_Push() must exist in the driver source")
	WpmCriticalPos := InStr(WpmBody, 'RingCritical := Critical("On")')
	WpmFinalPausePos := InStr(WpmBody, "A_IsSuspended", , WpmCriticalPos)
	WpmMutationPos := InStr(WpmBody, "WPMWidget._ring.Push")
	Assert(WpmCriticalPos > 0 && WpmFinalPausePos > WpmCriticalPos
		&& WpmMutationPos > WpmFinalPausePos,
		"AHK-22: the WPM sink must pair its post-helper pause recheck and ring mutation in one short Critical transaction")
}





; =========================================================
; =========================================================
; ======= 3/ Lifecycle transfers one explicit owner =======
; =========================================================
; =========================================================

_DHLC_LifecycleOwnsDeferredCallbacks() {
	EnterBody := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(EnterBody != "", "Ergopti_OnSuspendEnter() must exist in the driver source")
	RetirePos := InStr(EnterBody, "HotstringPrefixWatcherOnSuspend")
	ResetPos := InStr(EnterBody, "HSE_HardReset")
	Assert(RetirePos > 0 && ResetPos > 0 && RetirePos < ResetPos,
		"AHK-22: suspend must retire deferred owners before clearing hotstring state")

	ResumeBody := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(ResumeBody != "", "Ergopti_OnSuspendResume() must exist in the driver source")
	Assert(InStr(ResumeBody, "HotstringPrefixWatcherOnResume") > 0,
		"AHK-22: resume must transfer a retained fire batch to one fresh owner")

	ShutdownBody := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(ShutdownBody != "", "Ergopti_OnShutdown() must exist in the driver source")
	LeasePos := InStr(ShutdownBody, "KL_BeginShutdown")
	PreparePos := InStr(ShutdownBody, "HotstringPrefixWatcherPrepareShutdown")
	FinalGatePos := InStr(ShutdownBody,
		"_Updater_CompleteRecoveryHandoffOnExit")
	ProducerStopPos := InStr(ShutdownBody, "HotstringPrefixWatcherStop")
	DrainPos := InStr(ShutdownBody, "HotstringPrefixWatcherOnShutdown")
	StopPos := InStr(ShutdownBody, "KL_Stop")
	Assert(LeasePos > 0 && PreparePos > LeasePos
		&& FinalGatePos > PreparePos && ProducerStopPos > FinalGatePos
		&& DrainPos > ProducerStopPos && StopPos > DrainPos,
		"AHK-22: reload/exit must publish the reversible keylogger lease, prepare the retained batch, accept every refusal gate, then stop the producer and close the sinks")
	DrainFailurePos := InStr(ShutdownBody, "if !FireDrainComplete")
	FinalAuthorizationPos := InStr(ShutdownBody,
		"FinalExitAuthorized := false", , DrainFailurePos)
	Assert(FinalAuthorizationPos > DrainFailurePos,
		"the final drain branch must remain bounded before FinalExit authorization")
	DrainFailureBranch := SubStr(ShutdownBody, DrainFailurePos,
		FinalAuthorizationPos - DrainFailurePos)
	CancelLeasePos := InStr(DrainFailureBranch, "KL_CancelShutdown()")
	ExitRetryPos := InStr(DrainFailureBranch,
		"_Updater_DeferExitIntentRetry()", , CancelLeasePos)
	RecoveryRetryPos := InStr(DrainFailureBranch,
		"_Updater_DeferRecoveryHandoffRetry()", , ExitRetryPos)
	RefusePos := InStr(DrainFailureBranch, "return 1", , RecoveryRetryPos)
	Assert(InStr(ShutdownBody,
		"FireDrainComplete := HotstringPrefixWatcherPrepareShutdown") > 0
		&& DrainFailurePos > 0 && CancelLeasePos > 0
		&& ExitRetryPos > CancelLeasePos
		&& RecoveryRetryPos > ExitRetryPos && RefusePos > RecoveryRetryPos,
		"AHK-22: a prepared-batch refusal must withdraw the only reversible lease and re-arm each active terminal requester before returning")
}


Test("AHK-22 deferred-hotstring-lifecycle: every captured callback owns a generation",
	_DHLC_CapturedCallbacksAreLifecycleOwned)
Test("AHK-22 deferred-hotstring-lifecycle: every fire sink guards before mutation",
	_DHLC_AllFireSinksGuardBeforeMutation)
Test("AHK-22 deferred-hotstring-lifecycle: suspend resume shutdown transfer ownership",
	_DHLC_LifecycleOwnsDeferredCallbacks)
