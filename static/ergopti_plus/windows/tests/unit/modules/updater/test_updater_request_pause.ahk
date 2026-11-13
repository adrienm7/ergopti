; tests/unit/modules/updater/test_updater_request_pause.ahk

; ==============================================================================
; MODULE: Updater Request Pause Contract
; DESCRIPTION:
; AHK-14, revised by UPD-2 (the maintainer's real pause): a background request
; born before or after a pause drops; a manual request runs and answers whatever
; the pause, as on macOS and Linux.
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

_UpdaterTest_PausedTrayClickContinues() {
	State := { ContinueCount: 0, ShowCount: 0 }
	ContinueFn := () => (State.ContinueCount += 1)
	ShowFn := () => (
		State.ShowCount += 1,
		_Updater_ShowAvailableUpdateEntry(ContinueFn))

	; The click answers the updater's own balloon: only that one routes.
	_Updater_ClaimBalloon()
	_Updater_OnTrayMsg(0, 0x405, 0x404, 0, ShowFn)
	AssertEqual(1, State.ShowCount, "a genuine balloon click reaches the updater")
	AssertEqual(1, State.ContinueCount,
		"a pause stops typing, not the prompt the user asks for (UPD-2)")

	_Updater_OnTrayMsg(0, 0x406, 0x404, 0, ShowFn)
	AssertEqual(1, State.ShowCount,
		"non-balloon tray messages must not enter updater policy or produce output")
}
Test("Updater UPD-2: a notification click continues while paused",
	_UpdaterTest_PausedTrayClickContinues)

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

_UpdaterTest_ManualBornPausedRuns() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_REQUEST_POLICY_ALLOW
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, true)
		State := { TerminalCount: 0, PublishCount: 0 }
		OnJson := (Json, CompletedRequest, Terminal := 0) => _UpdaterTest_RecordRequestTerminal(
			State, true, Json, CompletedRequest)
		AssertEqual(UPDATER_REQUEST_POLICY_ALLOW, _Updater_RequestPolicy(Request, true),
			"a manual check asked while paused runs, as on macOS and Linux (UPD-2)")
		Id := _Updater_RegisterAsyncRequest(
			_UpdaterTestReadyHttp(), "main", OnJson, "test://latest", Request)
		Assert(Id > 0, "the paused manual check takes its transport")
		_Updater_PollAsync(Id)
		AssertEqual(1, State.TerminalCount, "it completes once")
		AssertEqual(1, State.PublishCount, "and answers while the driver is still paused")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater UPD-2: a manual check asked while paused runs and answers",
	_UpdaterTest_ManualBornPausedRuns)

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

_UpdaterTest_ManualBornRunningSurvivesPause() {
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
		AssertEqual(0, State.TerminalCount, "the pause does not cancel a manual check (UPD-2)")
		_Updater_PollAsync(Id)
		AssertEqual(1, State.TerminalCount, "the manual check completes once")
		AssertEqual(1, State.PublishCount, "and answers during the pause")
		AssertEqual(0, _UpdaterPendingManualPauseNoticeCount, "no paused-request notice is queued")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater UPD-2: a pause keeps a manual check in flight and its answer",
	_UpdaterTest_ManualBornRunningSurvivesPause)

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

; UPD-2 leaves installs to a follow-up: the self-update transaction still stops
; at a pause, so an install asked while paused is refused visibly before it starts.
_UpdaterTest_InstallRefusedWhilePaused() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		State := { InstallCount: 0, NoticeCount: 0 }
		Install := (Candidate) => (State.InstallCount += 1, true)
		Notify := (Message, Options) => (State.NoticeCount += 1)
		AssertEqual(false, _Updater_ActivateCachedRelease({ Tag: "v9.9.9" }, Request, true, Notify, Install),
			"an install asked while paused is refused")
		AssertEqual(0, State.InstallCount, "nothing is staged")
		AssertEqual(1, State.NoticeCount, "the refusal is told once")
		AssertEqual(false, Updater_DownloadAndInstall({ RawJson: "{}", Tag: "v9.9.9" }, Request, true, 0, Notify),
			"the direct install refuses too")
		AssertEqual(2, State.NoticeCount, "and says so")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater UPD-2: an install asked while paused is refused visibly before it starts",
	_UpdaterTest_InstallRefusedWhilePaused)

_UpdaterTest_RecordResumeNotice(State, Message, Options) {
	State.Count += 1
	State.Message := Message
	State.Options := Options
}

; An install keeps the pause notice of AHK-14 (UPD-2 leaves installs pause-sensitive).
_UpdaterTest_ManualPauseTerminalDeduplicatesByRequest() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterPauseGeneration
	global _UpdaterPendingManualPauseNoticeCount, _UpdaterPendingManualPauseNoticeIds
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_UpdaterPauseGeneration += 1

		AssertEqual(false, _Updater_RequestMayPublish(Request, true, 0, true),
			"the first paused delivery must reject publication")
		AssertEqual(false, _Updater_RequestMayPublish(Request, true, 0, true),
			"a duplicate delivery of the same immutable request must also reject publication")
		AssertEqual(1, _UpdaterPendingManualPauseNoticeCount,
			"duplicate callbacks carrying one request identity must retain one terminal, not two")
		AssertEqual(1, _UpdaterPendingManualPauseNoticeIds.Count,
			"the atomic pending-id registry must own exactly one request identity")

		Notice := { Count: 0, Message: "", Options: 0 }
		NotifyFn := (Message, Options) => _UpdaterTest_RecordResumeNotice(Notice, Message, Options)
		AssertEqual(true, Updater_OnSuspendResume(NotifyFn, false),
			"resume must surface the sole retained terminal")
		AssertEqual(false, _Updater_RequestMayPublish(Request, false, 0, true),
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
Test("Updater AHK-14: duplicate install callbacks retain one resume terminal per request",
	_UpdaterTest_ManualPauseTerminalDeduplicatesByRequest)

; UPD-2: a manual request answers whatever the pause, while the install policy
; keeps the pause contract of AHK-14 for the self-update transaction.
_UpdaterTest_InstallPolicyKeepsPauseContract() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_REQUEST_ORIGIN_BACKGROUND, _UpdaterPauseGeneration
	global UPDATER_REQUEST_POLICY_ALLOW, UPDATER_REQUEST_POLICY_DROP, UPDATER_REQUEST_POLICY_NOTIFY
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Running := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Paused := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, true)
		Background := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		AssertEqual(UPDATER_REQUEST_POLICY_ALLOW, _Updater_InstallRequestPolicy(Running, false),
			"a running manual request may install")
		AssertEqual(UPDATER_REQUEST_POLICY_NOTIFY, _Updater_InstallRequestPolicy(Running, true),
			"a pause stops its install with one notice")
		AssertEqual(UPDATER_REQUEST_POLICY_ALLOW, _Updater_RequestPolicy(Running, true),
			"while the same request still answers a check")
		AssertEqual(UPDATER_REQUEST_POLICY_DROP, _Updater_InstallRequestPolicy(Paused, false),
			"a request born paused never installs")
		AssertEqual(UPDATER_REQUEST_POLICY_ALLOW, _Updater_RequestPolicy(Paused, false),
			"but it answers its check")
		_UpdaterPauseGeneration += 1
		AssertEqual(UPDATER_REQUEST_POLICY_NOTIFY, _Updater_InstallRequestPolicy(Running, false),
			"a pause and resume since its birth stops its install")
		AssertEqual(UPDATER_REQUEST_POLICY_DROP, _Updater_InstallRequestPolicy(Background, false),
			"a background request keeps its own drop")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater UPD-2: installs keep the pause contract while checks answer (upd-2-manual-check-while-paused)",
	_UpdaterTest_InstallPolicyKeepsPauseContract)
