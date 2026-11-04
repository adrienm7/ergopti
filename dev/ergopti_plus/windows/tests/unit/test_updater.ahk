; static/ergopti_plus/windows/tests/unit/test_updater.ahk

; ==============================================================================
; MODULE: Updater Channel Replacement and Operation Leasing Tests
; DESCRIPTION:
; AHK-31 channel replacement transaction and operation leasing. This file
; keeps its flat path and only these sections because the sealed updater
; diagnostic cohort (tools/ci/seal-windows-updater-original-source.cjs) pins
; its bytes; the other updater tests live in unit/modules/updater/.
; ==============================================================================





; ==================================================
; ===== AHK-31 channel replacement transaction =====
; ==================================================

_UpdaterTest_RequireChannelTransactionFunctions(Names) {
	for _, Name in Names {
		if (_DriverFuncBodyOrEmpty(Name) == "") {
			Assert(false, "AHK-31 channel replacement requires " . Name . "()")
			return false
		}
	}
	return true
}

_UpdaterTest_AcquireChannelConfigBundle() {
	global ConfigurationFile
	Bundle := _ConfigWriteTerminalTryAcquire([ConfigurationFile])
	Assert(IsObject(Bundle),
		"the deferred channel repro must own one global configuration bundle")
	return Bundle
}

class _UpdaterTestChannelHttp {
	__New(State) {
		this.State := State
	}

	Abort() {
		this.State.Aborts += 1
		return true
	}
}

_UpdaterTest_RecordChannelNotice(State, Message, Options) {
	State.Notices += 1
	if State.HasOwnProp("CriticalStates")
		State.CriticalStates.Push({ Phase: "notify", Value: A_IsCritical })
	if State.HasOwnProp("Messages")
		State.Messages.Push(Message)
	return true
}

_UpdaterTest_RecordBlockedCadenceSchedule(State, TimerFn, DelayMs) {
	State.CadenceSchedules += 1
	return true
}

_UpdaterTest_CaptureChannelAdmissionTerminal(State, Json, Request,
	Terminal := 0) {
	State.Terminals += 1
	State.Terminal := Terminal
	State.TerminalDeliveryOwned := _Updater_AsyncTerminalDeliveryActive()
}

_UpdaterTest_ProbeChannelWrite(State, Mode, Args*) {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND
	State.BoundaryDuringWrite := _Updater_AsyncAdmissionBoundaryActive()
	Request := _Updater_NewRequestContext(
		UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
	State.RefusedOwner := _Updater_RegisterAsyncRequestOwner(
		0, "main", _UpdaterTest_CaptureChannelAdmissionTerminal.Bind(State),
		"test://during-channel-write", Request)
	State.CadenceStartResult := Updater_StartBackgroundChecks(
		_UpdaterTest_RecordBlockedCadenceSchedule.Bind(State), false)
	if (Mode == "throw")
		throw Error("deterministic channel persistence failure")
	return false
}

; Preference effects need a genuinely constructed current selected source.
; The callback retains its original ports; this owner restores the selected path
; even when an assertion or injected effect throws.
_UpdaterTest_WithCurrentConfiguration(Callback) {
	global ConfigurationFile
	SavedPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Fixture := _ScopeOwnerFixture('[updater]`nchannel = "main"`ncheck_interval = 60`n')
	ConfigurationFile := Fixture.path
	try return Callback.Call()
	finally {
		ConfigurationFile := IsSet(SavedPath) ? SavedPath : unset
		_ScopeOwnerCleanup(Fixture)
	}
}

_UpdaterTest_ChannelAdmissionPrecedesPersistenceAndFailureReleases() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global UPDATER_CANCEL_REASON_CHANNEL_SWITCH
	global _UpdaterDownloadInProgress
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global _UpdaterBackgroundOwnerCounter, _UpdaterAsyncRequests
	global _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterChannelEpoch, _UpdaterFetchCache
	global UPDATER_LATEST_RELEASE, _UpdaterPendingReleaseNotification
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_BeginAsyncAdmissionBoundary",
		"_Updater_EndAsyncAdmissionBoundary",
		"_Updater_AsyncAdmissionBoundaryActive",
		"_Updater_ChannelReloadTransitionActive",
		"_Updater_AsyncTerminalDeliveryActive"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadBackgroundFn := IsSet(_UpdaterBackgroundFn)
	if HadBackgroundFn
		SavedBackgroundFn := _UpdaterBackgroundFn
	HadBackgroundOwner := IsSet(_UpdaterBackgroundOwner)
	if HadBackgroundOwner
		SavedBackgroundOwner := _UpdaterBackgroundOwner
	SavedBackgroundCounter := _UpdaterBackgroundOwnerCounter
	SavedFetchCache := _UpdaterFetchCache
	HadLatestRelease := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatestRelease
		SavedLatestRelease := UPDATER_LATEST_RELEASE
	SetChannelFn := _UpdaterTest_ResolveFunction("Updater_SetChannel")
	try {
		for _, Mode in ["false", "throw"] {
			_UpdaterTest_ResetRequestState()
			_UpdaterDownloadInProgress := false
			UPDATER_CHECK_INTERVAL := 60
			_UpdaterBackgroundFn := unset
			_UpdaterBackgroundOwner := 0
			_UpdaterChannelEpoch := 41
			_UpdaterFetchCache := Map("sentinel", "preserve")
			CacheBefore := _UpdaterFetchCache
			_UpdaterPendingReleaseNotification := { Sentinel: true }
			PendingBefore := _UpdaterPendingReleaseNotification
			UPDATER_LATEST_RELEASE := { Tag: "v-preserve" }
			LatestBefore := UPDATER_LATEST_RELEASE
			State := {
				BoundaryDuringWrite: false,
				RefusedOwner: 0,
				Terminals: 0,
				Terminal: 0,
				TerminalDeliveryOwned: false,
				CadenceSchedules: 0,
				CadenceStartResult: true,
				Notices: 0
			}
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_MANUAL, false)
			Result := SetChannelFn.Call(
				"dev", Request, false,
				_UpdaterTest_RecordChannelNotice.Bind(State),
				_UpdaterTest_ProbeChannelWrite.Bind(State, Mode))

			AssertEqual(false, Result,
				"channel persistence " . Mode . " must refuse publication")
			AssertEqual(true, State.BoundaryDuringWrite,
				"HTTP admission must close before the first yielding TOML effect")
			Assert(IsObject(State.RefusedOwner)
				and State.RefusedOwner.Id == 0
				and State.RefusedOwner.HasOwnProp("TerminalDelivered"),
				"reentrant HTTP registration must receive only an already-terminal Id=0 token")
			AssertEqual(1, State.Terminals,
				"closed admission must deliver one exact callback terminal")
			Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
				and State.Terminal.Reason == UPDATER_CANCEL_REASON_CHANNEL_SWITCH,
				"admission refusal must retain the typed channel-switch reason")
			AssertEqual(true, State.TerminalDeliveryOwned,
				"admission refusal must publish terminal quiescence before callback entry")
			AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount,
				"admission refusal must balance terminal ownership after callback return")
			AssertEqual(false, State.CadenceStartResult,
				"background cadence cannot acquire a producer during channel persistence")
			AssertEqual(0, State.CadenceSchedules,
				"closed admission must prevent even the first timer-scheduler effect")
			AssertEqual(false, IsSet(_UpdaterBackgroundFn),
				"cadence refusal must not publish a dead timer callback")
			AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
				"cadence refusal must not publish a dead owner")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				"reentrant HTTP work must never enter the replacement registry")
			AssertEqual("main", UPDATER_CHANNEL,
				"failed persistence must retain the active channel")
			AssertEqual(41, _UpdaterChannelEpoch,
				"failed persistence must not invalidate the live channel epoch")
			Assert(ObjPtr(_UpdaterFetchCache) == ObjPtr(CacheBefore),
				"failed persistence must retain the exact derived fetch cache")
			Assert(ObjPtr(_UpdaterPendingReleaseNotification)
				== ObjPtr(PendingBefore),
				"failed persistence must retain pending release state")
			Assert(ObjPtr(UPDATER_LATEST_RELEASE) == ObjPtr(LatestBefore),
				"failed persistence must retain the latest-release snapshot")
			AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
				"false/throw persistence must retire the exact admission boundary")
			AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
				"failed persistence must never publish a deferred Reload owner")
			AssertEqual(1, State.Notices,
				"persistence failure must have one visible terminal")
		}
	} finally {
		try Updater_StopBackgroundChecks(false)
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterBackgroundOwnerCounter := SavedBackgroundCounter
		if HadBackgroundFn
			_UpdaterBackgroundFn := SavedBackgroundFn
		else
			_UpdaterBackgroundFn := unset
		if HadBackgroundOwner
			_UpdaterBackgroundOwner := SavedBackgroundOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
		_UpdaterFetchCache := SavedFetchCache
		if HadLatestRelease
			UPDATER_LATEST_RELEASE := SavedLatestRelease
		else
			UPDATER_LATEST_RELEASE := unset
	}
}
Test("Updater AHK-31: channel admission precedes persistence and releases on failure (updater-channel-replacement-transaction)",
	_UpdaterTest_WithCurrentConfiguration.Bind(_UpdaterTest_ChannelAdmissionPrecedesPersistenceAndFailureReleases))

_UpdaterTest_CountUnexpectedSettingsWrite(State, Args*) {
	State.Writes += 1
	return true
}

_UpdaterTest_AcceptMenuSchedule(State, Args*) {
	State.MenuSchedules += 1
	return true
}

_UpdaterTest_ProbeIntervalLeaseAgainstChannel(State, Args*) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	State.IntervalWrites += 1
	Request := _Updater_NewRequestContext(
		UPDATER_REQUEST_ORIGIN_MANUAL, false)
	State.ChannelResult := _UpdaterTest_ResolveFunction(
		"Updater_SetChannel").Call(
		"dev", Request, false,
		_UpdaterTest_RecordChannelNotice.Bind(State),
		_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State))
	return false
}

_UpdaterTest_CountNestedIntervalWrite(State, Args*) {
	State.NestedWrites += 1
	return true
}

_UpdaterTest_ProbeIntervalLeaseAgainstInterval(State, Args*) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	State.OuterWrites += 1
	Request := _Updater_NewRequestContext(
		UPDATER_REQUEST_ORIGIN_MANUAL, false)
	State.NestedIntervalResult := Updater_SetCheckInterval(
		120, Request, false,
		_UpdaterTest_RecordChannelNotice.Bind(State),
		_UpdaterTest_CountNestedIntervalWrite.Bind(State))
	return true
}

_UpdaterTest_ActionLeasesSerializeChannelAndSiblingActions() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterAsyncActionLeases, _UpdaterDownloadInProgress
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		UPDATER_CHECK_INTERVAL := 60
		State := { Writes: 0, IntervalWrites: 0, Notices: 0,
			ChannelResult: true, OuterWrites: 0, NestedWrites: 0,
			NestedIntervalResult: true, MenuSchedules: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)

		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		Assert(IsObject(BoundaryOwner),
			"the test must own a closed channel boundary")
		AssertEqual(false, Updater_SetCheckInterval(
			91, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State)),
			"a nested cadence write must refuse before persistence")
		AssertEqual(false, Updater_DownloadAndInstall(
			{ RawJson: "{}", Tag: "v-test" }, Request, false, 0,
			_UpdaterTest_RecordChannelNotice.Bind(State)),
			"a nested install action must refuse before staging admission")
		AssertEqual(0, State.Writes,
			"closed channel admission must prevent every sibling TOML effect")
		AssertEqual(60, UPDATER_CHECK_INTERVAL,
			"refused cadence work must not publish runtime state")
		AssertEqual(false, _UpdaterDownloadInProgress,
			"refused install work must not publish the download singleton")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"refused actions must not leak a phantom lease")
		AssertEqual(true, _Updater_EndAsyncAdmissionBoundary(BoundaryOwner),
			"the exact test boundary must remain owned until explicit release")
		_UpdaterDownloadInProgress := true
		AssertEqual(false, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State)),
			"an active staging transaction must refuse channel replacement")
		AssertEqual(0, State.Writes,
			"download-active refusal must happen before persistence")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"download-active refusal must not publish a channel boundary")
		_UpdaterDownloadInProgress := false

		AssertEqual(false, Updater_SetCheckInterval(
			92, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_ProbeIntervalLeaseAgainstChannel.Bind(State)),
			"the deterministic interval write fails after its nested channel probe")
		AssertEqual(1, State.IntervalWrites,
			"the interval action must enter its yielding persistence seam once")
		AssertEqual(false, State.ChannelResult,
			"a channel switch must refuse while the interval lease is live")
		AssertEqual(0, State.Writes,
			"the refused nested channel switch must never reach persistence")
		AssertEqual("main", UPDATER_CHANNEL,
			"the nested channel refusal must leave runtime channel unchanged")
		AssertEqual(60, UPDATER_CHECK_INTERVAL,
			"the deliberately failed interval write must leave cadence unchanged")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"the failed interval action must release its exact lease from finally")

		AssertEqual(true, Updater_SetCheckInterval(
			0, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_ProbeIntervalLeaseAgainstInterval.Bind(State),
			_UpdaterTest_AcceptMenuSchedule.Bind(State)),
			"the outer interval transaction must complete after refusing reentrance")
		AssertEqual(1, State.OuterWrites,
			"the outer interval writer must run once")
		AssertEqual(false, State.NestedIntervalResult,
			"a second interval action cannot overlap the first exact lease")
		AssertEqual(0, State.NestedWrites,
			"nested interval persistence must be refused before its first effect")
		AssertEqual(0, UPDATER_CHECK_INTERVAL,
			"runtime cadence must match the sole admitted durable transaction")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"successful interval publication must release its exact lease")
		AssertEqual(1, State.MenuSchedules,
			"successful interval publication must request one deferred menu handoff")
		AssertEqual(6, State.Notices,
			"boundary, download, nested-channel, persistence and nested-action refusals must each stay visible")
	} finally {
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: action leases serialize channel, cadence and install ingress (updater-channel-replacement-transaction)",
	_UpdaterTest_WithCurrentConfiguration.Bind(_UpdaterTest_ActionLeasesSerializeChannelAndSiblingActions))

_UpdaterTest_AdmissionWrapperTerminal(State, Json, Request, Terminal := 0) {
	State.Terminals += 1
	State.Terminal := Terminal
	State.TerminalOwned := _Updater_AsyncTerminalDeliveryActive()
}

_UpdaterTest_AdmissionRefusalStopsRealAsyncWrappers() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	global _UpdaterActiveAsyncTerminalDeliveryCount
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := { Terminals: 0, Terminal: 0, TerminalOwned: false,
			Polls: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		LatestOwner := _Updater_FetchLatestJsonAsync(
			"main", Request,
			_UpdaterTest_AdmissionWrapperTerminal.Bind(State))
		ListOwner := _Updater_FetchReleasesListJsonAsync(
			"main", Request,
			_UpdaterTest_AdmissionWrapperTerminal.Bind(State))
		Assert(IsObject(LatestOwner) and LatestOwner.Id == 0
			and IsObject(ListOwner) and ListOwner.Id == 0,
			"both real async wrappers must return only terminal Id=0 tokens")
		AssertEqual(2, State.Terminals,
			"each refused wrapper must deliver one typed terminal")
		AssertEqual(true, State.TerminalOwned,
			"wrapper refusal must own terminal quiescence during callback")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal),
			"wrapper refusal must retain typed cancellation")
		AssertEqual(false, _Updater_SendOwnedAsyncRequest(
			LatestOwner, (Id) => (State.Polls += 1),
			"refused owner replay"),
			"an Id=0 terminal token can never enter transport dispatch")
		AssertEqual(0, State.Polls,
			"an Id=0 terminal token can never hand off a poll")
		AssertEqual(2, State.Terminals,
			"replaying the refused token must not duplicate its terminal")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"refused wrappers must never publish registry ownership")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount,
			"both refusal callbacks must balance terminal ownership")
	} finally {
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: real async wrappers stop at admission refusal (updater-channel-replacement-transaction)",
	_UpdaterTest_AdmissionRefusalStopsRealAsyncWrappers)

_UpdaterTest_IntervalCancellationProbesLease(State, Json, Request,
	Terminal := 0) {
	global _UpdaterAsyncActionLeases
	State.Callbacks += 1
	State.Terminal := Terminal
	State.LeasesDuringCallback := _UpdaterAsyncActionLeases.Count
	State.ChannelResult := _UpdaterTest_ResolveFunction(
		"Updater_SetChannel").Call(
		"dev", Request, false,
		_UpdaterTest_RecordChannelNotice.Bind(State),
		_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State))
}

_UpdaterTest_IntervalLeaseSpansPostcommitCancellation() {
	global UPDATER_CHECK_INTERVAL, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		State := { Writes: 0, Notices: 0, Callbacks: 0,
			Terminal: 0, LeasesDuringCallback: 0,
			ChannelResult: true, MenuSchedules: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_Updater_RegisterAsyncRequestOwner(
			0, "main",
			_UpdaterTest_IntervalCancellationProbesLease.Bind(State),
			"test://interval-cancellation", Request)

		AssertEqual(true, Updater_SetCheckInterval(
			0, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State),
			_UpdaterTest_AcceptMenuSchedule.Bind(State)),
			"a typed durable interval write must complete")
		AssertEqual(1, State.Writes,
			"the interval setting must persist exactly once")
		AssertEqual(1, State.Callbacks,
			"post-commit Stop must terminal the prior async owner")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal),
			"the stopped owner must receive typed cancellation")
		AssertEqual(1, State.LeasesDuringCallback,
			"the interval action lease must span cancellation callbacks")
		AssertEqual(false, State.ChannelResult,
			"a cancellation callback cannot start channel replacement mid-apply")
		AssertEqual(1, State.Writes,
			"the nested channel refusal must not reach its writer")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"the successful interval action must release its lease after handoff")
		AssertEqual(1, State.MenuSchedules,
			"post-commit cancellation must still reach one menu handoff")
		AssertEqual(1, State.Notices,
			"the nested channel refusal must remain visible")
	} finally {
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: interval action lease spans post-commit cancellation (updater-channel-replacement-transaction)",
	_UpdaterTest_WithCurrentConfiguration.Bind(_UpdaterTest_IntervalLeaseSpansPostcommitCancellation))

_UpdaterTest_ChannelWritePumpsRetiredTick(State, Mode, Args*) {
	State.TickResult := State.OldTick.Call()
	if (Mode == "throw")
		throw Error("deterministic channel persistence failure")
	return false
}

_UpdaterTest_RestoreChannelCadence(State, ScheduleFn, Args*) {
	global _UpdaterAsyncActionLeases
	global ConfigurationFile
	State.Recoveries += 1
	State.BoundaryDuringRecovery := _Updater_AsyncAdmissionBoundaryActive()
	State.ActionLeasesDuringRecovery := _UpdaterAsyncActionLeases.Count
	State.ConfigTerminalDuringRecovery := _ConfigWriteTerminalIsActive()
	CompetingConfig := _ConfigWriteLeaseTryAcquire(
		ConfigurationFile . ".precommit-recovery-sibling")
	State.ConfigWriterAdmittedDuringRecovery := CompetingConfig is Object
	if CompetingConfig is Object
		_ConfigWriteLeaseRelease(CompetingConfig)
	State.CompetingBoundary := _Updater_BeginAsyncAdmissionBoundary(
		"competing channel switch")
	return Updater_StartBackgroundChecks(ScheduleFn, false)
}

_UpdaterTest_FailedChannelWriteRestoresExactCadence() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterDownloadInProgress, _UpdaterAsyncRequests
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global _UpdaterBackgroundOwnerCounter, _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadBackgroundFn := IsSet(_UpdaterBackgroundFn)
	if HadBackgroundFn
		SavedBackgroundFn := _UpdaterBackgroundFn
	HadBackgroundOwner := IsSet(_UpdaterBackgroundOwner)
	if HadBackgroundOwner
		SavedBackgroundOwner := _UpdaterBackgroundOwner
	SavedBackgroundCounter := _UpdaterBackgroundOwnerCounter
	SetChannelFn := _UpdaterTest_ResolveFunction("Updater_SetChannel")
	try {
		for Mode in ["false", "throw"] {
			try Updater_StopBackgroundChecks(false)
			_UpdaterTest_ResetRequestState()
			_UpdaterDownloadInProgress := false
			UPDATER_CHECK_INTERVAL := 60
			_UpdaterBackgroundFn := unset
			_UpdaterBackgroundOwner := 0
			State := { Calls: 0, Disarms: 0, InlineNext: false,
				Pending: [], InterleaveFn: 0, Notices: 0,
				Recoveries: 0, BoundaryDuringRecovery: true,
				ActionLeasesDuringRecovery: 0,
				ConfigTerminalDuringRecovery: false,
				ConfigWriterAdmittedDuringRecovery: true,
				CompetingBoundary: 0,
				TickResult: true, OldTick: 0 }
			ScheduleFn := _UpdaterTest_BackgroundSchedule.Bind(State)
			AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
				"the repro must begin with one live cadence owner")
			OldOwner := _UpdaterBackgroundOwner
			State.OldTick := State.Pending[1]
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_MANUAL, false)

			AssertEqual(false, SetChannelFn.Call(
				"dev", Request, false,
				_UpdaterTest_RecordChannelNotice.Bind(State),
				_UpdaterTest_ChannelWritePumpsRetiredTick.Bind(State, Mode),
				0, 0, 0,
				_UpdaterTest_RestoreChannelCadence.Bind(State, ScheduleFn)),
				"failed channel persistence must report failure")
			AssertEqual(false, State.TickResult,
				"the tick captured before persistence must already be retired")
			AssertEqual(false, IsObject(OldOwner.TimerFn),
				"pre-commit stop must break the old callback cycle")
			AssertEqual(1, State.Recoveries,
				"failed persistence must restore the displaced cadence exactly once")
			AssertEqual(false, State.BoundaryDuringRecovery,
				"cadence restoration must start only after exact boundary release")
			AssertEqual(1, State.ActionLeasesDuringRecovery,
				"boundary release must atomically hand recovery one exact action lease")
			AssertEqual(true, State.ConfigTerminalDuringRecovery,
				"write-failure recovery must retain the exact global config bundle")
			AssertEqual(false, State.ConfigWriterAdmittedDuringRecovery,
				"no sibling config writer may enter before retired cadence restoration")
			AssertEqual(0, State.CompetingBoundary,
				"a successor channel boundary cannot enter during exact recovery")
			Assert(IsObject(_UpdaterBackgroundOwner)
				and ObjPtr(_UpdaterBackgroundOwner) != ObjPtr(OldOwner)
				and _UpdaterBackgroundOwner.Active
				and _UpdaterBackgroundOwner.Armed,
				"recovery must publish one acknowledged successor cadence")
			AssertEqual(1, State.Pending.Length,
				"recovery must leave exactly one future timer callback")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				"a retired tick pumped by persistence must not dispatch HTTP")
			AssertEqual("main", UPDATER_CHANNEL,
				"failed persistence must not publish the requested channel")
			AssertEqual(0, _UpdaterAsyncActionLeases.Count,
				"completed recovery must release action admission")
			AssertEqual(false, _ConfigWriteTerminalIsActive(),
				"completed pre-commit recovery must release global config admission")
			AssertEqual(1, State.Notices,
				"the persistence failure must remain visible exactly once")
		}
	} finally {
		try Updater_StopBackgroundChecks(false)
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterBackgroundOwnerCounter := SavedBackgroundCounter
		if HadBackgroundFn
			_UpdaterBackgroundFn := SavedBackgroundFn
		else
			_UpdaterBackgroundFn := unset
		if HadBackgroundOwner
			_UpdaterBackgroundOwner := SavedBackgroundOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: failed channel persistence restores the exact retired cadence (updater-channel-replacement-transaction)",
	_UpdaterTest_WithCurrentConfiguration.Bind(_UpdaterTest_FailedChannelWriteRestoresExactCadence))

_UpdaterTest_BackgroundScheduleRejectsDisarm(State, TimerFn, DelayMs) {
	Result := _UpdaterTest_BackgroundSchedule(State, TimerFn, DelayMs)
	return DelayMs == 0 ? false : Result
}

_UpdaterTest_FailedCadenceRetirementPreventsPersistence() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterChannelEpoch
	global _UpdaterDownloadInProgress
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global _UpdaterBackgroundOwnerCounter
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadBackgroundFn := IsSet(_UpdaterBackgroundFn)
	if HadBackgroundFn
		SavedBackgroundFn := _UpdaterBackgroundFn
	HadBackgroundOwner := IsSet(_UpdaterBackgroundOwner)
	if HadBackgroundOwner
		SavedBackgroundOwner := _UpdaterBackgroundOwner
	SavedBackgroundCounter := _UpdaterBackgroundOwnerCounter
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Calls: 0, Disarms: 0, InlineNext: false,
			Pending: [], InterleaveFn: 0, Notices: 0, Messages: [],
			Writes: 0, Recoveries: 0, BoundaryDuringRecovery: true,
			ActionLeasesDuringRecovery: 0 }
		ScheduleFn := _UpdaterTest_BackgroundScheduleRejectsDisarm.Bind(State)
		AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
			"the repro must begin with a live cadence")
		BeforeEpoch := _UpdaterChannelEpoch
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)

		AssertEqual(false, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State),
			0, 0, 0,
			_UpdaterTest_RestoreChannelCadence.Bind(State, ScheduleFn)),
			"failed exact timer retirement must abort before persistence")
		AssertEqual(0, State.Writes,
			"a failed precondition must never reach the TOML writer")
		AssertEqual("main", UPDATER_CHANNEL,
			"failed cadence retirement must not publish channel state")
		AssertEqual(BeforeEpoch, _UpdaterChannelEpoch,
			"failed cadence retirement must not advance channel epoch")
		AssertEqual(1, State.Recoveries,
			"even a rejecting disarm must restore its displaced cadence owner")
		AssertEqual(1, State.Notices,
			"the precondition failure must have one visible terminal")
		AssertEqual(t("updater.settings_save_failed"), State.Messages[1],
			"a pre-write failure must not claim that the channel was saved")
		Assert(IsObject(_UpdaterBackgroundOwner)
			and _UpdaterBackgroundOwner.Active
			and _UpdaterBackgroundOwner.Armed,
			"recovery must acknowledge one replacement cadence")
	} finally {
		try Updater_StopBackgroundChecks(false)
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterBackgroundOwnerCounter := SavedBackgroundCounter
		if HadBackgroundFn
			_UpdaterBackgroundFn := SavedBackgroundFn
		else
			_UpdaterBackgroundFn := unset
		if HadBackgroundOwner
			_UpdaterBackgroundOwner := SavedBackgroundOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: failed cadence retirement aborts before persistence (updater-channel-replacement-transaction)",
	_UpdaterTest_FailedCadenceRetirementPreventsPersistence)

_UpdaterTest_CaptureReplacementTerminal(State, Json, Request, Terminal := 0) {
	State.NewTerminals += 1
	State.NewTerminal := Terminal
}

_UpdaterTest_RegisterReplacementFromRetiredTerminal(State, Json, Request,
	Terminal := 0) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	State.OldTerminals += 1
	State.OldTerminal := Terminal
	State.NewRequest := _Updater_NewRequestContext(
		UPDATER_REQUEST_ORIGIN_MANUAL, false)
	State.NewOwner := _Updater_RegisterAsyncRequestOwner(
		_UpdaterTestChannelHttp(State.NewHttp), "main",
		_UpdaterTest_CaptureReplacementTerminal.Bind(State),
		"test://replacement", State.NewRequest)
}

_UpdaterTest_ChannelRegistrySwapPreservesReentrantReplacement() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	global _UpdaterActiveAsyncTerminalDeliveryCount
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_SwapAsyncRequestsForBoundary",
		"_Updater_DeliverCancelledAsyncRequests"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := {
			OldHttp: { Aborts: 0 },
			NewHttp: { Aborts: 0 },
			OldTerminals: 0,
			OldTerminal: 0,
			NewTerminals: 0,
			NewTerminal: 0,
			NewRequest: 0,
			NewOwner: 0
		}
		OldRequest := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		OldOwner := _Updater_RegisterAsyncRequestOwner(
			_UpdaterTestChannelHttp(State.OldHttp), "main",
			_UpdaterTest_RegisterReplacementFromRetiredTerminal.Bind(State),
			"test://retired", OldRequest)
		PreviousCritical := A_IsCritical
		Critical("On")
		try Pending := _Updater_SwapAsyncRequestsForBoundary(
			"channel switch", Map())
		finally Critical(PreviousCritical ? PreviousCritical : "Off")

		_Updater_DeliverCancelledAsyncRequests(Pending, "channel switch")

		AssertEqual(1, State.OldHttp.Aborts,
			"the retired registry must abort its old transport exactly once")
		AssertEqual(1, State.OldTerminals,
			"the retired registry must callback its old owner exactly once")
		Assert(_Updater_AsyncTerminalIsCancelled(State.OldTerminal),
			"the retired owner must receive typed cancellation")
		Assert(IsObject(State.NewOwner)
			and _Updater_AsyncRequestOwned(State.NewOwner),
			"callback reentrance must publish into the replacement Map")
		AssertEqual(1, _UpdaterAsyncRequests.Count,
			"retired-map delivery must preserve the one replacement owner")
		AssertEqual(0, State.NewTerminals,
			"old-owner cleanup must not terminal its reentrant replacement")
		AssertEqual(false, _Updater_AsyncRequestOwned(OldOwner),
			"the old owner must remain retired after callback reentrance")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount,
			"retired-map delivery must balance terminal ownership after callback return")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: registry swap preserves reentrant replacement (updater-channel-replacement-transaction)",
	_UpdaterTest_ChannelRegistrySwapPreservesReentrantReplacement)

_UpdaterTest_RecordChannelReloadSchedule(State, Continuation, DelayMs) {
	State.ScheduleCount += 1
	if State.HasOwnProp("CriticalStates")
		State.CriticalStates.Push({ Phase: "schedule", Value: A_IsCritical })
	State.Scheduled.Push({ Continuation: Continuation, DelayMs: DelayMs })
	return true
}

_UpdaterTest_RejectChannelReloadSchedule(State, Continuation, DelayMs) {
	State.ScheduleCount += 1
	State.Scheduled.Push({ Continuation: Continuation, DelayMs: DelayMs })
	return false
}

; A launched reload owns the lent bundle until OnExit, and an accepted OnExit
; ends the process, which releases it. The fake models that whole accepted path
; so no test leaks the process-wide configuration barrier.
_UpdaterTest_RunChannelReload(State, ConfigBundle := 0, RefusedFn := 0) {
	State.ReloadCount += 1
	State.RefusedFn := RefusedFn
	if State.HasOwnProp("CriticalStates")
		State.CriticalStates.Push({ Phase: "reload", Value: A_IsCritical })
	if State.ReloadResult && (ConfigBundle is Object)
		_ConfigWriteTerminalRelease(ConfigBundle)
	return State.ReloadResult
}

_UpdaterTest_RecordSuccessfulChannelWrite(State, Args*) {
	State.Writes += 1
	State.CriticalStates.Push({ Phase: "writer", Value: A_IsCritical })
	return 1
}

_UpdaterTest_RecordChannelReloadFailure(State, Args*) {
	State.FailureCount += 1
	return true
}

_UpdaterTest_RecordChannelReloadRecovery(State, Args*) {
	State.RecoverCount += 1
	return true
}

_UpdaterTest_CaptureNonLeasedTerminal(State, Json, Request, Terminal := 0) {
	State.TerminalCount += 1
	State.DeliveryActiveDuringCallback := _Updater_AsyncTerminalDeliveryActive()
	State.FirstContinuationResult := State.Scheduled[1].Continuation.Call()
	State.ReloadCountDuringCallback := State.ReloadCount
}

_UpdaterTest_NewChannelReloadProbe() {
	return {
		ScheduleCount: 0,
		Scheduled: [],
		ReloadCount: 0,
		ReloadResult: true,
		FailureCount: 0,
		RecoverCount: 0,
		TerminalCount: 0,
		DeliveryActiveDuringCallback: false,
		FirstContinuationResult: true,
		ReloadCountDuringCallback: -1
	}
}

_UpdaterTest_ChannelActionDefusesInheritedCritical() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterDownloadInProgress
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	HadBackgroundFn := IsSet(_UpdaterBackgroundFn)
	if HadBackgroundFn
		SavedBackgroundFn := _UpdaterBackgroundFn
	HadBackgroundOwner := IsSet(_UpdaterBackgroundOwner)
	if HadBackgroundOwner
		SavedBackgroundOwner := _UpdaterBackgroundOwner
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := _UpdaterTest_NewChannelReloadProbe()
		State.Writes := 0
		State.Notices := 0
		State.CriticalStates := []
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		PreviousCritical := Critical("On")
		try {
			AssertTrue(Updater_SetChannel("dev", Request, false,
				_UpdaterTest_RecordChannelNotice.Bind(State),
				_UpdaterTest_RecordSuccessfulChannelWrite.Bind(State),
				_UpdaterTest_RunChannelReload.Bind(State),
				_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
				_UpdaterTest_RecordChannelReloadFailure.Bind(State),
				_UpdaterTest_RecordChannelReloadRecovery.Bind(State)))
			AssertTrue(A_IsCritical,
				"Updater_SetChannel must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(1, State.Writes)
		AssertEqual(1, State.ScheduleCount)
		for Sample in State.CriticalStates
			AssertEqual(0, Sample.Value,
				Sample.Phase . " must remain interruptible during channel change")
		AssertTrue(State.Scheduled[1].Continuation.Call(),
			"the accepted fake Reload must retire the retained transition bundle")
		AssertEqual(1, State.ReloadCount)
		LastCriticalSample := State.CriticalStates[
			State.CriticalStates.Length]
		AssertEqual("reload", LastCriticalSample.Phase)
		AssertEqual(0, LastCriticalSample.Value,
			"the deferred Reload callback must not recover the original caller's Critical state")
	} finally {
		_UpdaterDownloadInProgress := SavedDownload
		if HadBackgroundFn
			_UpdaterBackgroundFn := SavedBackgroundFn
		else
			_UpdaterBackgroundFn := unset
		if HadBackgroundOwner
			_UpdaterBackgroundOwner := SavedBackgroundOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: channel action never inherits caller Critical "
	. "(updater-channel-inherited-critical)",
	_UpdaterTest_WithCurrentConfiguration.Bind(_UpdaterTest_ChannelActionDefusesInheritedCritical))

_UpdaterTest_NonLeasedTerminalBlocksDeferredReload() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_BeginAsyncAdmissionBoundary",
		"_Updater_EndAsyncAdmissionBoundary",
		"_Updater_TakeAsyncRequest",
		"_Updater_InvokeAsyncOnJson",
		"_Updater_BeginDeferredChannelReload",
		"_Updater_ChannelReloadQuiescent",
		"_Updater_ChannelReloadTransitionActive"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewChannelReloadProbe()
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := _Updater_RegisterAsyncRequestOwner(
			0, "main", _UpdaterTest_CaptureNonLeasedTerminal.Bind(State),
			"test://nonleased-terminal", Request)
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		Assert(IsObject(BoundaryOwner),
			"the test must own one exact channel boundary")
		ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
		AssertEqual(true, _Updater_TakeAsyncRequest(Owner.Id, Owner.Record),
			"completion must exact-take the non-leased registry owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"the exact take must publish an empty registry")
		AssertEqual(0, _UpdaterActiveSendLeaseCount,
			"this repro deliberately has no COM lease backstop")
		AssertEqual(false, _Updater_ChannelReloadQuiescent(),
			"a claimed non-leased terminal keeps an empty registry non-quiescent")

		Transition := _Updater_BeginDeferredChannelReload(
			BoundaryOwner,
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordChannelReloadFailure.Bind(State),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
			A_TickCount, 10000, 0, ConfigBundle)
		Assert(IsObject(Transition),
			"channel replacement must publish one exact deferred Reload owner")
		AssertEqual(1, State.ScheduleCount,
			"deferred Reload must start with one one-shot continuation")

		AssertEqual(true, _Updater_InvokeAsyncOnJson(
			Owner.Record["on_json"], "{}", Request, 0,
			"non-leased terminal test", Owner.Record),
			"the owned terminal callback must return through the shared dispatcher")
		AssertEqual(1, State.TerminalCount,
			"the exact completion must callback once")
		AssertEqual(true, State.DeliveryActiveDuringCallback,
			"terminal ownership must remain published on the callback stack")
		AssertEqual(false, State.FirstContinuationResult,
			"a continuation pumped by on_json must refuse Reload")
		AssertEqual(0, State.ReloadCountDuringCallback,
			"Reload must remain impossible until the callback returns")
		AssertEqual(0, State.ReloadCount,
			"terminal return may only make a timer eligible, never Reload inline")
		AssertEqual(true, _Updater_ChannelReloadQuiescent(),
			"quiescence begins after the terminal dispatcher returns")
		AssertEqual(2, State.ScheduleCount,
			"the consumed non-quiescent arm must be replaced exactly once")
		AssertEqual(false, State.Scheduled[1].Continuation.Call(),
			"the consumed first continuation must be stale")
		AssertEqual(true, State.Scheduled[2].Continuation.Call(),
			"the current continuation must perform the quiescent Reload")
		AssertEqual(1, State.ReloadCount,
			"the exact transition must Reload once")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"successful Reload must retire the exact transition")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"a returning test Reload must release its exact admission boundary")
		BoundaryOwner := 0
	} finally {
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: non-leased terminal blocks Reload until callback return (updater-channel-replacement-transaction)",
	_UpdaterTest_NonLeasedTerminalBlocksDeferredReload)

_UpdaterTest_TerminalClaimsBalanceIndependently() {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		First := Map("terminal_claimed", false)
		Second := Map("terminal_claimed", false)
		AssertEqual(true, _Updater_ClaimAsyncTerminalRecord(First),
			"the first exact terminal must claim one delivery slot")
		AssertEqual(true, _Updater_ClaimAsyncTerminalRecord(Second),
			"the second exact terminal must claim an independent delivery slot")
		AssertEqual(2, _UpdaterActiveAsyncTerminalDeliveryCount,
			"two simultaneous terminal owners must publish count two")
		AssertEqual(false, _Updater_ChannelReloadQuiescent(),
			"two claimed terminals keep channel Reload non-quiescent")

		AssertEqual(true, _Updater_EndAsyncTerminalRecord(First),
			"the first exact owner must release its own terminal claim")
		AssertEqual(1, _UpdaterActiveAsyncTerminalDeliveryCount,
			"ending one terminal must preserve the sibling's live claim")
		AssertEqual(false, _Updater_ChannelReloadQuiescent(),
			"one remaining terminal must still block channel Reload")

		AssertEqual(true, _Updater_EndAsyncTerminalRecord(Second),
			"the sibling owner must release its own terminal claim")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount,
			"all terminal claims must balance exactly to zero")
		AssertEqual(true, _Updater_ChannelReloadQuiescent(),
			"terminal quiescence begins only after both exact owners return")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: simultaneous terminal claims balance independently (updater-channel-replacement-transaction)",
	_UpdaterTest_TerminalClaimsBalanceIndependently)

_UpdaterTest_DeferredReloadTimeoutRecoversExactlyOnce() {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_BeginAsyncAdmissionBoundary",
		"_Updater_EndAsyncAdmissionBoundary",
		"_Updater_BeginDeferredChannelReload",
		"_Updater_RunDeferredChannelReload",
		"_Updater_ChannelReloadTransitionActive"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewChannelReloadProbe()
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
		Transition := _Updater_BeginDeferredChannelReload(
			BoundaryOwner,
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordChannelReloadFailure.Bind(State),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
			0xFFFFFFF0, 40, 0, ConfigBundle)
		_UpdaterActiveAsyncTerminalDeliveryCount := 1

		AssertEqual(false, _Updater_RunDeferredChannelReload(
			Transition, Transition.ArmEpoch, 0x100000020),
			"native monotonic crossing must abandon Reload over a live terminal")
		AssertEqual(0, State.ReloadCount,
			"timeout must never force Reload over non-quiescent work")
		AssertEqual(1, State.FailureCount,
			"timeout must surface one failure terminal")
		AssertEqual(1, State.RecoverCount,
			"timeout must recover the committed channel session once")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"timeout must retire the exact deferred owner")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"timeout recovery must reopen channel admission")
		BoundaryOwner := 0
		AssertEqual(false, _Updater_RunDeferredChannelReload(Transition),
			"the timed-out continuation must be permanently stale")
		AssertEqual(1, State.FailureCount,
			"stale timeout replay must not duplicate failure output")
		AssertEqual(1, State.RecoverCount,
			"stale timeout replay must not duplicate recovery")
	} finally {
		_UpdaterActiveAsyncTerminalDeliveryCount := 0
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: deferred Reload timeout crosses a DWORD boundary and is exact-once (updater-channel-replacement-transaction)",
	_UpdaterTest_DeferredReloadTimeoutRecoversExactlyOnce)

_UpdaterTest_DeferredReloadArmFailureOwnsOneRecovery() {
	if !_UpdaterTest_RequireChannelTransactionFunctions([
		"_Updater_BeginAsyncAdmissionBoundary",
		"_Updater_EndAsyncAdmissionBoundary",
		"_Updater_BeginDeferredChannelReload",
		"_Updater_ChannelReloadTransitionActive"
	])
		return
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewChannelReloadProbe()
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
		Transition := _Updater_BeginDeferredChannelReload(
			BoundaryOwner,
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RejectChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordChannelReloadFailure.Bind(State),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
			A_TickCount, 10000, 0, ConfigBundle)
		AssertEqual(0, Transition,
			"a false scheduler result must refuse deferred Reload ownership")
		AssertEqual(1, State.ScheduleCount,
			"the failed exact arm must make one scheduler attempt")
		AssertEqual(1, State.FailureCount,
			"arm failure must own one visible failure terminal")
		AssertEqual(1, State.RecoverCount,
			"arm failure must recover the committed channel once")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"arm failure must retire its exact transition")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"arm failure must release its exact channel boundary")
		BoundaryOwner := 0
		AssertEqual(false, State.Scheduled[1].Continuation.Call(),
			"a callback retained by a rejecting scheduler must be stale")
		AssertEqual(1, State.FailureCount,
			"stale rejected-arm callback must not duplicate failure")
		AssertEqual(1, State.RecoverCount,
			"stale rejected-arm callback must not duplicate recovery")
	} finally {
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: deferred Reload arm failure owns one recovery (updater-channel-replacement-transaction)",
	_UpdaterTest_DeferredReloadArmFailureOwnsOneRecovery)

_UpdaterTest_RecordReloadEvent(State, Kind, Args*) {
	State.Events.Push(Kind)
	if (Kind == "failure")
		State.FailureCount += 1
	else if (Kind == "recover")
		State.RecoverCount += 1
	else if (Kind == "notice")
		State.Notices += 1
	return true
}

_UpdaterTest_SetterArmFailureHasOneOwnedTerminal() {
	global UPDATER_CHANNEL, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterDownloadInProgress, _UpdaterFetchCache
	global UPDATER_LATEST_RELEASE, _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedFetchCache := _UpdaterFetchCache
	HadLatest := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatest
		SavedLatest := UPDATER_LATEST_RELEASE
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		State := _UpdaterTest_NewChannelReloadProbe()
		State.Writes := 0
		State.Notices := 0
		State.Events := []
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(false, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordReloadEvent.Bind(State, "notice"),
			_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State),
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RejectChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordReloadEvent.Bind(State, "failure"),
			_UpdaterTest_RecordReloadEvent.Bind(State, "recover")),
			"a rejecting initial reload arm must fail the outer setter")
		AssertEqual(1, State.Writes,
			"the channel must reach its durable commit exactly once")
		AssertEqual(1, State.FailureCount,
			"initial arm failure must own one failure callback")
		AssertEqual(1, State.Notices,
			"initial arm failure must use the injected visible terminal once")
		AssertEqual(1, State.RecoverCount,
			"initial arm failure must recover once")
		AssertEqual(3, State.Events.Length,
			"outer Setter must not duplicate the helper-owned terminal")
		AssertEqual("failure", State.Events[1],
			"failure callback must precede visible output")
		AssertEqual("notice", State.Events[2],
			"the injected notice must be emitted by the owned failure path")
		AssertEqual("recover", State.Events[3],
			"recovery must follow the visible failure terminal")
		AssertEqual("dev", UPDATER_CHANNEL,
			"arm failure happens after the explicit durable commit point")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"helper-owned recovery must consume the exact boundary")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"synchronous injected recovery must release its exact lease")
	} finally {
		_UpdaterDownloadInProgress := SavedDownload
		_UpdaterFetchCache := SavedFetchCache
		if HadLatest
			UPDATER_LATEST_RELEASE := SavedLatest
		else
			UPDATER_LATEST_RELEASE := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Setter initial arm failure has one owned terminal (updater-channel-replacement-transaction)",
	_UpdaterTest_WithCurrentConfiguration.Bind(_UpdaterTest_SetterArmFailureHasOneOwnedTerminal))

_UpdaterTest_ActiveSendLeaseBlocksDeferredReload() {
	global _UpdaterActiveSendLeaseCount
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryOwner := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewChannelReloadProbe()
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
		_UpdaterActiveSendLeaseCount := 1
		Transition := _Updater_BeginDeferredChannelReload(
			BoundaryOwner,
			_UpdaterTest_RunChannelReload.Bind(State),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordChannelReloadFailure.Bind(State),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
			A_TickCount, 10000, 0, ConfigBundle)
		AssertEqual(false, State.Scheduled[1].Continuation.Call(),
			"an empty registry with one active COM lease must not Reload")
		AssertEqual(0, State.ReloadCount,
			"Reload must remain blocked until the yielding COM frame returns")
		AssertEqual(2, State.ScheduleCount,
			"the consumed lease-blocked arm must be replaced exactly once")
		_UpdaterActiveSendLeaseCount := 0
		AssertEqual(true, State.Scheduled[2].Continuation.Call(),
			"the current continuation may Reload after lease release")
		AssertEqual(1, State.ReloadCount,
			"lease quiescence must hand off exactly one Reload")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"successful lease-gated Reload must retire its transition")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"successful lease-gated Reload must release admission")
		BoundaryOwner := 0
	} finally {
		_UpdaterActiveSendLeaseCount := 0
		if IsObject(BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: active COM lease blocks deferred Reload (updater-channel-replacement-transaction)",
	_UpdaterTest_ActiveSendLeaseBlocksDeferredReload)

_UpdaterTest_ThrowChannelReload(State, *) {
	State.ReloadCount += 1
	throw Error("deterministic Reload failure")
}

_UpdaterTest_FailChannelRecovery(State, Mode, Args*) {
	State.RecoverCount += 1
	if (Mode == "throw")
		throw Error("deterministic recovery failure")
	return false
}

_UpdaterTest_ReloadAndRecoveryFailuresAreExact() {
	global _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	try {
		for ReloadMode in ["false", "throw"] {
			_UpdaterTest_ResetRequestState()
			State := _UpdaterTest_NewChannelReloadProbe()
			State.ReloadResult := false
			BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
			ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
			ReloadFn := ReloadMode == "throw"
				? _UpdaterTest_ThrowChannelReload.Bind(State)
				: _UpdaterTest_RunChannelReload.Bind(State)
			Transition := _Updater_BeginDeferredChannelReload(
				BoundaryOwner, ReloadFn,
				_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
				_UpdaterTest_RecordChannelReloadFailure.Bind(State),
				_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
				A_TickCount, 10000, 0, ConfigBundle)
			AssertEqual(false, State.Scheduled[1].Continuation.Call(),
				ReloadMode . " Reload failure must return a typed failure")
			AssertEqual(1, State.ReloadCount,
				ReloadMode . " Reload effect must run exactly once")
			AssertEqual(1, State.FailureCount,
				ReloadMode . " Reload failure must surface exactly once")
			AssertEqual(1, State.RecoverCount,
				ReloadMode . " Reload failure must recover exactly once")
			AssertEqual(true, Transition.RecoveryOwned,
				ReloadMode . " failure must record typed recovery ownership")
			AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
				ReloadMode . " failure recovery must consume the boundary")
			AssertEqual(0, _UpdaterAsyncActionLeases.Count,
				ReloadMode . " injected recovery must release its exact lease")
			AssertEqual(false, State.Scheduled[1].Continuation.Call(),
				ReloadMode . " consumed continuation must stay stale")
			AssertEqual(1, State.FailureCount,
				ReloadMode . " stale replay must not duplicate output")
		}

		for RecoveryMode in ["false", "throw"] {
			_UpdaterTest_ResetRequestState()
			State := _UpdaterTest_NewChannelReloadProbe()
			State.ReloadResult := false
			BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
			ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
			Transition := _Updater_BeginDeferredChannelReload(
				BoundaryOwner,
				_UpdaterTest_RunChannelReload.Bind(State),
				_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
				_UpdaterTest_RecordChannelReloadFailure.Bind(State),
				_UpdaterTest_FailChannelRecovery.Bind(State, RecoveryMode),
				A_TickCount, 10000, 0, ConfigBundle)
			AssertEqual(false, State.Scheduled[1].Continuation.Call(),
				RecoveryMode . " recovery failure must remain contained")
			AssertEqual(1, State.FailureCount,
				RecoveryMode . " recovery failure must not duplicate the Reload terminal")
			AssertEqual(1, State.RecoverCount,
				RecoveryMode . " recovery seam must execute exactly once")
			AssertEqual(false, Transition.RecoveryOwned,
				RecoveryMode . " recovery must not be recorded as owned")
			AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
				RecoveryMode . " failed recovery must not leave a stale boundary")
			AssertEqual(0, _UpdaterAsyncActionLeases.Count,
				RecoveryMode . " failed recovery must release its exact lease")
		}
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Reload and recovery false/throw paths are exact (updater-channel-replacement-transaction)",
	_UpdaterTest_ReloadAndRecoveryFailuresAreExact)

; Models a launched Reload whose successor has not asked this instance to close
; yet: the lent bundle stays owned by the reload.
_UpdaterTest_LaunchPendingChannelReload(State, ConfigBundle := 0, RefusedFn := 0) {
	State.ReloadCount += 1
	State.RefusedFn := RefusedFn
	return true
}

_UpdaterTest_RefusalAfterLaunchRecoversOnce() {
	global _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	ConfigBundle := 0
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewChannelReloadProbe()
		BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary("channel switch")
		ConfigBundle := _UpdaterTest_AcquireChannelConfigBundle()
		_Updater_BeginDeferredChannelReload(
			BoundaryOwner,
			_UpdaterTest_LaunchPendingChannelReload.Bind(State),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(State),
			_UpdaterTest_RecordChannelReloadFailure.Bind(State),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(State),
			A_TickCount, 10000, 0, ConfigBundle)
		AssertEqual(true, State.Scheduled[1].Continuation.Call(),
			"a launched channel Reload is a pending success")
		AssertEqual(0, State.FailureCount,
			"a launched Reload must not surface a failure (reload-returns-pending)")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"the launched Reload ends channel admission")
		AssertEqual(true, _ConfigWriteTerminalIsActive(),
			"the launched Reload keeps the lent bundle until OnExit")
		AssertEqual(true, HasMethod(State.RefusedFn, "Call"),
			"the channel must hand the Reload a refusal callback")
		State.RefusedFn.Call("test refusal")
		AssertEqual(1, State.FailureCount,
			"a refusal after launch must surface one failure")
		AssertEqual(1, State.RecoverCount,
			"a refusal after launch must recover the committed channel once")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"recovery must release its exact action lease")
		AssertEqual(false, _ConfigWriteTerminalIsActive(),
			"recovery must release the bundle the refused Reload handed back")
	} finally {
		if (ConfigBundle is Object)
			_ConfigWriteTerminalRelease(ConfigBundle)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: a channel Reload refused after launch recovers once (reload-returns-pending)",
	_UpdaterTest_RefusalAfterLaunchRecoversOnce)

_UpdaterTest_RecoveryEffect(State, Field, Mode, Args*) {
	State[Field] += 1
	if (Mode == "throw")
		throw Error("deterministic " . Field . " failure")
	return Mode == "true"
}

_UpdaterTest_ProbeRecoveryRebuildOwnership(State, Args*) {
	global _UpdaterAsyncActionLeases
	State["Rebuilds"] += 1
	State["LeasesDuringRebuild"] := _UpdaterAsyncActionLeases.Count
	CompetingBoundary := _Updater_BeginAsyncAdmissionBoundary(
		"competing channel during menu rebuild")
	State["CompetingBoundaryAdmitted"] := IsObject(CompetingBoundary)
	if IsObject(CompetingBoundary)
		_Updater_EndAsyncAdmissionBoundary(CompetingBoundary)
	return true
}

_UpdaterTest_InlineRecoverySchedule(State, Mode, Continuation, DelayMs) {
	State["Schedules"] += 1
	if (Mode == "throw")
		throw Error("deterministic recovery scheduler failure")
	if (Mode == "false")
		return false
	State["CallbackResult"] := Continuation.Call()
	return true
}

_UpdaterTest_DefaultRecoveryTypesEveryEffect() {
	global _UpdaterAsyncActionLeases
	Saved := _UpdaterTest_SaveRequestState()
	try {
		for RecoverySpec in [
			{ Start: "false", Schedule: "false", Rebuild: "true" },
			{ Start: "throw", Schedule: "false", Rebuild: "true" },
			{ Start: "true", Schedule: "false", Rebuild: "true" },
			{ Start: "true", Schedule: "throw", Rebuild: "true" },
			{ Start: "true", Schedule: "true", Rebuild: "false" },
			{ Start: "true", Schedule: "true", Rebuild: "throw" },
			{ Start: "true", Schedule: "true", Rebuild: "true" }
		] {
			_UpdaterTest_ResetRequestState()
			State := Map("Starts", 0, "Schedules", 0, "Rebuilds", 0,
				"CallbackResult", false)
			Result := _Updater_RecoverCommittedChannelTransition(
				"deterministic recovery", 0,
				_UpdaterTest_InlineRecoverySchedule.Bind(
					State, RecoverySpec.Schedule),
				_UpdaterTest_RecoveryEffect.Bind(
					State, "Starts", RecoverySpec.Start),
				0,
				_UpdaterTest_RecoveryEffect.Bind(
					State, "Rebuilds", RecoverySpec.Rebuild))
			Expected := RecoverySpec.Start == "true"
				and RecoverySpec.Schedule == "true"
				and RecoverySpec.Rebuild == "true"
			AssertEqual(Expected, Result,
				"recovery must type Start, scheduler and actual menu effect")
			AssertEqual(1, State["Starts"],
				"recovery must attempt cadence startup exactly once")
			AssertEqual(1, State["Schedules"],
				"recovery must attempt menu scheduling exactly once")
			AssertEqual(RecoverySpec.Schedule == "true" ? 1 : 0,
				State["Rebuilds"],
				"only an acknowledged inline schedule may run menu rebuild")
			AssertEqual(0, _UpdaterAsyncActionLeases.Count,
				"every synchronous recovery terminal must release action ownership")
		}

		_UpdaterTest_ResetRequestState()
		ScheduleState := _UpdaterTest_NewChannelReloadProbe()
		EffectState := Map("Starts", 0, "Rebuilds", 0,
			"LeasesDuringRebuild", -1,
			"CompetingBoundaryAdmitted", false)
		AssertEqual(true, _Updater_RecoverCommittedChannelTransition(
			"future menu recovery", 0,
			_UpdaterTest_RecordChannelReloadSchedule.Bind(ScheduleState),
			_UpdaterTest_RecoveryEffect.Bind(
				EffectState, "Starts", "true"),
			0,
			_UpdaterTest_ProbeRecoveryRebuildOwnership.Bind(EffectState)),
			"an acknowledged future menu callback must retain recovery ownership")
		AssertEqual(1, _UpdaterAsyncActionLeases.Count,
			"future menu recovery must keep its exact action lease")
		AssertEqual(0, _Updater_BeginAsyncAdmissionBoundary("successor channel"),
			"channel replacement must remain closed until the actual menu effect")
		AssertEqual(true, ScheduleState.Scheduled[1].Continuation.Call(),
			"the retained continuation must execute the typed menu effect")
		AssertEqual(1, EffectState["Rebuilds"],
			"the future continuation must rebuild once")
		AssertEqual(1, EffectState["LeasesDuringRebuild"],
			"the exact recovery lease must stay live on the menu effect stack")
		AssertEqual(false, EffectState["CompetingBoundaryAdmitted"],
			"menu rebuild must refuse a competing channel boundary until it returns")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count,
			"actual menu completion must release recovery admission")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: default recovery types cadence, scheduler and menu effect (updater-channel-replacement-transaction)",
	_UpdaterTest_DefaultRecoveryTypesEveryEffect)

_UpdaterTest_StaleTimedOutRecoveryCannotRetireSuccessor() {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	Saved := _UpdaterTest_SaveRequestState()
	BoundaryTwo := 0
	try {
		_UpdaterTest_ResetRequestState()
		StateOne := _UpdaterTest_NewChannelReloadProbe()
		BoundaryOne := _Updater_BeginAsyncAdmissionBoundary("channel switch one")
		ConfigBundleOne := _UpdaterTest_AcquireChannelConfigBundle()
		TransitionOne := _Updater_BeginDeferredChannelReload(
			BoundaryOne,
			_UpdaterTest_RunChannelReload.Bind(StateOne),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(StateOne),
			_UpdaterTest_RecordChannelReloadFailure.Bind(StateOne),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(StateOne),
			100, 10, 0, ConfigBundleOne)
		_UpdaterActiveAsyncTerminalDeliveryCount := 1
		AssertEqual(false, _Updater_RunDeferredChannelReload(
			TransitionOne, TransitionOne.ArmEpoch, 111),
			"the first exact transition must time out")
		_UpdaterActiveAsyncTerminalDeliveryCount := 0

		StateTwo := _UpdaterTest_NewChannelReloadProbe()
		BoundaryTwo := _Updater_BeginAsyncAdmissionBoundary("channel switch two")
		Assert(IsObject(BoundaryTwo),
			"timeout recovery must permit one exact successor boundary")
		ConfigBundleTwo := _UpdaterTest_AcquireChannelConfigBundle()
		TransitionTwo := _Updater_BeginDeferredChannelReload(
			BoundaryTwo,
			_UpdaterTest_RunChannelReload.Bind(StateTwo),
			_UpdaterTest_RecordChannelReloadSchedule.Bind(StateTwo),
			_UpdaterTest_RecordChannelReloadFailure.Bind(StateTwo),
			_UpdaterTest_RecordChannelReloadRecovery.Bind(StateTwo),
			A_TickCount, 10000, 0, ConfigBundleTwo)
		AssertEqual(false, StateOne.Scheduled[1].Continuation.Call(),
			"the retained timeout callback must stay stale beside a successor")
		AssertEqual(true, _Updater_ChannelReloadTransitionActive(),
			"stale predecessor replay must not retire the live successor")
		AssertEqual(0, StateTwo.ReloadCount,
			"stale predecessor replay must not run successor Reload")
		AssertEqual(true, StateTwo.Scheduled[1].Continuation.Call(),
			"the successor's exact continuation must remain runnable")
		AssertEqual(1, StateTwo.ReloadCount,
			"the successor must Reload exactly once")
		BoundaryTwo := 0
	} finally {
		_UpdaterActiveAsyncTerminalDeliveryCount := 0
		if IsObject(BoundaryTwo)
			_Updater_EndAsyncAdmissionBoundary(BoundaryTwo)
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: stale timed-out continuation cannot retire successor (updater-channel-replacement-transaction)",
	_UpdaterTest_StaleTimedOutRecoveryCannotRetireSuccessor)

_UpdaterTest_ChannelEpochRejectsABA() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_REQUEST_POLICY_ALLOW
	global UPDATER_REQUEST_POLICY_DROP
	global _UpdaterChannelEpoch, UPDATER_CHANNEL
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		NewRequest := _UpdaterTest_ResolveFunction("_Updater_NewRequestContext")
		RequestA := NewRequest.Call(
			UPDATER_REQUEST_ORIGIN_MANUAL, false, "main")
		CapturedEpoch := RequestA.ChannelEpoch
		AssertEqual(_UpdaterChannelEpoch, CapturedEpoch,
			"a new request must capture the current monotone channel epoch")
		AssertEqual(UPDATER_REQUEST_POLICY_ALLOW,
			_Updater_RequestPolicy(RequestA, false),
			"fresh same-epoch work must remain publishable before a channel transition")
		UPDATER_CHANNEL := "dev"
		_UpdaterChannelEpoch += 1
		UPDATER_CHANNEL := "main"
		_UpdaterChannelEpoch += 1
		Assert(_UpdaterChannelEpoch > CapturedEpoch,
			"main-dev-main must advance beyond the request's captured epoch")
		AssertEqual("main", RequestA.Channel,
			"the stale request and current state deliberately share a channel String")
		AssertEqual(UPDATER_REQUEST_POLICY_DROP,
			_Updater_RequestPolicy(RequestA, false),
			"main-dev-main must still reject stale work by monotone channel epoch")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: channel epoch rejects ABA publication (updater-channel-replacement-transaction)",
	_UpdaterTest_ChannelEpochRejectsABA)



; ====================================
; ===== AHK-31 operation leasing =====
; ====================================

_UpdaterTest_OperationLeaseActiveOrFalse() {
	try return _Updater_AsyncSendLeaseActive()
	catch {
		return false
	}
}

class _UpdaterTestOperationLeaseHttp {
	__New(State, SendInterleave := 0, WaitInterleave := 0,
		ThrowOnAbort := false) {
		this.State := State
		this.SendInterleave := SendInterleave
		this.WaitInterleave := WaitInterleave
		this.ThrowOnAbort := ThrowOnAbort
		this.Status := 200
		this.ResponseText := '{}'
	}

	Send() {
		this.State.Sends += 1
		this.State.LeaseInsideSend := _UpdaterTest_OperationLeaseActiveOrFalse()
		if IsObject(this.SendInterleave)
			this.SendInterleave.Call()
		this.State.TerminalsInsideSend := this.State.Terminals
		this.State.AbortsInsideSend := this.State.Aborts
		return true
	}

	WaitForResponse(*) {
		this.State.Waits += 1
		this.State.LeaseInsideWait := _UpdaterTest_OperationLeaseActiveOrFalse()
		if IsObject(this.WaitInterleave)
			this.WaitInterleave.Call()
		this.State.TerminalsInsideWait := this.State.Terminals
		this.State.AbortsInsideWait := this.State.Aborts
		return false
	}

	GetResponseHeader(*) {
		return ""
	}

	Abort() {
		this.State.Aborts += 1
		if this.ThrowOnAbort
			throw Error("deterministic Abort failure")
		return true
	}
}

_UpdaterTest_CaptureOperationLeaseTerminal(State, Json, Request,
	Terminal := 0) {
	State.LeaseAtTerminal := _UpdaterTest_OperationLeaseActiveOrFalse()
	State.AbortsAtTerminal := State.Aborts
	_UpdaterTest_CaptureOwnedPreparationTerminal(
		State, Json, Request, Terminal)
}

_UpdaterTest_CancelOperationLease(State, Transport := 0, *) {
	global UPDATER_CANCEL_REASON_SUSPEND
	State.LeaseDuringCancel := _UpdaterTest_OperationLeaseActiveOrFalse()
	_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
	State.TerminalsDuringCancel := State.Terminals
	State.AbortsDuringCancel := State.Aborts
	return Transport
}

_UpdaterTest_CancelThenThrowOwnedPreparation(State, *) {
	global UPDATER_CANCEL_REASON_SUSPEND
	State.LeaseDuringCancel := _UpdaterTest_OperationLeaseActiveOrFalse()
	_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
	State.TerminalsDuringCancel := State.Terminals
	throw Error("deterministic preparation throw after cancellation")
}

_UpdaterTest_NewOperationLeaseState() {
	return { Sends: 0, Waits: 0, Aborts: 0, Polls: 0,
		Terminals: 0, Json: "not-called", CompletedRequest: 0,
		Terminal: 0, LeaseDuringCancel: false,
		LeaseInsideSend: false, LeaseInsideWait: false,
		LeaseAtTerminal: false, AbortsAtTerminal: -1,
		TerminalsDuringCancel: -1, AbortsDuringCancel: -1,
		TerminalsInsideSend: -1, AbortsInsideSend: -1,
		TerminalsInsideWait: -1, AbortsInsideWait: -1 }
}

_UpdaterTest_SendLeaseCancelsBeforeCommit() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewOperationLeaseState()
		Http := _UpdaterTestOperationLeaseHttp(State)
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		Owner := RegisterOwner.Call(
			Http, "main",
			_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
			"test://cancel-before-send-commit", Request)
		PrepareFn := _UpdaterTest_CancelOperationLease.Bind(State, Http)
		PollFn := (Id) => (State.Polls += 1, true)

		AssertEqual(false, SendOwned.Call(
			Owner, PollFn, "test cancel before Send commit", PrepareFn),
			"cancellation after lease acquisition must win before COM Send")
		AssertEqual(0, State.TerminalsDuringCancel,
			"leased cancellation must defer its callback until release")
		AssertEqual(0, State.AbortsDuringCancel,
			"leased cancellation must not Abort a transport still on the stack")
		AssertEqual(true, State.LeaseDuringCancel,
			"the deterministic cancellation must run under the exact lease")
		AssertEqual(0, State.Sends,
			"cancel-before-commit must prevent Send")
		AssertEqual(1, State.Aborts,
			"lease release must abort the cancelled exact transport once")
		AssertEqual(1, State.Terminals,
			"lease release must deliver one cancellation terminal")
		AssertEqual(true, State.LeaseAtTerminal,
			"deferred callback return must remain inside published quiescence")
		AssertEqual(1, State.AbortsAtTerminal,
			"deferred callback must observe its transport already aborted")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
			and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
			"lease release must preserve the typed suspend terminal")
		AssertEqual(0, State.Polls,
			"cancel-before-commit must never hand off to polling")
		AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
			"every sender exit must release operation quiescence")
		AssertEqual(0, _UpdaterActiveSendLeaseCount,
			"the exact operation-lease count must return to zero")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"cancel-before-commit must leave no registry owner")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: lease closes cancel-before-Send window (updater-operation-lease)",
	_UpdaterTest_SendLeaseCancelsBeforeCommit)

_UpdaterTest_SendStackDefersCancellationTerminal() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewOperationLeaseState()
		InterleaveFn := _UpdaterTest_CancelOperationLease.Bind(State)
		Http := _UpdaterTestOperationLeaseHttp(State, InterleaveFn)
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		Owner := RegisterOwner.Call(
			Http, "main",
			_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
			"test://cancel-inside-send", Request)

		AssertEqual(false, SendOwned.Call(
			Owner, (Id) => (State.Polls += 1, true),
			"test cancellation inside Send"),
			"cancellation pumped by Send must own the terminal")
		AssertEqual(true, State.LeaseInsideSend,
			"the exact lease must remain active through return from Send")
		AssertEqual(0, State.TerminalsInsideSend,
			"Send-stack cancellation must not re-enter its callback")
		AssertEqual(0, State.AbortsInsideSend,
			"Send-stack cancellation must not Abort the active COM frame")
		AssertEqual(1, State.Sends,
			"the deterministic Send interleave must execute once")
		AssertEqual(1, State.Aborts,
			"release after Send must abort the retired transport once")
		AssertEqual(1, State.Terminals,
			"release after Send must terminal exactly once")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
			and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
			"Send-stack cancellation must retain its typed reason")
		AssertEqual(0, State.Polls,
			"a Send cancelled on its stack must never start polling")
		AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
			"Send return must release operation quiescence")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"Send cancellation must leave no registry owner")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Send-stack cancellation defers terminal (updater-operation-lease)",
	_UpdaterTest_SendStackDefersCancellationTerminal)

_UpdaterTest_CancellationOwnsPreparationThrowTerminal() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewOperationLeaseState()
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
			"test://cancel-then-prepare-throw", Request)

		AssertEqual(false, SendOwned.Call(
			Owner, (Id) => (State.Polls += 1, true),
			"test cancel and preparation throw",
			_UpdaterTest_CancelThenThrowOwnedPreparation.Bind(State)),
			"cancellation must win over a simultaneous preparation exception")
		AssertEqual(true, State.LeaseDuringCancel,
			"preparation must run inside the operation lease")
		AssertEqual(0, State.TerminalsDuringCancel,
			"preparation cancellation must defer while its frame unwinds")
		AssertEqual(1, State.Terminals,
			"cancel plus throw must deliver only one terminal")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
			and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
			"cancellation, not the sibling exception, must own the terminal")
		AssertEqual(0, State.Sends,
			"a cancelled throwing preparation must never reach Send")
		AssertEqual(0, State.Polls,
			"a cancelled throwing preparation must never start polling")
		AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
			"preparation unwind must release operation quiescence")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"cancel plus throw must leave no registry owner")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: cancellation owns simultaneous preparation throw (updater-operation-lease)",
	_UpdaterTest_CancellationOwnsPreparationThrowTerminal)

_UpdaterTest_BothPollComPathsDeferCancellation() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	LatestPoll := _UpdaterTest_ResolveFunction("_Updater_PollAsync")
	ReleasesPoll := _UpdaterTest_ResolveFunction("_Updater_PollReleasesListAsync")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		for Name, PollFn in Map(
				"latest", LatestPoll,
				"releases", ReleasesPoll) {
			_UpdaterTest_ResetRequestState()
			State := _UpdaterTest_NewOperationLeaseState()
			InterleaveFn := _UpdaterTest_CancelOperationLease.Bind(State)
			Http := _UpdaterTestOperationLeaseHttp(State, 0, InterleaveFn)
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
			Owner := RegisterOwner.Call(
				Http, "main",
				_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
				"test://cancel-inside-" . Name . "-poll", Request)

			AssertEqual(false, PollFn.Call(Owner.Id),
				Name . " cancellation pumped by WaitForResponse must retire the poll")
			AssertEqual(true, State.LeaseInsideWait,
				Name . " WaitForResponse must execute under the exact operation lease")
			AssertEqual(0, State.TerminalsInsideWait,
				Name . " poll cancellation must defer its callback until COM returns")
			AssertEqual(0, State.AbortsInsideWait,
				Name . " poll cancellation must not Abort the active COM frame")
			AssertEqual(1, State.Waits,
				Name . " poll must execute its deterministic wait once")
			AssertEqual(1, State.Aborts,
				Name . " poll release must abort the cancelled transport once")
			AssertEqual(1, State.Terminals,
				Name . " poll release must deliver exactly one terminal")
			Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
				and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
				Name . " poll must retain the typed cancellation reason")
			AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
				Name . " poll exit must release operation quiescence")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				Name . " cancelled poll must leave no registry owner")
		}
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: both poll COM paths defer cancellation (updater-operation-lease)",
	_UpdaterTest_BothPollComPathsDeferCancellation)

_UpdaterTest_AbortFailureStillDeliversCancellation() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := _UpdaterTest_NewOperationLeaseState()
		Http := _UpdaterTestOperationLeaseHttp(State, 0, 0, true)
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		RegisterOwner.Call(
			Http, "main",
			_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
			"test://throwing-abort", Request)

		_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)

		AssertEqual(1, State.Aborts,
			"direct cancellation must attempt its exact transport Abort once")
		AssertEqual(1, State.Terminals,
			"an Abort exception must not suppress the typed terminal callback")
		AssertEqual(1, State.AbortsAtTerminal,
			"the terminal callback must run after the failed Abort attempt")
		AssertEqual(false, State.LeaseAtTerminal,
			"a transport between polls must cancel without inventing a COM lease")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal)
			and State.Terminal.Reason == UPDATER_CANCEL_REASON_SUSPEND,
			"Abort failure must preserve the typed cancellation reason")
		AssertEqual(0, _UpdaterActiveSendLeaseCount,
			"direct cancellation must not leak operation quiescence")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"direct cancellation must retire registry ownership before Abort")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Abort failure cannot suppress cancellation (updater-operation-lease)",
	_UpdaterTest_AbortFailureStillDeliversCancellation)

_UpdaterTest_PollHandoffFailureCannotLeakOwner() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		for Mode in ["invalid", "false"] {
			_UpdaterTest_ResetRequestState()
			State := _UpdaterTest_NewOperationLeaseState()
			Http := _UpdaterTestOperationLeaseHttp(State)
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
			Owner := RegisterOwner.Call(
				Http, "main",
				_UpdaterTest_CaptureOperationLeaseTerminal.Bind(State),
				"test://poll-handoff-" . Mode, Request)
			PollFn := Mode == "invalid" ? 0 : (Id) => false

			AssertEqual(false, SendOwned.Call(
				Owner, PollFn, "test poll handoff " . Mode),
				Mode . " poll handoff must fail closed")
			AssertEqual(Mode == "invalid" ? 0 : 1, State.Sends,
				"validation must precede Send while false handoff follows it")
			AssertEqual(1, State.Aborts,
				Mode . " handoff failure must abort its exact transport")
			AssertEqual(1, State.Terminals,
				Mode . " handoff failure must callback exactly once")
			AssertEqual(0, State.Terminal,
				Mode . " handoff failure must not impersonate cancellation")
			AssertEqual(false, _UpdaterTest_OperationLeaseActiveOrFalse(),
				Mode . " handoff failure must release operation quiescence")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				Mode . " handoff failure must leave no registry owner")
		}
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: poll handoff failure cannot leak owner (updater-operation-lease)",
	_UpdaterTest_PollHandoffFailureCannotLeakOwner)

_UpdaterTest_BackgroundSchedule(State, TimerFn, DelayMs) {
	State.Calls += 1
	if (DelayMs == 0) {
		State.Disarms += 1
		Loop State.Pending.Length {
			if ObjPtr(State.Pending[A_Index]) == ObjPtr(TimerFn) {
				State.Pending.RemoveAt(A_Index)
				break
			}
		}
		return true
	}
	if State.InlineNext {
		State.InlineNext := false
		TimerFn.Call()
		return true
	}
	if State.HasOwnProp("InterleaveFn") and IsObject(State.InterleaveFn) {
		InterleaveFn := State.InterleaveFn
		State.InterleaveFn := 0
		InterleaveFn.Call()
	}
	State.Pending.Push(TimerFn)
	return true
}

_UpdaterTest_ReplaceBackgroundOwnerDuringArm(State, ScheduleFn) {
	global _UpdaterBackgroundOwner
	State.Interleaves += 1
	Updater_StopBackgroundChecks(false)
	Updater_StartBackgroundChecks(ScheduleFn, false)
	State.SuccessorOwner := _UpdaterBackgroundOwner
}

_UpdaterTest_BackgroundOwnerRejectsStaleTick() {
	global UPDATER_CHECK_INTERVAL, _UpdaterBackgroundFn
	global _UpdaterBackgroundOwner, _UpdaterBackgroundOwnerCounter
	global _UpdaterAsyncRequests
	SavedRequests := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadFn := IsSet(_UpdaterBackgroundFn)
	if HadFn
		SavedFn := _UpdaterBackgroundFn
	HadOwner := IsSet(_UpdaterBackgroundOwner)
	if HadOwner
		SavedOwner := _UpdaterBackgroundOwner
	HadCounter := IsSet(_UpdaterBackgroundOwnerCounter)
	if HadCounter
		SavedCounter := _UpdaterBackgroundOwnerCounter
	try {
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		_UpdaterBackgroundOwnerCounter := 0
		State := { Calls: 0, Disarms: 0, InlineNext: true, Pending: [],
			InterleaveFn: 0, Interleaves: 0, SuccessorOwner: 0 }
		ScheduleFn := _UpdaterTest_BackgroundSchedule.Bind(State)

		AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
			"Start must replace an inline-consumed arm with one future owner")
		AssertEqual(2, State.Calls,
			"the inline callback must consume A and force one bounded B arm")
		AssertEqual(1, State.Pending.Length,
			"successful Start must own exactly one demonstrably future callback")
		OldTick := State.Pending[1]
		OldOwner := _UpdaterBackgroundOwner
		AssertEqual(true, Updater_StopBackgroundChecks(false),
			"Stop must retire and disarm the exact first owner")
		AssertEqual(0, State.Pending.Length,
			"retiring the first owner must remove its pending timer")
		AssertEqual(false, IsObject(OldOwner.TimerFn),
			"Stop must break the retired Owner-BoundFunc reference cycle")

		AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
			"Start after Stop must publish a successor owner")
		NewOwner := _UpdaterBackgroundOwner
		NewTick := State.Pending[1]
		Assert(NewOwner.Id > OldOwner.Id,
			"Stop-Start must use a monotone owner epoch")
		CallsBeforeStale := State.Calls
		AssertEqual(false, OldTick.Call(),
			"a queued callback from the retired owner must be inert")
		AssertEqual(CallsBeforeStale, State.Calls,
			"the stale callback must not arm a timer for the successor")
		AssertEqual(1, State.Pending.Length,
			"the successor must retain exactly its own pending callback")
		Assert(ObjPtr(State.Pending[1]) == ObjPtr(NewTick),
			"the stale callback must not replace the successor timer")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"the stale callback must not dispatch an HTTP request")

		; Stronger interleave: the current tick has already claimed MayRun when
		; its rearm scheduler pumps Stop -> Start. Its failed old-owner arm must
		; not globally stop the successor that now owns the cadence.
		State.Pending.RemoveAt(1)
		State.InterleaveFn := _UpdaterTest_ReplaceBackgroundOwnerDuringArm.Bind(
			State, ScheduleFn)
		OwnerBeforeInterleave := _UpdaterBackgroundOwner
		AssertEqual(false, NewTick.Call(),
			"an old tick displaced during rearm must retire without dispatch")
		AssertEqual(1, State.Interleaves,
			"the scheduler must execute the deterministic Stop-Start interleave")
		Assert(IsObject(State.SuccessorOwner)
			and ObjPtr(State.SuccessorOwner) == ObjPtr(_UpdaterBackgroundOwner)
			and ObjPtr(_UpdaterBackgroundOwner) != ObjPtr(OwnerBeforeInterleave),
			"the reentrant Start successor must remain the published owner")
		AssertEqual(false, IsObject(OwnerBeforeInterleave.TimerFn),
			"a displaced arm must disarm its callback and break its owner cycle")
		Assert(_UpdaterBackgroundOwner.Active
			and _UpdaterBackgroundOwner.Armed
			and _UpdaterBackgroundOwner.Phase == "armed",
			"the displaced tick must not stop the successor cadence")
		AssertEqual(1, State.Pending.Length,
			"detached old-arm cleanup must leave only the successor callback")
		Assert(ObjPtr(State.Pending[1])
			== ObjPtr(_UpdaterBackgroundOwner.TimerFn),
			"the sole remaining timer must belong to the successor owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"the displaced tick must not dispatch after losing its arm owner")
		Updater_StopBackgroundChecks(false)
		AssertEqual(false, IsObject(State.SuccessorOwner.TimerFn),
			"final Stop must release the successor BoundFunc cycle")
	} finally {
		UPDATER_CHECK_INTERVAL := SavedInterval
		if HadFn
			_UpdaterBackgroundFn := SavedFn
		else
			_UpdaterBackgroundFn := unset
		if HadOwner
			_UpdaterBackgroundOwner := SavedOwner
		else
			_UpdaterBackgroundOwner := unset
		if HadCounter
			_UpdaterBackgroundOwnerCounter := SavedCounter
		else
			_UpdaterBackgroundOwnerCounter := unset
		_UpdaterTest_RestoreRequestState(SavedRequests)
	}
}
Test("Updater AHK-31: stale Stop-Start tick cannot adopt its successor (updater-background-owner-epoch)",
	_UpdaterTest_BackgroundOwnerRejectsStaleTick)

_UpdaterTest_BeginBoundaryDuringBackgroundArm(State) {
	State.Interleaves += 1
	State.BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary(
		"channel switch")
}

_UpdaterTest_BackgroundArmCannotCrossChannelBoundary() {
	global UPDATER_CHECK_INTERVAL, _UpdaterBackgroundFn
	global _UpdaterBackgroundOwner, _UpdaterBackgroundOwnerCounter
	global _UpdaterAsyncRequests
	Saved := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	HadFn := IsSet(_UpdaterBackgroundFn)
	if HadFn
		SavedFn := _UpdaterBackgroundFn
	HadOwner := IsSet(_UpdaterBackgroundOwner)
	if HadOwner
		SavedOwner := _UpdaterBackgroundOwner
	SavedCounter := _UpdaterBackgroundOwnerCounter
	try {
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Calls: 0, Disarms: 0, InlineNext: false,
			Pending: [], InterleaveFn: 0, Interleaves: 0,
			BoundaryOwner: 0 }
		ScheduleFn := _UpdaterTest_BackgroundSchedule.Bind(State)
		AssertEqual(true, Updater_StartBackgroundChecks(ScheduleFn, false),
			"the ready-tick repro must begin with one armed owner")
		ReadyTick := State.Pending.RemoveAt(1)
		OldOwner := _UpdaterBackgroundOwner
		State.InterleaveFn := _UpdaterTest_BeginBoundaryDuringBackgroundArm.Bind(State)
		AssertEqual(false, ReadyTick.Call(),
			"a boundary acquired by the rearm scheduler must retire the ready tick")
		AssertEqual(1, State.Interleaves,
			"the scheduler must pump the deterministic channel boundary")
		Assert(IsObject(State.BoundaryOwner),
			"the reentrant channel boundary must own admission")
		AssertEqual(false, IsSet(_UpdaterBackgroundFn),
			"the detached rearm must not leave a dead callback published")
		AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
			"the detached rearm must not leave a dead cadence owner")
		AssertEqual(false, IsObject(OldOwner.TimerFn),
			"detached cleanup must break the exact BoundFunc cycle")
		AssertEqual(0, State.Pending.Length,
			"detached cleanup must disarm the scheduler's callback")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"a tick that crossed channel admission must not dispatch HTTP")
		_Updater_EndAsyncAdmissionBoundary(State.BoundaryOwner)
		State.BoundaryOwner := 0

		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		StateTwo := { Calls: 0, Disarms: 0, InlineNext: false,
			Pending: [], InterleaveFn: 0, Interleaves: 0,
			BoundaryOwner: 0 }
		StateTwo.InterleaveFn :=
			_UpdaterTest_BeginBoundaryDuringBackgroundArm.Bind(StateTwo)
		AssertEqual(false, Updater_StartBackgroundChecks(
			_UpdaterTest_BackgroundSchedule.Bind(StateTwo), false),
			"initial Start must fail if its scheduler opens a channel boundary")
		AssertEqual(false, IsSet(_UpdaterBackgroundFn),
			"failed initial arm must unpublish its callback")
		AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
			"failed initial arm must retire its owner")
		AssertEqual(0, StateTwo.Pending.Length,
			"failed initial arm must disarm the detached timer")
		_Updater_EndAsyncAdmissionBoundary(StateTwo.BoundaryOwner)
		StateTwo.BoundaryOwner := 0
	} finally {
		if IsObject(State.BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(State.BoundaryOwner)
		if IsSet(StateTwo) and IsObject(StateTwo.BoundaryOwner)
			_Updater_EndAsyncAdmissionBoundary(StateTwo.BoundaryOwner)
		try Updater_StopBackgroundChecks(false)
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterBackgroundOwnerCounter := SavedCounter
		if HadFn
			_UpdaterBackgroundFn := SavedFn
		else
			_UpdaterBackgroundFn := unset
		if HadOwner
			_UpdaterBackgroundOwner := SavedOwner
		else
			_UpdaterBackgroundOwner := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: background arm cannot cross channel admission (updater-channel-replacement-transaction)",
	_UpdaterTest_BackgroundArmCannotCrossChannelBoundary)





#Include updater/test_global_config_admission.ahk
