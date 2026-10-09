; tests/unit/updater/test_global_config_admission.ahk

; ==============================================================================
; MODULE: Updater Global Configuration Admission Tests
; DESCRIPTION:
; Configuration leases cover preference writes, reload recovery and publication.
; Shared updater fixtures remain owned by the including test module.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= AHK-34/ Global config admission =======
; ===============================================
; ===============================================

_UpdaterTest_GlobalBarrierWriter(State, Args*) {
	global ConfigurationFile
	State.Writes += 1
	State.TerminalDuringWrite := _ConfigWriteTerminalIsActive()
	if State.HasOwnProp("CaptureWriterArgs") && State.CaptureWriterArgs
		State.WriterArgs := Args
	if State.HasOwnProp("ProbeCompetingTerminal")
		&& State.ProbeCompetingTerminal {
		Competing := _ConfigWriteTerminalTryAcquire([
			ConfigurationFile . ".writer-sibling"])
		State.CompetingTerminalAdmitted := Competing is Object
		if Competing is Object
			_ConfigWriteTerminalRelease(Competing)
	}
	return State.HasOwnProp("WriteResult") ? State.WriteResult : true
}

_UpdaterTest_GlobalBarrierMenuSchedule(State, Args*) {
	State.MenuSchedules += 1
	return true
}

_UpdaterTest_GlobalBarrierMenuMutatesLive(State, Args*) {
	global UPDATER_CHECK_INTERVAL
	State.MenuSchedules += 1
	; Models a yielding scheduler that dispatches a stale direct writer before
	; returning its strict acknowledgement to the owned transaction.
	UPDATER_CHECK_INTERVAL := 999
	return true
}

_UpdaterTest_GlobalBarrierReload(State, Args*) {
	State.Reloads += 1
	State.TerminalDuringReload := _ConfigWriteTerminalIsActive()
	return State.HasOwnProp("ReloadResult") ? State.ReloadResult : true
}

_UpdaterTest_GlobalBarrierReloadSchedule(State, Continuation, DelayMs) {
	State.ReloadSchedules += 1
	State.ReloadContinuation := Continuation
	return true
}

_UpdaterTest_GlobalBarrierRecovery(State, Args*) {
	global ConfigurationFile
	State.Recoveries += 1
	State.TerminalDuringRecovery := _ConfigWriteTerminalIsActive()
	Competing := _ConfigWriteLeaseTryAcquire(
		ConfigurationFile . ".recovery-sibling")
	State.SiblingAdmittedDuringRecovery := Competing is Object
	if Competing is Object
		_ConfigWriteLeaseRelease(Competing)
	return true
}

_UpdaterTest_GlobalTerminalRefusesPreferencesBeforeEffects() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterDownloadInProgress, _UpdaterChannelEpoch
	global _UpdaterFetchCache, _UpdaterPendingReleaseNotification
	global UPDATER_LATEST_RELEASE, ConfigurationFile
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	SavedChannel := UPDATER_CHANNEL
	SavedEpoch := _UpdaterChannelEpoch
	SavedCache := _UpdaterFetchCache
	SavedPending := _UpdaterPendingReleaseNotification
	HadLatest := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatest
		SavedLatest := UPDATER_LATEST_RELEASE
	Barrier := 0
	try {
		try Updater_StopBackgroundChecks(false)
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		UPDATER_CHANNEL := "main"
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Writes: 0, MenuSchedules: 0,
			Reloads: 0, ReloadSchedules: 0, Notices: 0,
			TerminalDuringWrite: false }
		Barrier := _ConfigWriteTerminalTryAcquire([
			ConfigurationFile . ".unrelated-terminal-target"])
		Assert(IsObject(Barrier),
			"the repro must own a process-wide sibling-path terminal barrier")
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)

		AssertEqual(false, Updater_SetCheckInterval(
			120, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierMenuSchedule.Bind(State)),
			"a sibling terminal barrier must refuse interval persistence")
		AssertEqual(false, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierReload.Bind(State),
			_UpdaterTest_GlobalBarrierReloadSchedule.Bind(State)),
			"a sibling terminal barrier must refuse channel persistence")
		AssertEqual(0, State.Writes,
			"terminal collision must stop before either injected writer")
		AssertEqual(0, State.MenuSchedules,
			"terminal collision must not schedule a menu rebuild")
		AssertEqual(0, State.ReloadSchedules,
			"terminal collision must not publish a deferred Reload")
		AssertEqual(0, State.Reloads,
			"terminal collision must not invoke Reload")
		AssertEqual(60, UPDATER_CHECK_INTERVAL,
			"terminal collision must retain the prior live interval")
		AssertEqual("main", UPDATER_CHANNEL,
			"terminal collision must retain the prior live channel")
		AssertEqual(false, IsSet(_UpdaterBackgroundFn),
			"terminal collision must not arm or retire a timer callback")
		AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
			"terminal collision must not publish a cadence owner")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"global collision must not leak updater-local admission")
		AssertEqual(false, _Updater_ChannelReloadTransitionActive(),
			"global collision must not leak a deferred transition")
		AssertEqual(2, State.Notices,
			"each refused user preference must remain visibly terminal")
	} finally {
		if IsObject(Barrier)
			_ConfigWriteTerminalRelease(Barrier)
		try Updater_StopBackgroundChecks(false)
		_UpdaterDownloadInProgress := SavedDownload
		UPDATER_CHECK_INTERVAL := SavedInterval
		UPDATER_CHANNEL := SavedChannel
		_UpdaterChannelEpoch := SavedEpoch
		_UpdaterFetchCache := SavedCache
		_UpdaterPendingReleaseNotification := SavedPending
		if HadLatest
			UPDATER_LATEST_RELEASE := SavedLatest
		else
			UPDATER_LATEST_RELEASE := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-34: global terminal collision precedes all preference effects (updater-global-config-barrier)",
	_UpdaterTest_GlobalTerminalRefusesPreferencesBeforeEffects)

_UpdaterTest_ChannelRetainsGlobalBundleThroughReloadRecovery() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterDownloadInProgress, _UpdaterChannelEpoch
	global _UpdaterFetchCache, _UpdaterPendingReleaseNotification
	global UPDATER_LATEST_RELEASE, ConfigurationFile
	Saved := _UpdaterTest_SaveRequestState()
	SavedDownload := _UpdaterDownloadInProgress
	SavedInterval := UPDATER_CHECK_INTERVAL
	SavedChannel := UPDATER_CHANNEL
	SavedEpoch := _UpdaterChannelEpoch
	SavedCache := _UpdaterFetchCache
	SavedPending := _UpdaterPendingReleaseNotification
	HadLatest := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatest
		SavedLatest := UPDATER_LATEST_RELEASE
	try {
		try Updater_StopBackgroundChecks(false)
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		UPDATER_CHANNEL := "main"
		UPDATER_CHECK_INTERVAL := 0
		State := { Writes: 0, WriteResult: true,
			TerminalDuringWrite: false, ReloadSchedules: 0,
			ReloadContinuation: 0, Reloads: 0,
			ReloadResult: false, TerminalDuringReload: false,
			Recoveries: 0, TerminalDuringRecovery: false,
			SiblingAdmittedDuringRecovery: true, Notices: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(true, _UpdaterTest_ResolveFunction(
			"Updater_SetChannel").Call(
			"dev", Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierReload.Bind(State),
			_UpdaterTest_GlobalBarrierReloadSchedule.Bind(State),
			0,
			_UpdaterTest_GlobalBarrierRecovery.Bind(State)),
			"a durable channel change must transfer its exact bundle to Reload")
		AssertEqual(1, State.Writes,
			"channel durability must be attempted once")
		AssertEqual(true, State.TerminalDuringWrite,
			"channel persistence must borrow the process-wide terminal owner")
		AssertEqual(true, _ConfigWriteTerminalIsActive(),
			"the deferred transition must retain global admission after the setter returns")
		CompetingWriter := _ConfigWriteLeaseTryAcquire(
			ConfigurationFile . ".deferred-sibling")
		CompetingWriterAdmitted := CompetingWriter is Object
		if CompetingWriterAdmitted
			_ConfigWriteLeaseRelease(CompetingWriter)
		AssertEqual(false, CompetingWriterAdmitted,
			"no sibling writer may enter while deferred Reload is alive")
		AssertEqual(1, State.ReloadSchedules,
			"the transition must own exactly one deferred Reload callback")
		Assert(HasMethod(State.ReloadContinuation, "Call"),
			"the deferred Reload callback must remain callable")
		AssertEqual(false, State.ReloadContinuation.Call(),
			"the deterministic Reload refusal must enter owned recovery")
		AssertEqual(1, State.Reloads,
			"the deferred Reload seam must run once")
		AssertEqual(true, State.TerminalDuringReload,
			"the global bundle must remain active on the Reload stack")
		AssertEqual(1, State.Recoveries,
			"Reload refusal must run one exact recovery")
		AssertEqual(true, State.TerminalDuringRecovery,
			"recovery must retain the same global bundle")
		AssertEqual(false, State.SiblingAdmittedDuringRecovery,
			"recovery must still exclude every sibling config writer")
		AssertEqual(false, _ConfigWriteTerminalIsActive(),
			"completed recovery must release the exact terminal bundle")
		AssertEqual(false, _Updater_AsyncAdmissionBoundaryActive(),
			"completed recovery must consume updater-local admission")
		AssertEqual("dev", UPDATER_CHANNEL,
			"Reload refusal occurs after the durable live channel commit")
	} finally {
		try Updater_StopBackgroundChecks(false)
		UPDATER_CHANNEL := SavedChannel
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterDownloadInProgress := SavedDownload
		_UpdaterChannelEpoch := SavedEpoch
		_UpdaterFetchCache := SavedCache
		_UpdaterPendingReleaseNotification := SavedPending
		if HadLatest
			UPDATER_LATEST_RELEASE := SavedLatest
		else
			UPDATER_LATEST_RELEASE := unset
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-34: channel Reload retains global config ownership through recovery (updater-global-config-barrier)",
	_UpdaterTest_ChannelRetainsGlobalBundleThroughReloadRecovery)

_UpdaterTest_IntervalWriterFailureCannotPublishStaleLiveState() {
	global UPDATER_CHECK_INTERVAL, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_INTERVAL_KEY
	Saved := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		try Updater_StopBackgroundChecks(false)
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Writes: 0, WriteResult: false,
			TerminalDuringWrite: false, MenuSchedules: 0,
			Notices: 0, ProbeCompetingTerminal: true,
			CompetingTerminalAdmitted: true, CaptureWriterArgs: true,
			WriterArgs: [] }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(false, Updater_SetCheckInterval(
			120, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierMenuSchedule.Bind(State)),
			"a strict false writer must reject the interval transaction")
		AssertEqual(1, State.Writes,
			"the strict writer seam must run exactly once")
		AssertEqual(4, State.WriterArgs.Length,
			"the owned gateway must preserve the legacy four-argument writer seam")
		AssertEqual(120, State.WriterArgs[1],
			"the legacy writer must still receive the requested value first")
		AssertEqual(ConfigurationFile, State.WriterArgs[2],
			"the legacy writer must still receive the exact config path second")
		AssertEqual(UPDATER_INI_SECTION, State.WriterArgs[3],
			"the legacy writer must still receive the updater section third")
		AssertEqual(UPDATER_INI_INTERVAL_KEY, State.WriterArgs[4],
			"the legacy writer must still receive the interval key fourth")
		AssertEqual(false, State.TerminalDuringWrite,
			"ordinary interval persistence must own a path lease, not a terminal bundle")
		AssertEqual(false, State.CompetingTerminalAdmitted,
			"the owned writer must prevent a process-wide terminal from interleaving")
		AssertEqual(60, UPDATER_CHECK_INTERVAL,
			"writer failure must retain the exact old live preference")
		AssertEqual(0, State.MenuSchedules,
			"writer failure must not reach native menu handoff")
		AssertEqual(false, IsSet(_UpdaterBackgroundFn),
			"writer failure must not retire or arm a cadence callback")
		AssertEqual(false, IsObject(_UpdaterBackgroundOwner),
			"writer failure must not publish a cadence owner")
		AssertEqual(1, State.Notices,
			"writer failure must have one visible terminal")
	} finally {
		try Updater_StopBackgroundChecks(false)
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-34: interval writer owns config before failure publication (updater-global-config-barrier)",
	_UpdaterTest_IntervalWriterFailureCannotPublishStaleLiveState)

_UpdaterTest_IntervalPublicationReassertsDurableCandidate() {
	global UPDATER_CHECK_INTERVAL, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	Saved := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		try Updater_StopBackgroundChecks(false)
		_UpdaterTest_ResetRequestState()
		UPDATER_CHECK_INTERVAL := 60
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		State := { Writes: 0, WriteResult: true,
			TerminalDuringWrite: false, MenuSchedules: 0,
			Notices: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(true, Updater_SetCheckInterval(
			120, Request, false,
			_UpdaterTest_RecordChannelNotice.Bind(State),
			_UpdaterTest_GlobalBarrierWriter.Bind(State),
			_UpdaterTest_GlobalBarrierMenuMutatesLive.Bind(State)),
			"an acknowledged native handoff must commit the interval transaction")
		AssertEqual(1, State.Writes,
			"the successful transaction must write its durable candidate once")
		AssertEqual(1, State.MenuSchedules,
			"the deterministic yielding scheduler must run once")
		AssertEqual(120, UPDATER_CHECK_INTERVAL,
			"owned publication must replace a stale live mutation with the durable candidate")
		AssertEqual(0, State.Notices,
			"the recovered live candidate must not emit a false failure terminal")
	} finally {
		try Updater_StopBackgroundChecks(false)
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-34: interval publication replaces stale reentrant live state (updater-global-config-barrier)",
	_UpdaterTest_IntervalPublicationReassertsDurableCandidate)
