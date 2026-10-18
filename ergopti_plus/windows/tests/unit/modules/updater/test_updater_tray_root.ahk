; tests/unit/modules/updater/test_updater_tray_root.ahk

; ==============================================================================
; MODULE: Updater Tray-Root Publication
; DESCRIPTION:
; AHK-32: tray-root rebuilds recheck pause and generation after staging, and
; a pending root is replayed on resume with a strict terminal acknowledgement.
; ==============================================================================

#Requires AutoHotkey v2.0





_UpdaterTest_SaveTrayRootState() {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	return {
		Stage: _TrayMenuStage,
		RequestedGeneration: _TrayRootRequestedGeneration,
		PublishedGeneration: _TrayRootPublishedGeneration,
		Active: _TrayRootActive,
		LifecycleEpoch: _TrayRootLifecycleEpoch,
		LatestAuthorizeFn: _TrayRootLatestAuthorizeFn,
		LatestWorkerFn: _TrayRootLatestWorkerFn,
		RetryGeneration: _TrayRootRetryGeneration,
		AutomaticRetryCount: _TrayRootAutomaticRetryCount
	}
}

_UpdaterTest_ResetTrayRootState() {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	_TrayMenuStage := false
	_TrayRootRequestedGeneration := 0
	_TrayRootPublishedGeneration := 0
	_TrayRootActive := false
	_TrayRootLifecycleEpoch := 0
	_TrayRootLatestAuthorizeFn := 0
	_TrayRootLatestWorkerFn := 0
	_TrayRootRetryGeneration := 0
	_TrayRootAutomaticRetryCount := 0
}

_UpdaterTest_RestoreTrayRootState(Saved) {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	_TrayMenuStage := Saved.Stage
	_TrayRootRequestedGeneration := Saved.RequestedGeneration
	_TrayRootPublishedGeneration := Saved.PublishedGeneration
	_TrayRootActive := Saved.Active
	_TrayRootLifecycleEpoch := Saved.LifecycleEpoch
	_TrayRootLatestAuthorizeFn := Saved.LatestAuthorizeFn
	_TrayRootLatestWorkerFn := Saved.LatestWorkerFn
	_TrayRootRetryGeneration := Saved.RetryGeneration
	_TrayRootAutomaticRetryCount := Saved.AutomaticRetryCount
}

_UpdaterTest_StageThenSuspend(State, PublishAuthorizeFn) {
	State.StageCount += 1
	WasSuspended := A_IsSuspended
	if !WasSuspended
		Suspend(1)
	try {
		Authorized := PublishAuthorizeFn.Call()
		if ((Authorized is Integer) and Authorized == 1)
			State.PublishCount += 1
		return Authorized
	} finally {
		if !WasSuspended
			Suspend(0)
	}
}

_UpdaterTest_GenerationCallbackRechecksAfterStaging() {
	global _UpdaterPauseGeneration, _UpdaterMenuRebuildPending
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedTray := _UpdaterTest_SaveTrayRootState()
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterTest_ResetTrayRootState()
		AssertFalse(A_IsSuspended,
			"the causal pause repro must begin from a running driver")
		State := { StageCount: 0, PublishCount: 0 }
		Result := _Updater_RunMenuRebuildForGeneration(
			_UpdaterPauseGeneration,
			_UpdaterTest_StageThenSuspend.Bind(State))
		AssertFalse(Result,
			"a pause entered after detached staging must refuse terminal root publication")
		AssertEqual(1, State.StageCount,
			"the repro must cross the detached staging boundary exactly once")
		AssertEqual(0, State.PublishCount,
			"a root staged before pause must never become visible during that pause")
		AssertTrue(_UpdaterMenuRebuildPending,
			"terminal pause refusal must retain the updater menu obligation for resume")
	} finally {
		if A_IsSuspended
			Suspend(0)
		_UpdaterTest_RestoreTrayRootState(SavedTray)
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-32: generation rebuild rechecks pause after staging (updater-tray-terminal-authorization)",
	_UpdaterTest_GenerationCallbackRechecksAfterStaging)

_UpdaterTest_StageThenAdvanceGeneration(State, PublishAuthorizeFn) {
	global _UpdaterPauseGeneration
	State.StageCount += 1
	_UpdaterPauseGeneration += 1
	Authorized := PublishAuthorizeFn.Call()
	if ((Authorized is Integer) and Authorized == 1)
		State.PublishCount += 1
	return Authorized
}

_UpdaterTest_RequestCallbackRechecksGenerationAfterStaging() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, _UpdaterMenuRebuildPending
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedTray := _UpdaterTest_SaveTrayRootState()
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterTest_ResetTrayRootState()
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		State := { StageCount: 0, PublishCount: 0 }
		Result := _Updater_RunMenuRebuildForRequest(Request,
			_UpdaterTest_StageThenAdvanceGeneration.Bind(State))
		AssertFalse(Result,
			"a request invalidated after detached staging must refuse terminal root publication")
		AssertEqual(1, State.StageCount,
			"the request repro must cross the detached staging boundary exactly once")
		AssertEqual(0, State.PublishCount,
			"a stale request generation must not publish its detached tray root")
		AssertTrue(_UpdaterMenuRebuildPending,
			"terminal generation refusal must retain a fresh updater menu obligation")
	} finally {
		_UpdaterTest_RestoreTrayRootState(SavedTray)
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-32: request rebuild rechecks generation after staging (updater-tray-terminal-authorization)",
	_UpdaterTest_RequestCallbackRechecksGenerationAfterStaging)

_UpdaterTest_TerminalOutcomeWorker(Mode, PublishAuthorizeFn) {
	Authorized := PublishAuthorizeFn.Call()
	if !((Authorized is Integer) and Authorized == 1)
		return false
	switch Mode {
		case "false": return false
		case "malformed": return "1"
		case "throw": throw Error("deterministic tray-root worker failure")
	}
	return true
}

_UpdaterTest_TerminalFailuresRetainPendingObligation() {
	global _UpdaterPauseGeneration, _UpdaterMenuRebuildPending
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedTray := _UpdaterTest_SaveTrayRootState()
	try {
		for _, Mode in ["false", "malformed", "throw"] {
			_UpdaterTest_ResetRequestState()
			_UpdaterTest_ResetTrayRootState()
			Result := _Updater_RunMenuRebuildForGeneration(
				_UpdaterPauseGeneration,
				_UpdaterTest_TerminalOutcomeWorker.Bind(Mode))
			AssertFalse(Result,
				Mode . " terminal outcome must not acknowledge updater tray publication")
			AssertTrue(_UpdaterMenuRebuildPending,
				Mode . " terminal outcome must retain the updater menu obligation")
		}
	} finally {
		_UpdaterTest_RestoreTrayRootState(SavedTray)
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-32: refused malformed and thrown tray terminals stay pending (updater-tray-terminal-authorization)",
	_UpdaterTest_TerminalFailuresRetainPendingObligation)

_UpdaterTest_ResumeReplayOutcomeWorker(State, Mode, PublishAuthorizeFn) {
	State.CallCount += 1
	Authorized := PublishAuthorizeFn.Call()
	if !((Authorized is Integer) and Authorized == 1)
		return false
	switch Mode {
		case "false": return false
		case "malformed": return "1"
		case "throw": throw Error("deterministic resumed tray-root worker failure")
	}
	return true
}

_UpdaterTest_ResumeReplaysPendingMenuWithStrictTerminalAck() {
	global _UpdaterMenuRebuildPending
	SavedRequest := _UpdaterTest_SaveRequestState()
	SavedTray := _UpdaterTest_SaveTrayRootState()
	try {
		for _, Scenario in [
			{ Mode: "true", Expected: true },
			{ Mode: "false", Expected: false },
			{ Mode: "malformed", Expected: false },
			{ Mode: "throw", Expected: false }
		] {
			_UpdaterTest_ResetRequestState()
			_UpdaterTest_ResetTrayRootState()
			_UpdaterMenuRebuildPending := true
			State := { CallCount: 0 }
			Result := Updater_OnSuspendResume(0, false,
				_UpdaterTest_ResumeReplayOutcomeWorker.Bind(State, Scenario.Mode))

			AssertEqual(Scenario.Expected, Result,
				Scenario.Mode . " resumed terminal must return its strict acknowledgement")
			AssertEqual(1, State.CallCount,
				Scenario.Mode . " pending obligation must traverse the resume replay exactly once")
			AssertEqual(!Scenario.Expected, _UpdaterMenuRebuildPending,
				Scenario.Mode . " resumed terminal must clear pending only after strict true")
		}
	} finally {
		_UpdaterTest_RestoreTrayRootState(SavedTray)
		_UpdaterTest_RestoreRequestState(SavedRequest)
	}
}
Test("Updater AHK-32: resume replays pending root with strict terminal acknowledgement (updater-tray-resume-replay)",
	_UpdaterTest_ResumeReplaysPendingMenuWithStrictTerminalAck)
