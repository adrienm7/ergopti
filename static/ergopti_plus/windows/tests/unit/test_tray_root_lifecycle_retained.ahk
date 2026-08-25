; tests/unit/test_tray_root_lifecycle_retained.ahk

; ==============================================================================
; MODULE: Tray-Root Retained Lifecycle Test
; DESCRIPTION:
; Reproduces a complete Pause -> Resume pulse while a detached root is staging.
; By terminal publication time A_IsSuspended may already be false, so only the
; lifecycle epoch can reject the stale tree. The rejected generation must then
; remain pending and the active-state retained service must publish it exactly
; once rather than losing the tray refresh or replaying it forever.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================================
; ==========================================================
; ======= 1/ State isolation ================================
; ==========================================================
; ==========================================================

_TRLR_SaveRootState() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	return {
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

_TRLR_ResetRootState() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	_TrayRootRequestedGeneration := 0
	_TrayRootPublishedGeneration := 0
	_TrayRootActive := false
	_TrayRootLifecycleEpoch := 0
	_TrayRootLatestAuthorizeFn := 0
	_TrayRootLatestWorkerFn := 0
	_TrayRootRetryGeneration := 0
	_TrayRootAutomaticRetryCount := 0
}

_TRLR_RestoreRootState(Saved) {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	global _TrayRootRetryGeneration, _TrayRootAutomaticRetryCount
	_TrayRootRequestedGeneration := Saved.RequestedGeneration
	_TrayRootPublishedGeneration := Saved.PublishedGeneration
	_TrayRootActive := Saved.Active
	_TrayRootLifecycleEpoch := Saved.LifecycleEpoch
	_TrayRootLatestAuthorizeFn := Saved.LatestAuthorizeFn
	_TrayRootLatestWorkerFn := Saved.LatestWorkerFn
	_TrayRootRetryGeneration := Saved.RetryGeneration
	_TrayRootAutomaticRetryCount := Saved.AutomaticRetryCount
}




; ==========================================================
; ==========================================================
; ======= 2/ Pause-pulse repro ==============================
; ==========================================================
; ==========================================================

_TRLR_InvalidateFirstDetachedBuild(State, PublishAuthorizeFn) {
	State.BuildCalls += 1
	if State.BuildCalls == 1
		_TrayRootOnSuspendEnter()
	Authorized := PublishAuthorizeFn.Call()
	if !((Authorized is Integer) and Authorized == 1)
		return false
	State.PublishCalls += 1
	return true
}

_TRLR_PausePulseRetainsAndReplaysLatestRoot() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	Saved := _TRLR_SaveRootState()
	try {
		_TRLR_ResetRootState()
		AssertFalse(A_IsSuspended,
			"the retained-root repro must begin after Resume")
		State := { BuildCalls: 0, PublishCalls: 0 }

		AssertFalse(RebuildTrayMenu(0,
			_TRLR_InvalidateFirstDetachedBuild.Bind(State), false),
			"a detached root invalidated by a complete pause pulse must refuse terminal publication")
		AssertEqual(1, State.BuildCalls,
			"the stale detached candidate must build exactly once")
		AssertEqual(0, State.PublishCalls,
			"the lifecycle-invalidated candidate must not publish")
		AssertEqual(1, _TrayRootRequestedGeneration,
			"the refused generation must remain requested")
		AssertEqual(0, _TrayRootPublishedGeneration,
			"terminal refusal must not acknowledge publication")
		AssertEqual(1, _TrayRootLifecycleEpoch,
			"the pause pulse must advance the lifecycle epoch")
		AssertFalse(_TrayRootActive,
			"the refused owner must release so the retained service can acquire")

		AssertTrue(_TrayRootServiceRetained(),
			"the resumed watchdog owner must replay the retained generic root")
		AssertEqual(2, State.BuildCalls,
			"resume must build one fresh candidate")
		AssertEqual(1, State.PublishCalls,
			"resume must publish the retained generation exactly once")
		AssertEqual(1, _TrayRootPublishedGeneration,
			"the replayed generation must be acknowledged only after terminal publication")
		AssertFalse(_TrayRootActive,
			"the successful retained owner must release")

		AssertTrue(_TrayRootServiceRetained(),
			"servicing an empty retained queue must be idempotent")
		AssertEqual(2, State.BuildCalls,
			"an acknowledged generation must never replay a second time")
		AssertEqual(1, State.PublishCalls)
	} finally {
		_TRLR_RestoreRootState(Saved)
	}
}
Test("tray root: pause pulse retains and replays latest generation exactly once (tray-root-lifecycle-retained)",
	_TRLR_PausePulseRetainsAndReplaysLatestRoot)

_TRLR_PreTrayServiceIsSafeBeforeInitializer() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	Saved := _TRLR_SaveRootState()
	try {
		for Field in ["requested", "published", "active", "epoch", "authorize", "worker"] {
			; Keep a retained generation pending so omitting any one IsSet guard
			; necessarily reaches the corresponding uninitialized field.  A
			; quiescent fixture would let the worker guard disappear unnoticed.
			_TrayRootRequestedGeneration := 1
			_TrayRootPublishedGeneration := 0
			_TrayRootActive := false
			_TrayRootLifecycleEpoch := 0
			_TrayRootLatestAuthorizeFn := 0
			_TrayRootLatestWorkerFn := _TRLR_PreTrayWorkerMustNotRun
			switch Field {
				case "requested": _TrayRootRequestedGeneration := unset
				case "published": _TrayRootPublishedGeneration := unset
				case "active": _TrayRootActive := unset
				case "epoch": _TrayRootLifecycleEpoch := unset
				case "authorize": _TrayRootLatestAuthorizeFn := unset
				case "worker": _TrayRootLatestWorkerFn := unset
			}
			AssertTrue(_TrayRootServiceRetained(),
				"the pre-tray watchdog must no-op while tray-root field '" . Field . "' is uninitialized")
		}
	} finally {
		_TRLR_RestoreRootState(Saved)
	}
}

_TRLR_PreTrayWorkerMustNotRun(PublishAuthorizeFn) {
	throw Error("the pre-tray guard must return before retained work starts")
}
Test("tray root: pre-tray watchdog tolerates uninitialized retained state "
	. "(ahk6-04-pretray-watchdog)",
	_TRLR_PreTrayServiceIsSafeBeforeInitializer)
