; tests/unit/test_bounded_focus_snapshot.ahk

; ==============================================================================
; MODULE: Bounded Canonical Focus Snapshot Regression Tests
; DESCRIPTION:
; Behavioral coverage for the failure modes a source-only "off-thread" test
; missed. The acquisition seam records Critical state and the real deadline,
; returns a deterministic timeout, and nests a newer B refresh inside an older
; A refresh. The tests prove timeout is privacy fail-closed, native work cannot
; inherit Critical, and A cannot overwrite B after yielding.
;
; A companion case drives KL_Hook_RefreshContext against the same production
; cache. It proves an invalid snapshot cannot mutate the keylogger projection
; and a valid snapshot is consumed without a second OS acquisition.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ Deterministic seams ==
; ================================
; ================================

global _BFS_NowValue := 1000
global _BFS_ProbeCriticalStates := []
global _BFS_ObservedTimeoutMs := 0
global _BFS_InnerRefreshResult := false

_BFS_Now() {
	global _BFS_NowValue
	_BFS_NowValue += 1
	return _BFS_NowValue
}

_BFS_TimeoutProbe(TimeoutMs) {
	global _BFS_ObservedTimeoutMs, _BFS_ProbeCriticalStates
	_BFS_ObservedTimeoutMs := TimeoutMs
	_BFS_ProbeCriticalStates.Push(A_IsCritical)
	return {
		ok: false,
		failure_reason: "title_unavailable",
		timed_out: true
	}
}

_BFS_AcceptedProbe(ProcessName, Title, ClassName, HWND) {
	return {
		ok: true,
		hwnd: HWND,
		process_name: ProcessName,
		title: Title,
		class: ClassName,
		failure_reason: "",
		timed_out: false
	}
}

_BFS_ProbeB(TimeoutMs) {
	global _BFS_ProbeCriticalStates
	_BFS_ProbeCriticalStates.Push(A_IsCritical)
	return _BFS_AcceptedProbe("b.exe", "B title", "BClass", 202)
}

_BFS_ProbeAWithNestedB(TimeoutMs) {
	global _BFS_ProbeCriticalStates, _BFS_InnerRefreshResult
	_BFS_ProbeCriticalStates.Push(A_IsCritical)
	_BFS_InnerRefreshResult := MF_RefreshFocus(true, _BFS_ProbeB, _BFS_Now)
	return _BFS_AcceptedProbe("a.exe", "A title", "AClass", 101)
}

_BFS_State(Valid, ProcessName := "", Title := "", ClassName := "", HWND := 0,
	FailureReason := "", TimedOut := false, LastAt := 0) {
	return {
		valid: Valid,
		last_at: LastAt,
		hwnd: HWND,
		process_name: ProcessName,
		title: Title,
		class: ClassName,
		failure_reason: FailureReason,
		timed_out: TimedOut
	}
}





; =========================================================
; =========================================================
; ======= 2/ Timeout is bounded and privacy fail-closed ===
; =========================================================
; =========================================================

; This is the before/after behavioral proof that does not depend on any new
; seam. Against the old source, all ordinary filters are disabled and the
; unmarked empty context returns false. The new validity gate returns true.
_BFS_InvalidSnapshotAloneFailsClosed() {
	SavedState := MetricsFocusCache.state
	SavedDisabledApps := MetricsFilters.disabled_apps
	SavedPrivate := MetricsFilters.private_browsing
	SavedSecure := MetricsFilters.secure_field
	SavedSystemAuth := MetricsFilters.system_auth
	try {
		MetricsFocusCache.state := _BFS_State(false, "", "", "", 0,
			"title_unavailable", true, 1000)
		MetricsFilters.disabled_apps := Map()
		MetricsFilters.private_browsing := false
		MetricsFilters.secure_field := false
		MetricsFilters.system_auth := false
		AssertTrue(MF_ShouldFilter(),
			"an invalid focus acquisition must filter even when every ordinary predicate is disabled")
	} finally {
		MetricsFocusCache.state := SavedState
		MetricsFilters.disabled_apps := SavedDisabledApps
		MetricsFilters.private_browsing := SavedPrivate
		MetricsFilters.secure_field := SavedSecure
		MetricsFilters.system_auth := SavedSystemAuth
	}
}

Test("metrics focus: invalid acquisition alone fails closed (focus-invalid-fails-closed)",
	_BFS_InvalidSnapshotAloneFailsClosed)

_BFS_TimeoutFailsClosedOutsideCritical() {
	global _BFS_NowValue, _BFS_ProbeCriticalStates, _BFS_ObservedTimeoutMs
	SavedState := MetricsFocusCache.state
	SavedGeneration := MetricsFocusCache.generation
	SavedRefreshGeneration := MetricsFocusCache.refresh_generation
	try {
		MetricsFocusCache.state := _BFS_State(true, "safe.exe", "Safe",
			"SafeClass", 77, "", false, 900)
		MetricsFocusCache.generation := 40
		MetricsFocusCache.refresh_generation := 12
		_BFS_NowValue := 1000
		_BFS_ProbeCriticalStates := []
		_BFS_ObservedTimeoutMs := 0

		PreviousCritical := Critical("On")
		try Result := MF_RefreshFocus(true, _BFS_TimeoutProbe, _BFS_Now)
		finally Critical(PreviousCritical)

		AssertFalse(Result,
			"a title timeout must not publish a valid focus identity")
		AssertEqual(WI_FOCUS_TITLE_TIMEOUT_MS, _BFS_ObservedTimeoutMs,
			"the acquisition seam must receive the canonical hard OS deadline")
		Assert(_BFS_ObservedTimeoutMs > 0 && _BFS_ObservedTimeoutMs <= 5,
			"the canonical title deadline must stay inside the 5 ms profiler budget")
		AssertEqual(1, _BFS_ProbeCriticalStates.Length,
			"the timeout fixture must execute exactly one acquisition")
		AssertEqual(0, _BFS_ProbeCriticalStates[1],
			"native acquisition must run outside an inherited Critical span")
		AssertFalse(MetricsFocusCache.state.valid,
			"a partial or timed-out identity must publish an explicit invalid snapshot")
		AssertEqual("", MetricsFocusCache.state.process_name,
			"an invalid snapshot must not retain a plausible process identity")
		AssertTrue(MetricsFocusCache.state.timed_out,
			"timeout diagnostics must survive publication")
		AssertEqual(41, MetricsFocusCache.generation,
			"valid-to-invalid changes must advance the privacy epoch")
		AssertTrue(MF_ShouldFilter(),
			"an invalid canonical focus snapshot must drop telemetry fail-closed")
	} finally {
		MetricsFocusCache.state := SavedState
		MetricsFocusCache.generation := SavedGeneration
		MetricsFocusCache.refresh_generation := SavedRefreshGeneration
	}
}

Test("metrics focus: timeout is bounded and privacy fail-closed (focus-refresh-bounded-resident)",
	_BFS_TimeoutFailsClosedOutsideCritical)





; =========================================================
; =========================================================
; ======= 3/ A stale acquisition cannot overwrite B =======
; =========================================================
; =========================================================

_BFS_NewerRefreshOwnsPublication() {
	global _BFS_NowValue, _BFS_ProbeCriticalStates, _BFS_InnerRefreshResult
	SavedState := MetricsFocusCache.state
	SavedGeneration := MetricsFocusCache.generation
	SavedRefreshGeneration := MetricsFocusCache.refresh_generation
	try {
		MetricsFocusCache.state := _BFS_State(true, "base.exe", "Base",
			"BaseClass", 1, "", false, 900)
		MetricsFocusCache.generation := 70
		MetricsFocusCache.refresh_generation := 30
		_BFS_NowValue := 1000
		_BFS_ProbeCriticalStates := []
		_BFS_InnerRefreshResult := false

		OuterResult := MF_RefreshFocus(true, _BFS_ProbeAWithNestedB, _BFS_Now)

		AssertTrue(_BFS_InnerRefreshResult,
			"the nested B refresh must publish successfully")
		AssertFalse(OuterResult,
			"the older A refresh must report that it lost publication ownership")
		AssertEqual("b.exe", MetricsFocusCache.state.process_name,
			"A returning after B must not overwrite B's canonical process")
		AssertEqual("B title", MetricsFocusCache.state.title,
			"A returning after B must not overwrite B's canonical title")
		AssertEqual(71, MetricsFocusCache.generation,
			"only B's semantic publication may advance the privacy epoch")
		AssertEqual(2, _BFS_ProbeCriticalStates.Length,
			"both A and nested B acquisitions must have executed")
		for CriticalState in _BFS_ProbeCriticalStates
			AssertEqual(0, CriticalState,
				"neither interleaved acquisition may execute under Critical")
	} finally {
		MetricsFocusCache.state := SavedState
		MetricsFocusCache.generation := SavedGeneration
		MetricsFocusCache.refresh_generation := SavedRefreshGeneration
	}
}

Test("metrics focus: newer B owns publication after A yields (focus-refresh-bounded-resident)",
	_BFS_NewerRefreshOwnsPublication)





; ================================================================
; ================================================================
; ======= 4/ Stop publishes a resumed-keystroke barrier ===========
; ================================================================
; ================================================================

_BFS_StopInvalidatesThePublishedIdentity() {
	SavedState := MetricsFocusCache.state
	SavedGeneration := MetricsFocusCache.generation
	SavedRefreshGeneration := MetricsFocusCache.refresh_generation
	SavedLifecycleGeneration := MetricsFocusCache.lifecycle_generation
	SavedRunning := MetricsFocusCache.running
	SavedTimerFn := MetricsFocusCache.timer_fn
	try {
		MetricsFocusCache.state := _BFS_State(true, "before-pause.exe",
			"Before pause", "BeforePauseClass", 303, "", false, 1200)
		MetricsFocusCache.generation := 90
		MetricsFocusCache.refresh_generation := 50
		MetricsFocusCache.lifecycle_generation := 20
		MetricsFocusCache.running := false
		MetricsFocusCache.timer_fn := 0

		AssertTrue(MF_StopFocusRefresh(),
			"stopping an already-idle focus owner must remain idempotent")
		AssertFalse(MetricsFocusCache.state.valid,
			"stop must retire the pre-pause identity before native Suspend can lift")
		AssertEqual("refresh_stopped", MetricsFocusCache.state.failure_reason,
			"the invalid lifecycle barrier must remain distinguishable from a title timeout")
		AssertEqual(91, MetricsFocusCache.generation,
			"retiring a valid identity must advance the journal privacy epoch")
		AssertEqual(51, MetricsFocusCache.refresh_generation,
			"stop must deny publication to every acquisition already in flight")
		AssertTrue(MF_ShouldFilter(),
			"an early resumed keystroke must fail closed until Start seeds a new identity")
	} finally {
		MetricsFocusCache.state := SavedState
		MetricsFocusCache.generation := SavedGeneration
		MetricsFocusCache.refresh_generation := SavedRefreshGeneration
		MetricsFocusCache.lifecycle_generation := SavedLifecycleGeneration
		MetricsFocusCache.running := SavedRunning
		MetricsFocusCache.timer_fn := SavedTimerFn
	}
}

Test("metrics focus: stop retires the pre-pause identity (focus-refresh-bounded-resident)",
	_BFS_StopInvalidatesThePublishedIdentity)





; =============================================================
; =============================================================
; ======= 5/ Keylogger consumes the canonical validity gate ===
; =============================================================
; =============================================================

_BFS_KeyloggerRejectsInvalidCanonicalSnapshot() {
	SavedState := MetricsFocusCache.state
	SavedInitialized := Keylogger.initialized
	SavedSessionApp := Keylogger.session_app
	SavedSessionTitle := Keylogger.session_title
	SavedContextAt := KLHook.context_at
	SavedPrevApp := KLHook.prev_app
	SavedPrevTitle := KLHook.prev_title
	SavedAppEnteredAt := KLHook.app_entered_at
	SavedTitleEnteredAt := KLHook.title_entered_at
	SavedSuspendTick := KLHook.suspend_tick
	try {
		Keylogger.initialized := true
		Keylogger.session_app := "old.exe"
		Keylogger.session_title := "Old title"
		KLHook.context_at := 0
		KLHook.prev_app := ""
		KLHook.prev_title := ""
		KLHook.app_entered_at := 0
		KLHook.title_entered_at := 0
		KLHook.suspend_tick := 0

		MetricsFocusCache.state := _BFS_State(false, "", "", "", 0,
			"title_unavailable", true, 1000)
		AssertFalse(KL_Hook_RefreshContext(true),
			"the keylogger projection must refuse an invalid canonical snapshot")
		AssertEqual("old.exe", Keylogger.session_app,
			"invalid focus must not erase or relabel the existing keylogger session")
		AssertEqual("Old title", Keylogger.session_title,
			"invalid focus must not emit a plausible empty-title transition")

		MetricsFocusCache.state := _BFS_State(true, "new.exe", "New title",
			"NewClass", 88, "", false, 1001)
		AssertTrue(KL_Hook_RefreshContext(true),
			"the keylogger projection must accept a complete canonical snapshot")
		AssertEqual("new.exe", Keylogger.session_app)
		AssertEqual("New title", Keylogger.session_title)
	} finally {
		MetricsFocusCache.state := SavedState
		Keylogger.initialized := SavedInitialized
		Keylogger.session_app := SavedSessionApp
		Keylogger.session_title := SavedSessionTitle
		KLHook.context_at := SavedContextAt
		KLHook.prev_app := SavedPrevApp
		KLHook.prev_title := SavedPrevTitle
		KLHook.app_entered_at := SavedAppEnteredAt
		KLHook.title_entered_at := SavedTitleEnteredAt
		KLHook.suspend_tick := SavedSuspendTick
	}
}

Test("keylogger focus: invalid canonical snapshot cannot mutate context (focus-refresh-bounded-resident)",
	_BFS_KeyloggerRejectsInvalidCanonicalSnapshot)
