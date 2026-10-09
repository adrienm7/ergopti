; tests/meta/test_updater_callback_suspend_guard.ahk

; ==============================================================================
; MODULE: Updater Async Request Provenance Meta Test
; DESCRIPTION:
; Regression guard ensuring updater producers capture immutable origin and
; suspend-generation provenance, then terminal callbacks apply the shared
; publication policy before UI or install operations.
;
; A raw terminal A_IsSuspended guard conflates manual work born paused, which
; needs immediate visible refusal, with work interrupted later, which must keep
; one terminal for resume. Immutable request context distinguishes those cases.
;
; SCOPE: source introspection of the core updater producers and callbacks plus
; the existing changelog bridge/fetch flow.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_UCSG_CoreOwnsImmutableRequestPolicy() {
	Builder := _DriverFuncBody("_Updater_NewRequestContext")
	Validator := _DriverFuncBody("_Updater_RequestContextValid")
	Policy := _DriverFuncBody("_Updater_RequestPolicy")
	Publisher := _DriverFuncBody("_Updater_RequestMayPublish")
	BridgeReader := _DriverFuncBody("_Updater_ReadManualBridgeMessage")
	Resume := _DriverFuncBody("Updater_OnSuspendResume")
	Assert(Builder != "" and Validator != "" and Policy != ""
		and Publisher != "" and BridgeReader != "" and Resume != "",
		"AHK-14 request provenance helpers must all remain defined")

	Assert(InStr(Builder, "RequestId:") > 0
		and InStr(Builder, "PauseTerminalState:") > 0
		and InStr(Builder, "Origin:") > 0
		and InStr(Builder, "BornSuspended:") > 0
		and InStr(Builder, "Generation:") > 0
		and InStr(Builder, "Channel:") > 0
		and InStr(Builder, "ChannelEpoch:") > 0,
		"request creation must capture immutable identity/provenance plus one request-scoped terminal claim")
	ObjectGate := InStr(Validator, 'Type(Request) != "Object"')
	IdentityGate := InStr(Validator, 'HasProp("RequestId")')
	OriginGate := InStr(Validator, 'HasProp("Origin")')
	BornGate := InStr(Validator, 'HasProp("BornSuspended")')
	GenerationGate := InStr(Validator, 'HasProp("Generation")')
	ChannelGate := InStr(Validator, 'HasProp("Channel")')
	ChannelEpochGate := InStr(Validator, 'HasProp("ChannelEpoch")')
	FirstRead := InStr(Validator, "Origin := Request.Origin")
	Assert(ObjectGate > 0 and IdentityGate > ObjectGate and OriginGate > IdentityGate and BornGate > OriginGate
		and GenerationGate > BornGate and ChannelGate > GenerationGate
		and ChannelEpochGate > ChannelGate and FirstRead > ChannelEpochGate,
		"malformed callback provenance must fail closed before any property read")

	ValidateAt := InStr(Policy, "_Updater_RequestContextValid(Request)")
	BornAt := InStr(Policy, "Request.BornSuspended", , ValidateAt)
	BackgroundAt := InStr(Policy, "UPDATER_REQUEST_ORIGIN_BACKGROUND", , ValidateAt)
	Assert(ValidateAt > 0 and BornAt > ValidateAt and BackgroundAt > ValidateAt,
		"the shared policy must validate first, visibly refuse born-paused manual work and silently drop background work")
	Assert(InStr(Policy, "Request.ChannelEpoch != _UpdaterChannelEpoch", , ValidateAt) > 0,
		"request publication policy must reject stale channel epochs even after A-B-A")
	Assert(InStr(Publisher, "_Updater_QueueManualPauseNotice(Request)") > 0,
		"interrupted manual work must retain one visible terminal instead of becoming a silent no-op")
	Assert(InStr(Resume, "_UpdaterPendingManualPauseNoticeIds") > 0,
		"resume must drain the exact deduplicated request identities")
	ReadAt := InStr(BridgeReader, "ReadFn.Call()")
	CatchAt := ReadAt > 0 ? InStr(BridgeReader, "catch as Err", , ReadAt) : 0
	LogAt := CatchAt > 0 ? InStr(BridgeReader, "LoggerError(", , CatchAt) : 0
	Assert(ReadAt > 0 and CatchAt > ReadAt and LogAt > CatchAt,
		"a yielding bridge read failure must stay fail-closed and reach the file logger")
}
Test("meta updater AHK-14: core owns immutable visible pause policy",
	_UCSG_CoreOwnsImmutableRequestPolicy)

_UCSG_DurableUpdaterSettingsFinishPublication() {
	Channel := _DriverFuncBody("Updater_SetChannel")
	ChannelGateAt := InStr(Channel, "_Updater_RequestMayPublish(")
	ConfigBundleAt := InStr(Channel,
		"_Updater_AcquireChannelConfigBundle()", , ChannelGateAt)
	BoundaryAt := InStr(Channel,
		"_Updater_BeginAsyncAdmissionBoundary(", , ConfigBundleAt)
	ChannelWriteAt := InStr(Channel,
		"ConfigCommitBorrowedUpdates(", , BoundaryAt)
	ChannelPublishAt := InStr(Channel,
		"UPDATER_CHANNEL := Channel", , ChannelWriteAt)
	ChannelFinishAt := InStr(Channel, "_Updater_BeginDeferredChannelReload(", , ChannelPublishAt)
	ChannelAbortAfterWrite := InStr(Channel,
		"_Updater_RequestMayPublish(", , ChannelWriteAt)
	Assert(ChannelGateAt > 0 and ConfigBundleAt > ChannelGateAt
		and BoundaryAt > ConfigBundleAt and ChannelWriteAt > BoundaryAt
		and ChannelPublishAt > ChannelWriteAt
		and ChannelFinishAt > ChannelPublishAt and ChannelAbortAfterWrite == 0,
		"Updater_SetChannel must gate, own the global config bundle, commit through its borrowed owner and retain that bundle through deferred Reload")
	Assert(InStr(Channel, "ConfigBundle)", , ChannelFinishAt) > ChannelFinishAt,
		"the deferred channel owner must retain the same global configuration bundle")

	Interval := _DriverFuncBody("Updater_SetCheckInterval")
	IntervalGateAt := InStr(Interval, "_Updater_RequestMayPublish(")
	IntervalLeaseAt := InStr(Interval, "_Updater_AcquireAsyncActionLease(", , IntervalGateAt)
	IntervalCommitAt := InStr(Interval, "ConfigCommitBuilt(", , IntervalLeaseAt)
	IntervalFinallyAt := InStr(Interval, "finally", , IntervalCommitAt)
	IntervalReleaseAt := InStr(Interval, "_Updater_ReleaseAsyncActionLease(", , IntervalFinallyAt)
	IntervalAbortAfterWrite := InStr(Interval,
		"_Updater_RequestMayPublish(", , IntervalCommitAt)
	Assert(IntervalGateAt > 0 and IntervalLeaseAt > IntervalGateAt
		and IntervalCommitAt > IntervalLeaseAt
		and IntervalFinallyAt > IntervalCommitAt
		and IntervalReleaseAt > IntervalFinallyAt
		and IntervalAbortAfterWrite == 0,
		"Updater_SetCheckInterval must retain updater admission around the global owned commit and release only after native publication")
	Plan := _DriverFuncBody("_Updater_BuildCheckIntervalPlan")
	Finalize := _DriverFuncBody("_Updater_FinalizeCheckInterval")
	Publish := _DriverFuncBody("_Updater_PublishCheckInterval")
	Restore := _DriverFuncBody("_Updater_RestoreCheckInterval")
	Assert(Plan != "" and Finalize != "" and Publish != ""
		and Restore != "",
		"the check-interval candidate, native finalizer and compensation must remain source-visible")
	Assert(InStr(Plan, "rollback_updates:") > 0
		and InStr(Plan, "finalize:") > 0
		and InStr(Plan, "publish:") > 0
		and InStr(Plan, "compensate:") > 0,
		"the owned interval plan must encode durability, native handoff and exact rollback")
	Assert(InStr(Finalize, "Updater_StopBackgroundChecks()") > 0
		and InStr(Finalize, "Updater_StartBackgroundChecks()") > 0
		and InStr(Publish, "UPDATER_CHECK_INTERVAL := Seconds") > 0
		and InStr(Restore, "State.OldSeconds") > 0,
		"native cadence replacement must be strict and compensable")
}
Test("meta updater AHK-14: durable setting writes finish live publication",
	_UCSG_DurableUpdaterSettingsFinishPublication)

_UCSG_EveryUpdaterProducerCarriesAndRevalidatesProvenance() {
	Specs := [
		{ Producer: "Updater_BackgroundTick", Origin: "UPDATER_REQUEST_ORIGIN_BACKGROUND",
			Consumer: "_Updater_HandleBackgroundResult" },
		{ Producer: "Updater_OneClickUpdate", Origin: "UPDATER_REQUEST_ORIGIN_MANUAL",
			Consumer: "_Updater_OneClickUpdateCallback" },
		{ Producer: "_Updater_ShowAvailableUpdateRunning", Origin: "UPDATER_REQUEST_ORIGIN_MANUAL",
			Consumer: "_Updater_ShowAvailableUpdateCallback" }
	]
	Checked := 0
	for _, Spec in Specs {
		Producer := _DriverFuncBody(Spec.Producer)
		Consumer := _DriverFuncBody(Spec.Consumer)
		Assert(Producer != "" and Consumer != "",
			Spec.Producer . " and " . Spec.Consumer . " must both remain defined")
		CaptureAt := InStr(Producer, "_Updater_NewRequestContext(" . Spec.Origin . ")")
		FetchAt := InStr(Producer, "_Updater_FetchLatestJsonAsync(", , CaptureAt)
		PolicyAt := InStr(Consumer, "_Updater_RequestMayPublish(Request)")
		Assert(CaptureAt > 0 and FetchAt > CaptureAt and PolicyAt > 0,
			Spec.Producer . " must capture immutable origin before dispatch and "
			. Spec.Consumer . " must revalidate before publication")
		Checked += 1
	}
	AssertEqual(3, Checked, "all latest-release producers must participate in AHK-14 provenance")

	DownloadBody := _DriverFuncBody("Updater_DownloadAndInstall")
	ReserveBody := _DriverFuncBody(
		"_Updater_TryReserveDownloadTransaction")
	Cancel := _DriverFuncBody("_Updater_CancelSelfUpdateTransaction")
	Assert(DownloadBody != "" and ReserveBody != "" and Cancel != "",
		"the download producer, reservation helper and suspend cancellation owner must remain defined")
	PublicPolicyAt := InStr(DownloadBody,
		"_Updater_RequestMayPublish(Request")
	BeginAt := InStr(DownloadBody,
		"_Updater_BeginDownloadTransaction(", , PublicPolicyAt)
	ReservePolicyAt := InStr(ReserveBody,
		"_Updater_RequestPolicy(Request")
	OwnerAt := InStr(ReserveBody,
		"_UpdaterDownloadRequest := Request", , ReservePolicyAt)
	Assert(PublicPolicyAt > 0 and BeginAt > PublicPolicyAt
		and ReservePolicyAt > 0 and OwnerAt > ReservePolicyAt,
		"download ownership must retain only a request admitted by the shared AHK-14 policy")
	TakeAt := InStr(Cancel, "_UpdaterDownloadRequest := 0")
	TerminalAt := InStr(Cancel, "_Updater_RequestMayPublish(Request, true)", , TakeAt)
	Assert(TakeAt > 0 and TerminalAt > TakeAt,
		"suspend cancellation must take the download owner before queueing its one visible resume terminal")
}
Test("meta updater AHK-14: producers carry and revalidate request provenance",
	_UCSG_EveryUpdaterProducerCarriesAndRevalidatesProvenance)

_UCSG_ChangelogBridgeCapturesBeforeYieldAndThreadsRequest() {
	Bridge := _DriverFuncBody("_CLW_OnWebMessage")
	Fetch := _DriverFuncBody("_CLW_FetchAndInject")
	FetchContext := _DriverFuncBody("_CLW_BeginFetchRequest")
	Queue := _DriverFuncBody("_CLW_Eval")
	Current := _DriverFuncBody("_CLW_RequestIsCurrent")
	Assert(Bridge != "" and Fetch != "" and FetchContext != ""
		and Queue != "" and Current != "",
		"the changelog bridge, fetch context, queue and validity gate must remain defined")
	CaptureAt := InStr(Bridge, "_Updater_ReadManualBridgeMessage(")
	ReadAt := InStr(Bridge, "TryGetWebMessageAsString()", , CaptureAt)
	BornAt := InStr(Bridge, "Request.BornSuspended", , ReadAt)
	PolicyAt := InStr(Bridge, "_Updater_RequestMayPublish(Request)", , BornAt)
	FetchAt := InStr(Bridge, "_CLW_FetchAndInject(Ch, Request)", , PolicyAt)
	UrlAt := InStr(Bridge, "_Updater_OpenManualUrl(() => Url, Request)", , PolicyAt)
	Assert(CaptureAt > 0 and ReadAt > CaptureAt and BornAt > ReadAt
		and PolicyAt > BornAt and FetchAt > PolicyAt and UrlAt > PolicyAt,
		"bridge actions must preserve entry-time provenance across the yielding COM read and revalidate before both outputs")
	Assert(InStr(Fetch, "_CLW_BeginFetchRequest(Channel, Request, ExpectedWindowEpoch)") > 0
		and InStr(FetchContext, "Request: Request") > 0,
		"the deferred changelog fetch must carry its owning request in the callback context")
	Assert(InStr(Queue, "Request:") > 0,
		"deferred page work must retain the request that authorized it")
	Assert(InStr(Current, "_Updater_RequestMayPublish(Context.Request)") > 0,
		"every async changelog completion must revalidate request provenance")
}
Test("meta updater AHK-14: changelog bridge captures provenance before COM yield",
	_UCSG_ChangelogBridgeCapturesBeforeYieldAndThreadsRequest)

_UCSG_ChangelogCriticalSectionsUsePurePolicyOnly() {
	Specs := [
		{ Boundary: "_CLW_Eval", PureHelper: "_CLW_RequestEpochIsCurrent",
			ForbiddenHelper: "_CLW_RequestIsCurrent" },
		{ Boundary: "_CLW_RunScript", PureHelper: "_CLW_ScriptWorkEpochIsCurrent",
			ForbiddenHelper: "_CLW_ScriptWorkIsCurrent" }
	]
	for _, Spec in Specs {
		Body := _DriverFuncBody(Spec.Boundary)
		PureBody := _DriverFuncBody(Spec.PureHelper)
		Assert(Body != "" and PureBody != "",
			Spec.Boundary . " and its epoch-only helper must remain defined")
		CriticalAt := InStr(Body, 'Critical("On")')
		RestoreAt := InStr(Body, "Critical(PreviousCritical)", , CriticalAt)
		Assert(CriticalAt > 0 and RestoreAt > CriticalAt,
			Spec.Boundary . " must keep one short, balanced atomic capture")
		CriticalSpan := SubStr(Body, CriticalAt, RestoreAt - CriticalAt)
		Assert(InStr(CriticalSpan, "_Updater_RequestPolicy(") > 0
			and InStr(CriticalSpan, Spec.PureHelper . "(") > 0,
			Spec.Boundary . " must evaluate pure pause policy and epoch state atomically")
		Assert(InStr(CriticalSpan, Spec.ForbiddenHelper . "(") == 0
			and InStr(CriticalSpan, "_Updater_RequestMayPublish(") == 0
			and InStr(CriticalSpan, "Logger") == 0
			and InStr(CriticalSpan, "Notifier") == 0,
			Spec.Boundary . " must not reach a side-effecting policy, logger or notifier while Critical")
		Assert(InStr(PureBody, "_Updater_RequestMayPublish(") == 0
			and InStr(PureBody, "Logger") == 0
			and InStr(PureBody, "Notifier") == 0
			and InStr(PureBody, "Updater_OnSuspendResume(") == 0,
			Spec.PureHelper . " must stay transitively side-effect free under its caller's Critical span")
		TerminalAt := InStr(Body, "_Updater_RequestMayPublish(", , RestoreAt)
		Assert(TerminalAt > RestoreAt,
			Spec.Boundary . " must queue/log its pause terminal only after restoring Critical")
	}
}
Test("meta updater AHK-14: changelog Critical spans use pure policy only",
	_UCSG_ChangelogCriticalSectionsUsePurePolicyOnly)
