; tests/meta/modules/updater/test_updater_setcheckinterval_coerces.ahk

; ==============================================================================
; MODULE: Updater_SetCheckInterval Coercion Meta Test
; DESCRIPTION:
; Static source guard for the "updater-setcheckinterval-type-guard-rejects-non-
; integer" finding.
;
; The old guard `if (Type(Seconds) != "Integer" or Seconds < 0) return` was an
; exact-type test: a valid cadence arriving as a String ("300") or Float (300.0)
; — entirely plausible from a config migration, since Updater_LoadCheckInterval
; reads strings from TOML — would silently fail it. The early return was also
; silent (no LoggerWarn), so a mis-typed value disappeared without a trace,
; violating the fail-loud / setter-logging conventions.
;
; The fix coerces with Integer() inside a try, rejects only genuinely invalid
; (non-numeric or negative) input, and LoggerWarn's on rejection. The real setter
; runs here against its writer and menu seams and a private configuration file.
;
; If the exact-type rejection regresses, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Coercion and refusal ==================
; ==================================================
; ==================================================

; Calls the setter with a private request. Cadence 0 stops the background checks,
; so these cases arm no timer whatever they exercise.
_USCI_Call(Seconds, State) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
	return Updater_SetCheckInterval(Seconds, Request, false,
		_UpdaterTest_RecordChannelNotice.Bind(State),
		_UpdaterTest_CountUnexpectedSettingsWrite.Bind(State),
		_UpdaterTest_AcceptMenuSchedule.Bind(State))
}

_USCI_WithRequestState(Body) {
	global UPDATER_CHECK_INTERVAL
	Saved := _UpdaterTest_SaveRequestState()
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		_UpdaterTest_ResetRequestState()
		Body.Call()
	} finally {
		UPDATER_CHECK_INTERVAL := SavedInterval
		_UpdaterTest_RestoreRequestState(Saved)
	}
}

_USCI_CoercesInsteadOfExactTypeReject() {
	global UPDATER_CHECK_INTERVAL
	for Cadence in ["0", 0.0, 0] {
		UPDATER_CHECK_INTERVAL := 60
		State := {Writes: 0, Notices: 0, MenuSchedules: 0}
		AssertEqual(true, _USCI_Call(Cadence, State), "a " . Type(Cadence) . " cadence is valid")
		AssertEqual(1, State.Writes, "a " . Type(Cadence) . " cadence persists once")
		AssertEqual(0, UPDATER_CHECK_INTERVAL, "a " . Type(Cadence) . " cadence is published")
		AssertTrue(UPDATER_CHECK_INTERVAL is Integer, "the published cadence is an integer")
	}
}
Test("updater: Updater_SetCheckInterval coerces instead of exact-type reject (updater-setcheckinterval-type-guard-rejects-non-integer)",
	_UpdaterTest_WithCurrentConfiguration.Bind(_USCI_WithRequestState.Bind(_USCI_CoercesInsteadOfExactTypeReject)))

_USCI_LogsOnRejection() {
	global UPDATER_CHECK_INTERVAL, _LOGGER_WARN_ENABLED
	SavedWarn := _LOGGER_WARN_ENABLED
	_LOGGER_WARN_ENABLED := true
	Lines := []
	LoggerSetTestSink((Line) => InStr(Line, "[WARN") ? Lines.Push(Line) : 0)
	try {
		for Index, Invalid in ["soon", -5] {
			UPDATER_CHECK_INTERVAL := 60
			State := {Writes: 0, Notices: 0, MenuSchedules: 0}
			Assert(!_USCI_Call(Invalid, State), "an invalid cadence is refused")
			AssertEqual(0, State.Writes, "a refused cadence reaches no writer")
			AssertEqual(60, UPDATER_CHECK_INTERVAL, "a refused cadence publishes nothing")
			AssertEqual(Index, Lines.Length, "a refused cadence is visible in the log")
			AssertContains(Lines[Index], String(Invalid), "the warning names the refused value")
		}
	} finally {
		LoggerClearTestSink()
		_LOGGER_WARN_ENABLED := SavedWarn
	}
}
Test("updater: Updater_SetCheckInterval logs a warning on rejection (updater-setcheckinterval-type-guard-rejects-non-integer)",
	_UpdaterTest_WithCurrentConfiguration.Bind(_USCI_WithRequestState.Bind(_USCI_LogsOnRejection)))

_USCI_PersistsBeforePublishingTimerState() {
	Seg := _DriverFuncBody("Updater_SetCheckInterval")
	LeaseAt := InStr(Seg, "_Updater_AcquireAsyncActionLease(")
	CommitAt := InStr(Seg, "ConfigCommitBuilt(", , LeaseAt)
	ReleaseAt := InStr(Seg,
		"_Updater_ReleaseAsyncActionLease(", , CommitAt)
	Assert(LeaseAt > 0 and CommitAt > LeaseAt and ReleaseAt > CommitAt,
		"Updater_SetCheckInterval must hold updater admission around one globally owned transaction")
	Assert(InStr(Seg, "GatewayWriter := IsObject(WriteFn)", , LeaseAt) > LeaseAt,
		"the optional writer seam must preserve the legacy object-vs-default dispatch contract")
	Adapter := _DriverFuncBody("_Updater_InvokeLegacyConfigWriter")
	Assert(InStr(Adapter, 'HasMethod(WriteFn, "Call")') > 0
		and InStr(Adapter,
			"WriteFn.Call(Update.Value, Path, Update.Section, Update.Key)") > 0,
		"the owned gateway adapter must retain the legacy four-argument writer signature and refuse malformed objects")
	Plan := _DriverFuncBody("_Updater_BuildCheckIntervalPlan")
	Finalize := _DriverFuncBody("_Updater_FinalizeCheckInterval")
	Publish := _DriverFuncBody("_Updater_PublishCheckInterval")
	Restore := _DriverFuncBody("_Updater_RestoreCheckInterval")
	Assert(Plan != "" and Finalize != "" and Publish != ""
		and Restore != "",
		"the owned check-interval transaction helpers must remain discoverable")
	Assert(InStr(Plan, "rollback_updates:") > 0
		and InStr(Plan, "compensate:") > 0,
		"a native cadence failure must restore both old durability and old cadence")
	PublishAt := InStr(Finalize, "UPDATER_CHECK_INTERVAL := Seconds")
	StopAt := InStr(Finalize, "Updater_StopBackgroundChecks()")
	StartAt := InStr(Finalize,
		"Updater_StartBackgroundChecks()", , PublishAt)
	Assert(StopAt > 0 and PublishAt > StopAt and StartAt > PublishAt,
		"native cadence retirement, provisional publication and acknowledged re-arm must stay ordered under config ownership")
	Assert(InStr(Publish, "UPDATER_CHECK_INTERVAL := Seconds") > 0
		and InStr(Publish, "State.Published := true") > 0,
		"the gateway's non-yielding publication step must own the authoritative live preference")
	Assert(InStr(Restore, "State.OldSeconds") > 0
		and InStr(Restore, "State.CadenceWasRunning") > 0,
		"a failed writer/finalizer must retain the exact prior live cadence")
}
Test("updater: interval persistence commits before state/timer publication", _USCI_PersistsBeforePublishingTimerState)
