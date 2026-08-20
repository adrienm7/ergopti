; tests/meta/test_updater_setchannel_cancels_async.ahk

; ==============================================================================
; MODULE: Updater_SetChannel Replacement-Transaction Meta Test
; DESCRIPTION:
; Class guard for AHK-31 Repro B. Channel replacement owns one admission
; boundary across persistence, cadence retirement, registry swap, terminal
; callbacks and a deferred Reload. Registry emptiness alone is insufficient:
; an active COM lease or a callback already claimed by an exact take can still
; re-enter updater code before returning.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Channel transaction ordering =========
; ==================================================
; ==================================================

_USCA_SetChannelOwnsReplacementTransaction() {
	Seg := _DriverFuncBody("Updater_SetChannel")
	Assert(Seg != "", "Updater_SetChannel(Channel) declaration must exist")
	ConfigBundleIdx := InStr(Seg,
		"_Updater_AcquireChannelConfigBundle()")
	BoundaryIdx := InStr(Seg,
		"_Updater_BeginAsyncAdmissionBoundary(", , ConfigBundleIdx)
	StopIdx := BoundaryIdx > 0
		? InStr(Seg, "Updater_StopBackgroundChecks(false)", , BoundaryIdx) : 0
	FirstPersistIdx := BoundaryIdx > 0
		? InStr(Seg, "ConfigCommitBorrowedUpdates(", , BoundaryIdx) : 0
	PublishIdx := FirstPersistIdx > 0
		? InStr(Seg, "UPDATER_CHANNEL := Channel", , FirstPersistIdx) : 0
	EpochIdx := PublishIdx > 0
		? InStr(Seg, "_UpdaterChannelEpoch += 1", , PublishIdx) : 0
	CancelIdx := EpochIdx > 0
		? InStr(Seg,
			"_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_CHANNEL_SWITCH)", , EpochIdx)
		: 0
	DeferIdx := CancelIdx > 0
		? InStr(Seg, "_Updater_BeginDeferredChannelReload(", , CancelIdx) : 0
	Assert(ConfigBundleIdx > 0 and BoundaryIdx > ConfigBundleIdx
		and StopIdx > BoundaryIdx
		and FirstPersistIdx > StopIdx
		and PublishIdx > FirstPersistIdx and EpochIdx > PublishIdx
		and CancelIdx > EpochIdx and DeferIdx > CancelIdx,
		"SetChannel must close admission, retire cadence before persistence, publish a monotone epoch, then swap the registry and hand off to deferred Reload")
	Assert(InStr(Seg, "ConfigCommitBorrowedUpdates(") == FirstPersistIdx,
		"channel persistence must use only the borrowed exact owner from the global terminal bundle")
	Assert(InStr(Seg, "GatewayWriter := IsObject(WriteFn)", , StopIdx) > StopIdx,
		"channel persistence must preserve the legacy object-vs-default writer seam")
	Assert(InStr(Seg, "ReloadPreservingSuspend()") == 0,
		"SetChannel must never Reload directly on the persistence/cancellation callback stack")
	FinallyIdx := DeferIdx > 0 ? InStr(Seg, "finally", , DeferIdx) : 0
	EndBoundaryIdx := FinallyIdx > 0
		? InStr(Seg, "_Updater_EndAsyncAdmissionBoundary(", , FinallyIdx) : 0
	Assert(FinallyIdx > DeferIdx and EndBoundaryIdx > FinallyIdx,
		"every pre-handoff exit must release only the exact admission owner from finally")
	Assert(InStr(Seg, "_Updater_ReleaseChannelConfigBundle(", , FinallyIdx) > FinallyIdx,
		"every non-retained exit must also release the exact global configuration bundle")
}
Test("updater AHK-31: SetChannel owns the complete replacement transaction (updater-channel-replacement-transaction)",
	_USCA_SetChannelOwnsReplacementTransaction)

_USCA_PersistsBeforePublishingChannel() {
	Seg := _DriverFuncBody("Updater_SetChannel")
	PersistAt := InStr(Seg, "ConfigCommitBorrowedUpdates(")
	PublishAt := PersistAt > 0
		? InStr(Seg, "UPDATER_CHANNEL := Channel", , PersistAt) : 0
	FailureAt := PersistAt > 0
		? InStr(Seg, "if !Persisted", , PersistAt)
		: 0
	Assert(PersistAt > 0 and PublishAt > PersistAt and FailureAt > PersistAt,
		"typed borrowed persistence failure must stop before runtime publication")
}
Test("updater AHK-31: channel persistence commits before publication (updater-channel-replacement-transaction)",
	_USCA_PersistsBeforePublishingChannel)

_USCA_DeferredReloadRequiresFullQuiescence() {
	RunBody := _DriverFuncBodyOrEmpty("_Updater_RunDeferredChannelReload")
	Quiescent := _DriverFuncBodyOrEmpty("_Updater_ChannelReloadQuiescent")
	Fail := _DriverFuncBodyOrEmpty("_Updater_FailDeferredChannelReload")
	Begin := _DriverFuncBodyOrEmpty("_Updater_BeginDeferredChannelReload")
	DefaultReload := _DriverFuncBodyOrEmpty("_Updater_DefaultChannelReload")
	Assert(RunBody != "" and Quiescent != "" and Fail != ""
		and Begin != "" and DefaultReload != "",
		"the exact deferred Reload runner, quiescence predicate and failure path must exist")
	Assert(InStr(DefaultReload,
		"ReloadPreservingSuspend(0, ConfigBundle)") > 0
		and InStr(Begin,
			"_Updater_DefaultChannelReload.Bind(ConfigBundle)") > 0,
		"the live Reload helper must borrow rather than reacquire the retained global bundle")
	Assert(InStr(Quiescent, "_UpdaterAsyncRequests.Count == 0") > 0
		and InStr(Quiescent, "_UpdaterActiveSendLeaseCount == 0") > 0
		and InStr(Quiescent, "_UpdaterActiveAsyncTerminalDeliveryCount == 0") > 0,
		"Reload quiescence requires an empty registry plus zero COM leases and zero terminal callbacks")
	QuiescentAt := InStr(RunBody, "_Updater_ChannelReloadQuiescent()")
	ReloadAt := InStr(RunBody, "State.ReloadFn.Call()", , QuiescentAt)
	Assert(QuiescentAt > 0 and ReloadAt > QuiescentAt,
		"only the current timer continuation may Reload after full quiescence")
	Assert(InStr(RunBody, "State.ConfigBundle", , ReloadAt) > ReloadAt
		and InStr(Fail, "State.ConfigBundle") > 0,
		"both accepted Reload and refusal recovery must retain the exact global configuration bundle")
	Assert(InStr(RunBody, "TickExpired(") > 0
		and InStr(RunBody, "channel reload quiescence timed out") > 0,
		"the quiescence wait must have a wrap-safe bounded timeout")
	Assert(InStr(Fail, "LoggerError(") > 0
		and InStr(Fail,
			'_Updater_SurfaceFailure("updater.channel_transition_failed"') > 0
		and InStr(Fail, "_Updater_InvokeChannelRecovery(") > 0
		and InStr(Fail, "RecoverFn.Call(") == 0
		and InStr(Fail, "_Updater_EndAsyncAdmissionBoundary(") == 0,
		"timeout/reload failure must delegate visible recovery to the atomic boundary-to-lease handoff")
}
Test("updater AHK-31: deferred Reload requires full quiescence and recovery (updater-channel-replacement-transaction)",
	_USCA_DeferredReloadRequiresFullQuiescence)

_USCA_ChannelEpochRejectsABA() {
	Builder := _DriverFuncBody("_Updater_NewRequestContext")
	Validator := _DriverFuncBody("_Updater_RequestContextValid")
	Policy := _DriverFuncBody("_Updater_RequestPolicy")
	Assert(InStr(Builder, "Channel:") > 0 and InStr(Builder, "ChannelEpoch:") > 0
		and InStr(Validator, 'HasProp("Channel")') > 0
		and InStr(Validator, 'HasProp("ChannelEpoch")') > 0
		and InStr(Policy, "Request.ChannelEpoch != _UpdaterChannelEpoch") > 0,
		"immutable channel identity plus monotone epoch must reject main-dev-main ABA work")
}
Test("updater AHK-31: request provenance owns channel epoch (updater-channel-replacement-transaction)",
	_USCA_ChannelEpochRejectsABA)

_USCA_BackgroundTimerUsesExactOwnerEpoch() {
	Start := _DriverFuncBody("Updater_StartBackgroundChecks")
	Stop := _DriverFuncBody("Updater_StopBackgroundChecks")
	Tick := _DriverFuncBody("Updater_BackgroundTick")
	MayDispatch := _DriverFuncBody("_Updater_BackgroundMayDispatch")
	Arm := _DriverFuncBody("_Updater_ArmBackgroundOwner")
	Assert(Start != "" and Stop != "" and Tick != "" and MayDispatch != ""
		and Arm != "",
		"the background cadence lifecycle must remain source-visible")
	Assert(InStr(Start, "_UpdaterAsyncAdmissionBoundary") > 0
		and InStr(Start, "IsObject(_UpdaterAsyncAdmissionBoundary)") > 0
		and InStr(Arm, "IsObject(_UpdaterAsyncAdmissionBoundary)") > 0
		and InStr(MayDispatch, "IsObject(_UpdaterAsyncAdmissionBoundary)") > 0,
		"channel replacement must prevent both producer publication and a yielded timer arm")
	Assert(InStr(Start, "_UpdaterBackgroundOwner") > 0
		and InStr(Start, "_Updater_ArmBackgroundOwner(") > 0,
		"Start must publish one exact owner before arming its timer")
	Assert(InStr(Tick, "ArmEpoch") > 0
		and InStr(Tick, "ObjPtr(Owner)") > 0,
		"each timer callback must carry immutable owner and arm identities")
	ExactRetireAt := InStr(Tick, "if Updater_StopBackgroundChecks(false, Owner)")
	RearmErrorAt := InStr(Tick, "LoggerError(", , ExactRetireAt)
	Assert(ExactRetireAt > 0 and RearmErrorAt > ExactRetireAt,
		"an interrupted old tick may retire only its own owner, never a Stop-Start successor")
	UnpublishFnAt := InStr(Stop, "_UpdaterBackgroundFn := unset")
	UnpublishOwnerAt := InStr(Stop, "_UpdaterBackgroundOwner := 0")
	DisarmAt := InStr(Stop, "_Updater_BackgroundSchedule(")
	Assert(UnpublishFnAt > 0 and UnpublishOwnerAt > UnpublishFnAt
		and DisarmAt > UnpublishOwnerAt,
		"Stop must unpublish the exact producer before a yielding timer disarm")
	Assert(InStr(MayDispatch, "ExpectedOwner") > 0
		and InStr(MayDispatch, "ObjPtr(ExpectedOwner)") > 0,
		"dispatch must reject a queued callback from an older Stop-Start epoch")
	TraceAt := InStr(Stop, "LoggerTrace(")
	DisarmGuardAt := InStr(Stop, "if Stopped and IsObject(TimerFn)")
	DoneAt := InStr(Stop, "LoggerDone(")
	Assert(TraceAt > 0 and DisarmGuardAt > TraceAt and DoneAt > DisarmGuardAt,
		"a successful background Stop must keep its TRACE/DONE lifecycle pair")
}
Test("updater AHK-31: background cadence owns exact timer epochs (updater-background-owner-epoch)",
	_USCA_BackgroundTimerUsesExactOwnerEpoch)

_USCA_CountOccurrences(Haystack, Needle) {
	Count := 0
	Pos := 1
	while Pos := InStr(Haystack, Needle, , Pos) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}

_USCA_RecoveryHandoffIsAtomicAndClassWide() {
	SetChannel := _DriverFuncBody("Updater_SetChannel")
	Fail := _DriverFuncBody("_Updater_FailDeferredChannelReload")
	Invoke := _DriverFuncBody("_Updater_InvokeChannelRecovery")
	Handoff := _DriverFuncBody("_Updater_HandoffAdmissionToActionLease")
	Assert(SetChannel != "" and Fail != "" and Invoke != "" and Handoff != "",
		"channel recovery and its exact handoff helpers must remain source-visible")
	Assert(_USCA_CountOccurrences(SetChannel,
		"_Updater_InvokeChannelRecovery(") >= 3
		and InStr(SetChannel,
			"_Updater_RecoverCommittedChannelTransition(") == 0
		and InStr(Fail, "_Updater_InvokeChannelRecovery(") > 0,
		"every precommit, postcommit, refused-handoff and deferred-failure route must use central recovery")
	Assert(InStr(Invoke, "_Updater_HandoffAdmissionToActionLease(") > 0,
		"central recovery must hand the exact boundary to action ownership")
	CriticalAt := InStr(Handoff, 'Critical("On")')
	LeaseAt := InStr(Handoff, "_UpdaterAsyncActionLeases[Owner.Id] := Owner")
	OpenAt := InStr(Handoff, "_UpdaterAsyncAdmissionBoundary := 0")
	RestoreAt := InStr(Handoff, "Critical(PreviousCritical")
	AtomicSpan := (CriticalAt > 0 and RestoreAt > CriticalAt)
		? SubStr(Handoff, CriticalAt, RestoreAt - CriticalAt) : ""
	Assert(CriticalAt > 0 and LeaseAt > CriticalAt and OpenAt > LeaseAt
		and RestoreAt > OpenAt
		and _USCA_CountOccurrences(AtomicSpan, "Critical(") == 1,
		"boundary-to-recovery handoff must publish the exact lease before reopening admission in one Critical span")
}
Test("updater AHK-31: recovery handoff is atomic and class-wide (updater-channel-replacement-transaction)",
	_USCA_RecoveryHandoffIsAtomicAndClassWide)

_USCA_ActionAdmissionIsExclusive() {
	Acquire := _DriverFuncBody("_Updater_AcquireAsyncActionLease")
	BeginBoundary := _DriverFuncBody("_Updater_BeginAsyncAdmissionBoundary")
	Assert(Acquire != "" and BeginBoundary != "",
		"action and channel admission helpers must remain defined")
	Assert(InStr(Acquire, "_UpdaterAsyncActionLeases.Count > 0") > 0,
		"a second updater action must be refused while an exact sibling lease is live")
	Assert(InStr(BeginBoundary, "_UpdaterAsyncActionLeases.Count == 0") > 0,
		"channel admission must be mutually exclusive with every updater action lease")
}
Test("updater AHK-31: updater action admission is exclusive (updater-channel-replacement-transaction)",
	_USCA_ActionAdmissionIsExclusive)
