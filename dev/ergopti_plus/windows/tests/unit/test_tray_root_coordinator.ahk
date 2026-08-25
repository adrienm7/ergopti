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
global _TRC_TriggerCalls := 0
global _TRC_PermanentFailureMode := ""
global _TRC_TerminalReports := []

_TRC_SaveState() {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	return {
		Stage: _TrayMenuStage,
		Requested: _TrayRootRequestedGeneration,
		Published: _TrayRootPublishedGeneration,
		Active: _TrayRootActive,
		Lifecycle: _TrayRootLifecycleEpoch,
		Authorize: _TrayRootLatestAuthorizeFn,
		Worker: _TrayRootLatestWorkerFn,
		RetryGeneration: _TrayRootRetryGeneration,
		AutomaticRetryCount: _TrayRootAutomaticRetryCount,
		CriticalLevel: A_IsCritical
	}
}

_TRC_ResetState() {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	global _TRC_Builds, _TRC_ApplyCalls, _TRC_FailureMode
	global _TRC_TriggerCalls
	_TrayMenuStage := false
	_TrayRootRequestedGeneration := 0
	_TrayRootPublishedGeneration := 0
	_TrayRootActive := false
	_TrayRootLifecycleEpoch := 0
	_TrayRootLatestAuthorizeFn := 0
	_TrayRootLatestWorkerFn := 0
	_TrayRootRetryGeneration := 0
	_TrayRootAutomaticRetryCount := 0
	_TRC_Builds := []
	_TRC_ApplyCalls := 0
	_TRC_FailureMode := ""
	_TRC_TriggerCalls := 0
}

_TRC_RestoreState(Saved) {
	global _TrayMenuStage
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	_TrayMenuStage := Saved.Stage
	_TrayRootRequestedGeneration := Saved.Requested
	_TrayRootPublishedGeneration := Saved.Published
	_TrayRootActive := Saved.Active
	_TrayRootLifecycleEpoch := Saved.Lifecycle
	_TrayRootLatestAuthorizeFn := Saved.Authorize
	_TrayRootLatestWorkerFn := Saved.Worker
	_TrayRootRetryGeneration := Saved.RetryGeneration
	_TrayRootAutomaticRetryCount := Saved.AutomaticRetryCount
	Critical(Saved.CriticalLevel)
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

_TRC_PendingThenSuccessWorker(PublishAuthorizeFn) {
	global _TRC_Builds
	_TRC_Builds.Push(_TRC_Builds.Length + 1)
	if _TRC_Builds.Length < 3
		throw TrayRootRetryPendingError("injected retained root")
	return PublishAuthorizeFn.Call()
}

_TRC_PendingRootRetainsExactGeneration() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TRC_Builds
	Saved := _TRC_SaveState()
	try {
		_TRC_ResetState()
		FirstPending := false
		try RebuildTrayMenu(0, _TRC_PendingThenSuccessWorker, false)
		catch as Err
			FirstPending := Err is TrayRootRetryPendingError
		AssertTrue(FirstPending,
			"the first pending build must surface its typed retained status")
		AssertEqual(1, _TrayRootRequestedGeneration)
		AssertEqual(0, _TrayRootPublishedGeneration)
		AssertFalse(_TrayRootActive)

		SecondPending := false
		try _TrayRootServiceRetained()
		catch as Err
			SecondPending := Err is TrayRootRetryPendingError
		AssertTrue(SecondPending,
			"the retained owner must preserve the same typed retry status")
		AssertEqual(1, _TrayRootRequestedGeneration)
		AssertEqual(0, _TrayRootPublishedGeneration)
		AssertFalse(_TrayRootActive)

		AssertTrue(_TrayRootServiceRetained(),
			"the retained generation must publish when its worker recovers")
		AssertEqual(3, _TRC_Builds.Length)
		AssertEqual(1, _TrayRootRequestedGeneration)
		AssertEqual(1, _TrayRootPublishedGeneration)
		AssertFalse(_TrayRootActive)
	} finally {
		_TRC_RestoreState(Saved)
	}
}
Test("tray root: pending status retains one exact generation (tray-root-retry-status)",
	_TRC_PendingRootRetainsExactGeneration)

_TRC_FatalWorker(PublishAuthorizeFn) {
	global _TRC_Builds
	_TRC_Builds.Push(_TRC_Builds.Length + 1)
	if _TRC_Builds.Length == 1 {
		AssertFalse(RebuildTrayMenu(0, _TRC_FatalWorker, false),
			"a successor accepted during the fatal build must remain queued")
		throw TrayRootFatalContextError("injected poisoned context")
	}
	return PublishAuthorizeFn.Call()
}

_TRC_FatalRootRetiresExactGeneration() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TRC_Builds
	Saved := _TRC_SaveState()
	try {
		_TRC_ResetState()
		FatalSurfaced := false
		try RebuildTrayMenu(0, _TRC_FatalWorker, false)
		catch as Err
			FatalSurfaced := Err is TrayRootFatalContextError
		AssertTrue(FatalSurfaced,
			"a poisoned HotIf context must terminate its logical thread")
		AssertEqual(2, _TrayRootRequestedGeneration)
		AssertEqual(1, _TrayRootPublishedGeneration)
		AssertFalse(_TrayRootActive)
		AssertTrue(_TrayRootServiceRetained(),
			"only the successor generation may remain queued after fatal retirement")
		AssertEqual(2, _TRC_Builds.Length)
		AssertEqual(2, _TrayRootPublishedGeneration)
		AssertFalse(_TrayRootActive)
	} finally {
		_TRC_RestoreState(Saved)
	}
}
Test("tray root: fatal context retires the exact generation (tray-root-fatal-status)",
	_TRC_FatalRootRetiresExactGeneration)

_TRC_OrdinaryFailureThenSuccessWorker(PublishAuthorizeFn) {
	global _TRC_Builds
	_TRC_Builds.Push(_TRC_Builds.Length + 1)
	if _TRC_Builds.Length == 1
		throw Error("injected ordinary root failure")
	return PublishAuthorizeFn.Call()
}

_TRC_OrdinaryFailureRemainsRetryable() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TRC_Builds
	Saved := _TRC_SaveState()
	try {
		_TRC_ResetState()
		AssertFalse(RebuildTrayMenu(0,
			_TRC_OrdinaryFailureThenSuccessWorker, false),
			"an ordinary failure must preserve the existing false result")
		AssertEqual(1, _TrayRootRequestedGeneration)
		AssertEqual(0, _TrayRootPublishedGeneration)
		AssertFalse(_TrayRootActive)
		AssertTrue(_TrayRootServiceRetained(),
			"an ordinary retained generation must remain serviceable")
		AssertEqual(2, _TRC_Builds.Length)
		AssertEqual(1, _TrayRootPublishedGeneration)
	} finally {
		_TRC_RestoreState(Saved)
	}
}
Test("tray root: ordinary failure remains retryable (tray-root-error-control)",
	_TRC_OrdinaryFailureRemainsRetryable)

_TRC_PermanentFailureWorker(PublishAuthorizeFn) {
	global _TRC_Builds, _TRC_PermanentFailureMode
	_TRC_Builds.Push(_TRC_Builds.Length + 1)
	if _TRC_PermanentFailureMode == "malformed"
		return "1"
	throw Error("injected permanent root failure")
}

_TRC_CaptureTerminalReport(TargetGeneration, RetryCount, Message) {
	global _TRC_TerminalReports
	_TRC_TerminalReports.Push({
		TargetGeneration: TargetGeneration,
		RetryCount: RetryCount,
		Message: Message
	})
}

_TRC_RecoveryWorker(PublishAuthorizeFn) {
	global _TRC_Builds
	_TRC_Builds.Push(_TRC_Builds.Length + 1)
	return PublishAuthorizeFn.Call()
}

_TRC_PermanentAutomaticFailureRetiresExactGeneration() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TRC_Builds
	global _TRC_PermanentFailureMode, _TRC_TerminalReports
	Saved := _TRC_SaveState()
	try {
		for _, Mode in ["throw", "malformed"] {
			_TRC_ResetState()
			_TRC_PermanentFailureMode := Mode
			_TRC_TerminalReports := []
			AssertFalse(RebuildTrayMenu(0, _TRC_PermanentFailureWorker, false),
				"the caller-visible " . Mode . " failure must retain its exact generation")
			AssertEqual(1, _TRC_Builds.Length)

			; Three automatic watchdog attempts are the complete retry budget. The
			; direct caller attempt above is deliberately not counted against it.
			loop 3
				AssertFalse(_TrayRootServiceRetained(_TRC_CaptureTerminalReport))
			AssertEqual(4, _TRC_Builds.Length,
				"one direct attempt plus three watchdog retries must be the hard bound")
			AssertEqual(1, _TrayRootRequestedGeneration)
			AssertEqual(1, _TrayRootPublishedGeneration,
				"the exhausted generation must retire without replacing the safe root")
			AssertFalse(_TrayRootActive)
			AssertEqual(1, _TRC_TerminalReports.Length,
				"only exhaustion may emit the terminal watchdog diagnostic")
			AssertEqual(1, _TRC_TerminalReports[1].TargetGeneration)
			AssertEqual(3, _TRC_TerminalReports[1].RetryCount)

			AssertTrue(_TrayRootServiceRetained(_TRC_CaptureTerminalReport),
				"an exhausted generation must become an idle watchdog no-op")
			AssertEqual(4, _TRC_Builds.Length,
				"the same failed generation must never be rebuilt after exhaustion")
			AssertEqual(1, _TRC_TerminalReports.Length)

			AssertFalse(RebuildTrayMenu(0, _TRC_PermanentFailureWorker, false),
				"a genuinely new generation must receive a fresh retry budget")
			loop 2
				AssertFalse(_TrayRootServiceRetained(_TRC_CaptureTerminalReport))
			AssertEqual(1, _TrayRootPublishedGeneration,
				"a previous generation's exhausted budget must not leak into its successor")
			AssertEqual(1, _TRC_TerminalReports.Length)
			AssertFalse(_TrayRootServiceRetained(_TRC_CaptureTerminalReport))
			AssertEqual(2, _TrayRootPublishedGeneration)
			AssertEqual(2, _TRC_TerminalReports.Length)
			AssertEqual(2, _TRC_TerminalReports[2].TargetGeneration)
			AssertEqual(3, _TRC_TerminalReports[2].RetryCount)

			AssertTrue(RebuildTrayMenu(0, _TRC_RecoveryWorker, false),
				"work after an exhausted successor must still publish normally")
			AssertEqual(9, _TRC_Builds.Length)
			AssertEqual(3, _TrayRootRequestedGeneration)
			AssertEqual(3, _TrayRootPublishedGeneration)
			AssertFalse(_TrayRootActive)
		}
	} finally {
		_TRC_RestoreState(Saved)
	}
}
Test("tray root: permanent automatic failure retires after a bounded budget "
	. "(ahk6-03-tray-root-retry-budget)",
	_TRC_PermanentAutomaticFailureRetiresExactGeneration)

_TRC_TypedErrorsHaveNarrowSilentClassification() {
	AssertTrue(_TrayRootErrorIsSilent(
		TrayRootRetryPendingError("pending")))
	AssertTrue(_TrayRootErrorIsSilent(
		TrayRootFatalContextError("fatal")))
	AssertFalse(_TrayRootErrorIsSilent(Error("ordinary")),
		"ordinary reconstruction errors must remain reportable")
}
Test("tray root: only typed control errors are silent (tray-root-error-classification)",
	_TRC_TypedErrorsHaveNarrowSilentClassification)

_TRC_FatalRetainedService() {
	throw TrayRootFatalContextError("injected poisoned watchdog context")
}

_TRC_PendingRetainedService() {
	throw TrayRootRetryPendingError("injected safe retained retry")
}

_TRC_TriggerRecoverySpy() {
	global _TRC_TriggerCalls
	_TRC_TriggerCalls += 1
	return true
}

_TRC_WatchdogStopsAfterFatalContext() {
	global _TRC_TriggerCalls
	_TRC_TriggerCalls := 0
	AssertFalse(_TrayRootServiceRetainedWork(
		_TRC_FatalRetainedService, _TRC_TriggerRecoverySpy),
		"a fatal root context must terminate the current watchdog pass")
	AssertEqual(0, _TRC_TriggerCalls,
		"no later native hotkey recovery may run under a poisoned HotIf context")
	AssertTrue(_TrayRootServiceRetainedWork(
		_TRC_PendingRetainedService, _TRC_TriggerRecoverySpy),
		"a proven-reset pending root may continue to sibling recovery")
	AssertEqual(1, _TRC_TriggerCalls)
}
Test("tray root: watchdog stops after fatal dynamic context (tray-root-fatal-watchdog)",
	_TRC_WatchdogStopsAfterFatalContext)
