; tests/unit/modules/updater/test_updater_request_pause.ahk

; ==============================================================================
; MODULE: Updater Request Pause Contract
; DESCRIPTION:
; AHK-14: an updater request born before or after a pause refuses, drops or
; cancels with exactly one visible terminal, outside Critical.
; ==============================================================================

#Requires AutoHotkey v2.0





class _UpdaterTestReadyHttp {
	__New() {
		this.Status := 200
		this.ResponseText := '{"tag_name":"v9.9.9"}'
	}

	WaitForResponse(*) {
		return true
	}

	GetResponseHeader(*) {
		return ""
	}
}

_UpdaterTest_SaveRequestState() {
	global _UpdaterAsyncRequests, _UpdaterAsyncCounter, _UpdaterRequestCounter
	global _UpdaterActiveSendLeaseCount, _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterAsyncAdmissionBoundary
	global _UpdaterAsyncActionLeases, _UpdaterAsyncActionLeaseCounter
	global _UpdaterChannelReloadTransition, _UpdaterChannelReloadCounter
	global _UpdaterChannelEpoch, UPDATER_CHANNEL
	global _UpdaterPauseGeneration, _UpdaterPendingManualPauseNoticeCount
	global _UpdaterPendingManualPauseNoticeIds
	global _UpdaterBackgroundGeneration
	global _UpdaterMenuRebuildPending, _UpdaterPendingReleaseNotification
	return {
		Requests: _UpdaterAsyncRequests,
		Counter: _UpdaterAsyncCounter,
		SendLeaseCount: IsSet(_UpdaterActiveSendLeaseCount)
			? _UpdaterActiveSendLeaseCount
			: 0,
		HadTerminalDeliveryCount: IsSet(_UpdaterActiveAsyncTerminalDeliveryCount),
		TerminalDeliveryCount: IsSet(_UpdaterActiveAsyncTerminalDeliveryCount)
			? _UpdaterActiveAsyncTerminalDeliveryCount
			: 0,
		HadAdmissionBoundary: IsSet(_UpdaterAsyncAdmissionBoundary),
		AdmissionBoundary: IsSet(_UpdaterAsyncAdmissionBoundary)
			? _UpdaterAsyncAdmissionBoundary
			: 0,
		HadActionLeases: IsSet(_UpdaterAsyncActionLeases),
		ActionLeases: IsSet(_UpdaterAsyncActionLeases)
			? _UpdaterAsyncActionLeases
			: Map(),
		HadActionLeaseCounter: IsSet(_UpdaterAsyncActionLeaseCounter),
		ActionLeaseCounter: IsSet(_UpdaterAsyncActionLeaseCounter)
			? _UpdaterAsyncActionLeaseCounter
			: 0,
		HadChannelReloadTransition: IsSet(_UpdaterChannelReloadTransition),
		ChannelReloadTransition: IsSet(_UpdaterChannelReloadTransition)
			? _UpdaterChannelReloadTransition
			: 0,
		HadChannelReloadCounter: IsSet(_UpdaterChannelReloadCounter),
		ChannelReloadCounter: IsSet(_UpdaterChannelReloadCounter)
			? _UpdaterChannelReloadCounter
			: 0,
		HadChannelEpoch: IsSet(_UpdaterChannelEpoch),
		ChannelEpoch: IsSet(_UpdaterChannelEpoch) ? _UpdaterChannelEpoch : 1,
		Channel: UPDATER_CHANNEL,
		RequestCounter: _UpdaterRequestCounter,
		Generation: _UpdaterPauseGeneration,
		BackgroundGeneration: _UpdaterBackgroundGeneration,
		PendingNoticeCount: _UpdaterPendingManualPauseNoticeCount,
		PendingNoticeIds: _UpdaterPendingManualPauseNoticeIds,
		MenuRebuildPending: _UpdaterMenuRebuildPending,
		PendingReleaseNotification: _UpdaterPendingReleaseNotification
	}
}

_UpdaterTest_ResetRequestState() {
	global _UpdaterAsyncRequests, _UpdaterAsyncCounter, _UpdaterRequestCounter
	global _UpdaterActiveSendLeaseCount, _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterAsyncAdmissionBoundary
	global _UpdaterAsyncActionLeases, _UpdaterAsyncActionLeaseCounter
	global _UpdaterChannelReloadTransition, _UpdaterChannelReloadCounter
	global _UpdaterChannelEpoch, UPDATER_CHANNEL
	global _UpdaterPauseGeneration, _UpdaterPendingManualPauseNoticeCount
	global _UpdaterPendingManualPauseNoticeIds
	global _UpdaterBackgroundGeneration
	global _UpdaterMenuRebuildPending, _UpdaterPendingReleaseNotification
	_UpdaterAsyncRequests := Map()
	_UpdaterAsyncCounter := 0
	_UpdaterActiveSendLeaseCount := 0
	_UpdaterActiveAsyncTerminalDeliveryCount := 0
	_UpdaterAsyncAdmissionBoundary := 0
	_UpdaterAsyncActionLeases := Map()
	_UpdaterAsyncActionLeaseCounter := 0
	_UpdaterChannelReloadTransition := 0
	_UpdaterChannelReloadCounter := 0
	_UpdaterChannelEpoch := 1
	UPDATER_CHANNEL := "main"
	_UpdaterRequestCounter := 0
	_UpdaterPauseGeneration := 1
	_UpdaterBackgroundGeneration := 1
	_UpdaterPendingManualPauseNoticeCount := 0
	_UpdaterPendingManualPauseNoticeIds := Map()
	_UpdaterMenuRebuildPending := false
	_UpdaterPendingReleaseNotification := 0
}

_UpdaterTest_CleanupTransientConfigBundles(Saved) {
	global _UpdaterChannelReloadTransition, _UpdaterAsyncActionLeases
	SavedBundles := Map()
	if (Saved.HadChannelReloadTransition
		and IsObject(Saved.ChannelReloadTransition)
		and Saved.ChannelReloadTransition.HasOwnProp("ConfigBundle")
		and IsObject(Saved.ChannelReloadTransition.ConfigBundle))
		SavedBundles[ObjPtr(Saved.ChannelReloadTransition.ConfigBundle)] := true
	if Saved.HadActionLeases {
		for _, Owner in Saved.ActionLeases {
			if IsObject(Owner) and Owner.HasOwnProp("ConfigBundle")
				and IsObject(Owner.ConfigBundle)
				SavedBundles[ObjPtr(Owner.ConfigBundle)] := true
		}
	}
	Candidates := []
	if (IsSet(_UpdaterChannelReloadTransition)
		and IsObject(_UpdaterChannelReloadTransition)
		and _UpdaterChannelReloadTransition.HasOwnProp("ConfigBundle"))
		Candidates.Push(_UpdaterChannelReloadTransition.ConfigBundle)
	if IsSet(_UpdaterAsyncActionLeases) {
		for _, Owner in _UpdaterAsyncActionLeases {
			if IsObject(Owner) and Owner.HasOwnProp("ConfigBundle")
				Candidates.Push(Owner.ConfigBundle)
		}
	}
	for Bundle in Candidates {
		if IsObject(Bundle) and !SavedBundles.Has(ObjPtr(Bundle))
			_Updater_ReleaseChannelConfigBundle(Bundle)
	}
}

_UpdaterTest_RestoreRequestState(Saved) {
	global _UpdaterAsyncRequests, _UpdaterAsyncCounter, _UpdaterRequestCounter
	global _UpdaterActiveSendLeaseCount, _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterAsyncAdmissionBoundary
	global _UpdaterAsyncActionLeases, _UpdaterAsyncActionLeaseCounter
	global _UpdaterChannelReloadTransition, _UpdaterChannelReloadCounter
	global _UpdaterChannelEpoch, UPDATER_CHANNEL
	global _UpdaterPauseGeneration, _UpdaterPendingManualPauseNoticeCount
	global _UpdaterPendingManualPauseNoticeIds
	global _UpdaterBackgroundGeneration
	global _UpdaterMenuRebuildPending, _UpdaterPendingReleaseNotification
	_UpdaterTest_CleanupTransientConfigBundles(Saved)
	_UpdaterAsyncRequests := Saved.Requests
	_UpdaterAsyncCounter := Saved.Counter
	_UpdaterActiveSendLeaseCount := Saved.SendLeaseCount
	if Saved.HadTerminalDeliveryCount
		_UpdaterActiveAsyncTerminalDeliveryCount := Saved.TerminalDeliveryCount
	else
		_UpdaterActiveAsyncTerminalDeliveryCount := unset
	if Saved.HadAdmissionBoundary
		_UpdaterAsyncAdmissionBoundary := Saved.AdmissionBoundary
	else
		_UpdaterAsyncAdmissionBoundary := unset
	if Saved.HadActionLeases
		_UpdaterAsyncActionLeases := Saved.ActionLeases
	else
		_UpdaterAsyncActionLeases := unset
	if Saved.HadActionLeaseCounter
		_UpdaterAsyncActionLeaseCounter := Saved.ActionLeaseCounter
	else
		_UpdaterAsyncActionLeaseCounter := unset
	if Saved.HadChannelReloadTransition
		_UpdaterChannelReloadTransition := Saved.ChannelReloadTransition
	else
		_UpdaterChannelReloadTransition := unset
	if Saved.HadChannelReloadCounter
		_UpdaterChannelReloadCounter := Saved.ChannelReloadCounter
	else
		_UpdaterChannelReloadCounter := unset
	if Saved.HadChannelEpoch
		_UpdaterChannelEpoch := Saved.ChannelEpoch
	else
		_UpdaterChannelEpoch := unset
	UPDATER_CHANNEL := Saved.Channel
	_UpdaterRequestCounter := Saved.RequestCounter
	_UpdaterPauseGeneration := Saved.Generation
	_UpdaterBackgroundGeneration := Saved.BackgroundGeneration
	_UpdaterPendingManualPauseNoticeCount := Saved.PendingNoticeCount
	_UpdaterPendingManualPauseNoticeIds := Saved.PendingNoticeIds
	_UpdaterMenuRebuildPending := Saved.MenuRebuildPending
	_UpdaterPendingReleaseNotification := Saved.PendingReleaseNotification
}

_UpdaterTest_RecordRequestTerminal(State, IsSuspended, Json, Request) {
	State.TerminalCount += 1
	if _Updater_RequestMayPublish(Request, IsSuspended)
		State.PublishCount += 1
}

_UpdaterTest_RecordResumeNotice(State, Message, Options) {
	State.Count += 1
	State.Message := Message
	State.Options := Options
}

_UpdaterTest_RecordCriticalResumeNotice(State, Message, Options) {
	State.Count += 1
	State.CriticalStates.Push(A_IsCritical)
}

_UpdaterTest_PausedTrayClickRefusesBeforeUpdaterWork() {
	State := { NotifyCount: 0, ContinueCount: 0, ShowCount: 0 }
	NotifyFn := (Message, Options) => (State.NotifyCount += 1)
	ContinueFn := () => (State.ContinueCount += 1)
	ShowFn := () => (
		State.ShowCount += 1,
		_Updater_ShowAvailableUpdateEntry(true, NotifyFn, ContinueFn))

	; The click answers the updater's own balloon: only that one routes.
	_Updater_ClaimBalloon()
	_Updater_OnTrayMsg(0, 0x405, 0x404, 0, ShowFn)
	AssertEqual(1, State.ShowCount,
		"a genuine balloon click must reach the updater policy boundary while paused")
	AssertEqual(1, State.NotifyCount,
		"a born-paused manual action must receive exactly one visible refusal")
	AssertEqual(0, State.ContinueCount,
		"born-paused work must stop before prompt, cache, or HTTP continuation")

	_Updater_OnTrayMsg(0, 0x406, 0x404, 0, ShowFn)
	AssertEqual(1, State.ShowCount,
		"non-balloon tray messages must not enter updater policy or produce output")
}
Test("Updater AHK-14: paused notification click refuses visibly before work",
	_UpdaterTest_PausedTrayClickRefusesBeforeUpdaterWork)

_UpdaterTest_MalformedProvenanceFailsClosed() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_REQUEST_POLICY_DROP
	Malformed := [
		0,
		{},
		{ RequestId: 0, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: 0, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: "0", Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: {}, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: -1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: -1, Channel: "main", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "beta", ChannelEpoch: 1 },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main" },
		{ RequestId: 1, PauseTerminalState: { Claimed: false }, Origin: UPDATER_REQUEST_ORIGIN_MANUAL, BornSuspended: false, Generation: 1, BackgroundGeneration: 1, Channel: "main", ChannelEpoch: 0 }
	]
	for _, Request in Malformed {
		AssertEqual(false, _Updater_RequestContextValid(Request),
			"malformed updater provenance must fail validation without a property-read exception")
		AssertEqual(UPDATER_REQUEST_POLICY_DROP, _Updater_RequestPolicy(Request, false),
			"malformed updater provenance must fail closed at the shared publication policy")
	}
}
Test("Updater AHK-14: malformed request provenance fails closed",
	_UpdaterTest_MalformedProvenanceFailsClosed)

_UpdaterTest_ManualBornPausedRefusesBeforeOwnership() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_REQUEST_POLICY_DROP
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, true)
		State := { TerminalCount: 0, PublishCount: 0 }
		OnJson := (Json, CompletedRequest, Terminal := 0) => _UpdaterTest_RecordRequestTerminal(
			State, true, Json, CompletedRequest)
		Id := _Updater_RegisterAsyncRequest(
			_UpdaterTestReadyHttp(), "main", OnJson, "test://latest", Request)
		AssertEqual(UPDATER_REQUEST_POLICY_DROP, _Updater_RequestPolicy(Request, false),
			"manual-born-paused provenance must fail closed even after resume")
		AssertEqual(0, Id,
			"manual-born-paused work must never acquire async transport ownership")
		AssertEqual(0, State.TerminalCount,
			"a refused manual action must not manufacture an async completion")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: manual-born-paused action refuses before async ownership",
	_UpdaterTest_ManualBornPausedRefusesBeforeOwnership)

_UpdaterTest_BackgroundBornRunningDropsAtPause() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterPendingManualPauseNoticeCount
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		State := { TerminalCount: 0, PublishCount: 0 }
		OnJson := (Json, CompletedRequest, Terminal := 0) => _UpdaterTest_RecordRequestTerminal(
			State, true, Json, CompletedRequest)
		Id := _Updater_RegisterAsyncRequest(
			_UpdaterTestReadyHttp(), "main", OnJson, "test://latest", Request)
		Assert(Id > 0, "background-born-running request must be registered before pause")

		_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
		_Updater_PollAsync(Id)

		AssertEqual(1, State.TerminalCount,
			"suspend cancellation must terminally release background ownership exactly once")
		AssertEqual(0, State.PublishCount,
			"background request born running must not publish after pause")
		AssertEqual(0, _UpdaterPendingManualPauseNoticeCount,
			"background cancellation must remain silent rather than queue manual feedback")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: background-born-running request drops after pause",
	_UpdaterTest_BackgroundBornRunningDropsAtPause)

_UpdaterTest_ManualBornRunningGetsOneResumeTerminal() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterPendingManualPauseNoticeCount
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		State := { TerminalCount: 0, PublishCount: 0 }
		OnJson := (Json, CompletedRequest, Terminal := 0) => _UpdaterTest_RecordRequestTerminal(
			State, true, Json, CompletedRequest)
		Id := _Updater_RegisterAsyncRequest(
			_UpdaterTestReadyHttp(), "main", OnJson, "test://latest", Request)
		Assert(Id > 0, "manual-born-running request must be registered before pause")

		_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
		_Updater_PollAsync(Id)
		AssertEqual(1, State.TerminalCount,
			"manual request interrupted by pause must release callback ownership exactly once")
		AssertEqual(0, State.PublishCount,
			"manual request born running must not mutate UI while a later pause is active")
		AssertEqual(1, _UpdaterPendingManualPauseNoticeCount,
			"manual cancellation must queue a visible resume terminal instead of disappearing")

		Notice := { Count: 0, Message: "", Options: 0 }
		NotifyFn := (Message, Options) => _UpdaterTest_RecordResumeNotice(Notice, Message, Options)
		AssertEqual(true, Updater_OnSuspendResume(NotifyFn),
			"first resume must surface the deferred manual cancellation")
		AssertEqual(false, Updater_OnSuspendResume(NotifyFn),
			"second resume must not replay an already-consumed terminal")
		AssertEqual(1, Notice.Count,
			"manual request cancellation must produce exactly one visible resume notice")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: manual-born-running request cancels with one resume terminal",
	_UpdaterTest_ManualBornRunningGetsOneResumeTerminal)

_UpdaterTest_ManualPauseTerminalDeduplicatesByRequest() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterPauseGeneration
	global _UpdaterPendingManualPauseNoticeCount, _UpdaterPendingManualPauseNoticeIds
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_UpdaterPauseGeneration += 1

		AssertEqual(false, _Updater_RequestMayPublish(Request, true),
			"the first paused delivery must reject publication")
		AssertEqual(false, _Updater_RequestMayPublish(Request, true),
			"a duplicate delivery of the same immutable request must also reject publication")
		AssertEqual(1, _UpdaterPendingManualPauseNoticeCount,
			"duplicate callbacks carrying one request identity must retain one terminal, not two")
		AssertEqual(1, _UpdaterPendingManualPauseNoticeIds.Count,
			"the atomic pending-id registry must own exactly one request identity")

		Notice := { Count: 0, Message: "", Options: 0 }
		NotifyFn := (Message, Options) => _UpdaterTest_RecordResumeNotice(Notice, Message, Options)
		AssertEqual(true, Updater_OnSuspendResume(NotifyFn, false),
			"resume must surface the sole retained terminal")
		AssertEqual(false, _Updater_RequestMayPublish(Request, false),
			"a duplicate callback delivered after resume must remain terminally rejected")
		AssertEqual(0, _UpdaterPendingManualPauseNoticeCount,
			"a drained request-scoped claim must prevent a late duplicate from requeueing")
		AssertEqual(false, Updater_OnSuspendResume(NotifyFn, false),
			"a second resume must not replay the drained request identity")
		AssertEqual(1, Notice.Count,
			"one immutable request may produce at most one visible pause terminal")
		AssertEqual(0, _UpdaterPendingManualPauseNoticeCount,
			"draining must clean the bounded pending-id registry and its public count")
		AssertEqual(0, _UpdaterPendingManualPauseNoticeIds.Count,
			"draining must release every deduplication identity")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: duplicate callbacks retain one resume terminal per request",
	_UpdaterTest_ManualPauseTerminalDeduplicatesByRequest)

_UpdaterTest_ChangelogPauseTerminalRunsOutsideCritical() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterPauseGeneration
	global _CLW_WindowEpoch, _CLW_RequestEpoch
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedWindowEpoch := _CLW_WindowEpoch
	SavedRequestEpoch := _CLW_RequestEpoch
	try {
		_UpdaterTest_ResetRequestState()
		_CLW_WindowEpoch := 101
		_CLW_RequestEpoch := 202
		Notice := { Count: 0, CriticalStates: [] }
		NotifyFn := (Message, Options) => _UpdaterTest_RecordCriticalResumeNotice(
			Notice, Message, Options)

		EvalRequest := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_UpdaterPauseGeneration += 1
		EvalContext := {
			WindowEpoch: _CLW_WindowEpoch,
			RequestEpoch: _CLW_RequestEpoch,
			Request: EvalRequest
		}
		AssertEqual(false, _CLW_Eval("void 0", EvalContext, NotifyFn),
			"a stale changelog page mutation must be rejected")

		ScriptRequest := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_UpdaterPauseGeneration += 1
		Work := {
			Js: "void 0",
			WindowEpoch: _CLW_WindowEpoch,
			RequestEpoch: _CLW_RequestEpoch,
			Request: ScriptRequest
		}
		_CLW_RunScript(Work, NotifyFn)

		AssertEqual(2, Notice.Count,
			"both changelog deferred boundaries must preserve one visible pause terminal")
		AssertEqual(0, Notice.CriticalStates[1],
			"_CLW_Eval must restore Critical before the notifier seam runs")
		AssertEqual(0, Notice.CriticalStates[2],
			"_CLW_RunScript must restore Critical before the notifier seam runs")
	} finally {
		_CLW_WindowEpoch := SavedWindowEpoch
		_CLW_RequestEpoch := SavedRequestEpoch
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-14: changelog pause terminals run outside Critical",
	_UpdaterTest_ChangelogPauseTerminalRunsOutsideCritical)

_UpdaterTest_ActivationPropagatesInstallStartResult() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Release := { Tag: "v9.9.9" }
		State := { InstallCount: 0, SuccessCount: 0 }
		RefuseInstall := (Candidate) => (
			State.InstallCount += 1,
			false)
		AcceptInstall := (Candidate) => (
			State.InstallCount += 1,
			true)
		SuccessFn := (Tag) => (State.SuccessCount += 1)

		AssertEqual(false, _Updater_ActivateCachedRelease(
			Release, Request, false, 0, RefuseInstall, SuccessFn),
			"a refused staging start must propagate false to the one-click lifecycle")
		AssertEqual(1, State.InstallCount,
			"the refused install seam must be invoked exactly once")
		AssertEqual(0, State.SuccessCount,
			"a refused staging start must not emit a misleading installing success")

		AssertEqual(true, _Updater_ActivateCachedRelease(
			Release, Request, false, 0, AcceptInstall, SuccessFn),
			"an accepted staging start must propagate true")
		AssertEqual(2, State.InstallCount,
			"the accepted install seam must be invoked exactly once")
		AssertEqual(1, State.SuccessCount,
			"only the accepted staging start may emit installing success")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-14: cached activation reports the real staging-start result",
	_UpdaterTest_ActivationPropagatesInstallStartResult)
