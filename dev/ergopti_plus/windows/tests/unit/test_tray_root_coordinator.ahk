; tests/unit/test_tray_root_coordinator.ahk

; ==============================================================================
; MODULE: Tray-Root Coordinator Tests
; DESCRIPTION:
; Proves that all detached tray-root builders share one generation owner and
; that terminal authorization precedes the irreversible native replacement.
; ==============================================================================

#Requires AutoHotkey v2.0



global _TRC_Builds := []
global _TRC_ApplyCalls := 0
global _TRC_FailureMode := ""
global _TRC_ExpectedError := 0

_TRC_SaveState() {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	return {
		Stage: _TrayMenuStage,
		Requested: _TrayRootRequestedGeneration,
		Published: _TrayRootPublishedGeneration,
		Active: _TrayRootActive,
		Lifecycle: _TrayRootLifecycleEpoch,
		Authorize: _TrayRootLatestAuthorizeFn,
		Worker: _TrayRootLatestWorkerFn
	}
}

_TRC_ResetState() {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TRC_Builds, _TRC_ApplyCalls, _TRC_FailureMode
	_TrayMenuStage := false
	_TrayRootRequestedGeneration := 0
	_TrayRootPublishedGeneration := 0
	_TrayRootActive := false
	_TrayRootLifecycleEpoch := 0
	_TrayRootLatestAuthorizeFn := 0
	_TrayRootLatestWorkerFn := 0
	_TRC_Builds := []
	_TRC_ApplyCalls := 0
	_TRC_FailureMode := ""
}

_TRC_RestoreState(Saved) {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	_TrayMenuStage := Saved.Stage
	_TrayRootRequestedGeneration := Saved.Requested
	_TrayRootPublishedGeneration := Saved.Published
	_TrayRootActive := Saved.Active
	_TrayRootLifecycleEpoch := Saved.Lifecycle
	_TrayRootLatestAuthorizeFn := Saved.Authorize
	_TrayRootLatestWorkerFn := Saved.Worker
}

_TRC_RefusePublication() {
	return false
}

_TRC_RecordApply(Stage) {
	global _TRC_ApplyCalls
	_TRC_ApplyCalls += 1
	return true
}

_TRC_AuthorizationPrecedesMutation() {
	global _TrayMenuStage, _TRC_ApplyCalls
	Saved := _TRC_SaveState()
	try {
		_TRC_ResetState()
		TrayMenuStage_Begin()
		TrayMenuStage_Add("candidate", 0)
		AssertFalse(TrayMenuStage_Publish(
			_TRC_RefusePublication, _TRC_RecordApply),
			"a refused generation must not mutate the native root")
		AssertEqual(0, _TRC_ApplyCalls,
			"terminal authorization must run before the mutation adapter")
		AssertFalse(IsObject(_TrayMenuStage),
			"a refused stage must release the singleton stage owner")
	} finally {
		_TRC_RestoreState(Saved)
	}
}
Test("tray root: terminal authorization precedes mutation (tray-publish-terminal-ticket)",
	_TRC_AuthorizationPrecedesMutation)

_TRC_ConcurrentWorker(PublishAuthorizeFn) {
	global _TRC_Builds
	BuildNumber := _TRC_Builds.Length + 1
	_TRC_Builds.Push(BuildNumber)
	if BuildNumber == 1
		AssertFalse(RebuildTrayMenu(0, _TRC_ConcurrentWorker, false),
			"a nested root request must queue behind the current owner")
	return PublishAuthorizeFn.Call()
}

_TRC_ConcurrentRequestPublishesLatest() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TRC_Builds
	Saved := _TRC_SaveState()
	try {
		_TRC_ResetState()
		AssertTrue(RebuildTrayMenu(0, _TRC_ConcurrentWorker, false))
		AssertEqual(2, _TRC_Builds.Length,
			"the owner must discard stale build A and build latest B")
		AssertEqual(2, _TrayRootRequestedGeneration)
		AssertEqual(2, _TrayRootPublishedGeneration)
		AssertFalse(_TrayRootActive)
	} finally {
		_TRC_RestoreState(Saved)
	}
}
Test("tray root: concurrent requests coalesce to latest (tray-root-owner-generation)",
	_TRC_ConcurrentRequestPublishesLatest)

_TRC_FailingWorker(PublishAuthorizeFn) {
	global _TRC_Builds, _TRC_FailureMode, _TRC_ExpectedError
	BuildNumber := _TRC_Builds.Length + 1
	_TRC_Builds.Push(BuildNumber)
	if BuildNumber == 1 {
		AssertFalse(RebuildTrayMenu(0, _TRC_FailingWorker, false),
			"the accepted successor must remain behind its current owner")
		if _TRC_FailureMode == "throw"
			throw _TRC_ExpectedError
		return "1"
	}
	return PublishAuthorizeFn.Call()
}

_TRC_FailedOwnerHandsOffSuccessor() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TRC_Builds, _TRC_FailureMode
	global _TRC_ExpectedError
	Saved := _TRC_SaveState()
	try {
		for _, Mode in ["malformed", "throw"] {
			_TRC_ResetState()
			_TRC_FailureMode := Mode
			_TRC_ExpectedError := Error("injected root failure")
			AssertTrue(RebuildTrayMenu(0, _TRC_FailingWorker, false),
				"a failed owner must hand off its accepted successor")
			AssertEqual(2, _TRC_Builds.Length)
			AssertEqual(2, _TrayRootRequestedGeneration)
			AssertEqual(2, _TrayRootPublishedGeneration)
			AssertFalse(_TrayRootActive)
		}
	} finally {
		_TRC_RestoreState(Saved)
	}
}
Test("tray root: failed owner hands off accepted successor (tray-root-failure-handoff)",
	_TRC_FailedOwnerHandsOffSuccessor)
