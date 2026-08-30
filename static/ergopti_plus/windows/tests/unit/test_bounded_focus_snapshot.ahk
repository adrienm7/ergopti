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

global _BFS_FOCUS_CANCEL_ATTEMPTS := 0

_BFS_FailingFocusTimerCancel(FocusTimerFn) {
	global _BFS_FOCUS_CANCEL_ATTEMPTS
	_BFS_FOCUS_CANCEL_ATTEMPTS += 1
	if _BFS_FOCUS_CANCEL_ATTEMPTS = 1
		throw Error("injected focus timer cancellation failure")
}

_BFS_StopFailureRetainsTimerOwnership() {
	global _BFS_FOCUS_CANCEL_ATTEMPTS
	SavedState := MetricsFocusCache.state
	SavedGeneration := MetricsFocusCache.generation
	SavedRefreshGeneration := MetricsFocusCache.refresh_generation
	SavedLifecycleGeneration := MetricsFocusCache.lifecycle_generation
	SavedRunning := MetricsFocusCache.running
	SavedTimerFn := MetricsFocusCache.timer_fn
	FocusTimerFn := (*) => 0
	try {
		_BFS_FOCUS_CANCEL_ATTEMPTS := 0
		MetricsFocusCache.running := true
		MetricsFocusCache.timer_fn := FocusTimerFn

		AssertFalse(MF_StopFocusRefresh(_BFS_FailingFocusTimerCancel),
			"a failed native cancellation must reject the stop transition")
		AssertFalse(MetricsFocusCache.running,
			"privacy acquisition must remain disabled after the stop request")
		AssertTrue(IsObject(MetricsFocusCache.timer_fn)
			&& ObjPtr(MetricsFocusCache.timer_fn) = ObjPtr(FocusTimerFn),
			"the exact timer identity must remain owned for cleanup retry")
		AssertFalse(MF_StartFocusRefresh(),
			"start must not overwrite an unresolved native timer owner")

		AssertTrue(MF_StopFocusRefresh(_BFS_FailingFocusTimerCancel),
			"a later stop retry must release the retained timer owner")
		AssertEqual(0, MetricsFocusCache.timer_fn,
			"successful cleanup must retire the exact timer identity")
	} finally {
		MetricsFocusCache.state := SavedState
		MetricsFocusCache.generation := SavedGeneration
		MetricsFocusCache.refresh_generation := SavedRefreshGeneration
		MetricsFocusCache.lifecycle_generation := SavedLifecycleGeneration
		MetricsFocusCache.running := SavedRunning
		MetricsFocusCache.timer_fn := SavedTimerFn
	}
}
Test("metrics focus: failed timer stop retains retry ownership (focus-refresh-stop-ownership)",
	_BFS_StopFailureRetainsTimerOwnership)





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





; =============================================================
; =============================================================
; ======= 6/ Stable focus polls reuse process identity =========
; =============================================================
; =============================================================

global _BFS_ProcessAcquireCount := 0
global _BFS_ProcessCloseCount := 0
global _BFS_ProcessAlive := Map()

_BFS_FakeAcquireProcess(ProcessId) {
	global _BFS_ProcessAcquireCount, _BFS_ProcessAlive
	_BFS_ProcessAcquireCount += 1
	Handle := 10000 + _BFS_ProcessAcquireCount
	_BFS_ProcessAlive[Handle] := true
	return {
		name: "process-" . ProcessId . ".exe",
		process_id: ProcessId,
		process_handle: Handle
	}
}

_BFS_FakeProcessAlive(ProcessHandle) {
	global _BFS_ProcessAlive
	return _BFS_ProcessAlive.Get(ProcessHandle, false)
}

_BFS_FakeCloseProcess(ProcessHandle) {
	global _BFS_ProcessCloseCount, _BFS_ProcessAlive
	_BFS_ProcessCloseCount += 1
	_BFS_ProcessAlive[ProcessHandle] := false
	return true
}

_BFS_ProcessIdentityCacheTracksLivePid() {
	global _BFS_ProcessAcquireCount, _BFS_ProcessCloseCount, _BFS_ProcessAlive
	SavedPid := WIFocusProcessCache.process_id
	SavedHandle := WIFocusProcessCache.process_handle
	SavedName := WIFocusProcessCache.process_name
	SavedGeneration := WIFocusProcessCache.generation
	SavedAcquire := WIFocusProcessCache.acquire_fn
	SavedAlive := WIFocusProcessCache.alive_fn
	SavedClose := WIFocusProcessCache.close_fn
	try {
		WIFocusProcessCache.process_id := 0
		WIFocusProcessCache.process_handle := 0
		WIFocusProcessCache.process_name := ""
		WIFocusProcessCache.acquire_fn := _BFS_FakeAcquireProcess
		WIFocusProcessCache.alive_fn := _BFS_FakeProcessAlive
		WIFocusProcessCache.close_fn := _BFS_FakeCloseProcess
		_BFS_ProcessAcquireCount := 0
		_BFS_ProcessCloseCount := 0
		_BFS_ProcessAlive := Map()

		First := _WIReadProcessIdentityCached(4100)
		FirstHandle := WIFocusProcessCache.process_handle
		Loop 200
			Again := _WIReadProcessIdentityCached(4100)
		AssertEqual(1, _BFS_ProcessAcquireCount,
			"stable polls and same-process window churn must resolve the executable once")
		AssertEqual(First.name, Again.name)
		AssertEqual(0, _BFS_ProcessCloseCount,
			"the live retained handle must remain the cache's PID-reuse fence")

		_BFS_ProcessAlive[FirstHandle] := false
		Recycled := _WIReadProcessIdentityCached(4100)
		AssertEqual(2, _BFS_ProcessAcquireCount,
			"a terminated retained handle must force resolution even when the PID number matches")
		AssertEqual(1, _BFS_ProcessCloseCount,
			"replacing a terminated identity must close its exact old handle")
		AssertEqual(4100, Recycled.process_id)

		Switched := _WIReadProcessIdentityCached(4200)
		AssertEqual(3, _BFS_ProcessAcquireCount,
			"a real PID change must resolve the new process exactly once")
		AssertEqual(2, _BFS_ProcessCloseCount,
			"the PID transition must close the previous retained owner")
		AssertEqual("process-4200.exe", Switched.name)
	} finally {
		_WIResetFocusProcessCache()
		WIFocusProcessCache.process_id := SavedPid
		WIFocusProcessCache.process_handle := SavedHandle
		WIFocusProcessCache.process_name := SavedName
		WIFocusProcessCache.generation := SavedGeneration
		WIFocusProcessCache.acquire_fn := SavedAcquire
		WIFocusProcessCache.alive_fn := SavedAlive
		WIFocusProcessCache.close_fn := SavedClose
	}
}

Test("metrics focus: stable PID polling performs one process query (focus-refresh-resident-stall)",
	_BFS_ProcessIdentityCacheTracksLivePid)

_BFS_PerformanceCounter() {
	Counter := 0
	DllCall("Kernel32\QueryPerformanceCounter", "Int64*", &Counter)
	return Counter
}

_BFS_ResidentFocusPrimitivesMeetBudget() {
	SavedPid := WIFocusProcessCache.process_id
	SavedHandle := WIFocusProcessCache.process_handle
	SavedName := WIFocusProcessCache.process_name
	SavedGeneration := WIFocusProcessCache.generation
	SavedAcquire := WIFocusProcessCache.acquire_fn
	SavedAlive := WIFocusProcessCache.alive_fn
	SavedClose := WIFocusProcessCache.close_fn
	try {
		WIFocusProcessCache.process_id := 0
		WIFocusProcessCache.process_handle := 0
		WIFocusProcessCache.process_name := ""
		WIFocusProcessCache.acquire_fn := 0
		WIFocusProcessCache.alive_fn := 0
		WIFocusProcessCache.close_fn := 0
		CurrentPid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
		AssertTrue(IsObject(_WIReadProcessIdentityCached(CurrentPid)),
			"the real-process warmup identity must resolve")
		AssertTrue(_WIFocusProcessHandleAlive(
			WIFocusProcessCache.process_handle),
			"the retained real process handle must include SYNCHRONIZE access")

		Frequency := 0
		DllCall("Kernel32\QueryPerformanceFrequency", "Int64*", &Frequency)
		Started := _BFS_PerformanceCounter()
		Loop 250 {
			Identity := _WIReadProcessIdentityCached(CurrentPid)
			Title := _WIReadForegroundTitleLocal(A_ScriptHwnd)
			ClassName := _WIReadClassNameLocal(A_ScriptHwnd)
			AssertTrue(IsObject(Identity) && Title.ok && ClassName is String,
				"every real resident probe primitive must remain complete")
		}
		ElapsedMs := (_BFS_PerformanceCounter() - Started) * 1000 / Frequency
		Assert(ElapsedMs < 750,
			"250 real cached focus probes must stay below 750 ms total; actual="
			. Round(ElapsedMs, 2) . " ms")

		; Exercise the complete foreground path as well. The foreground may change
		; while the suite runs, so validity is deliberately not asserted; races must
		; fail closed, but neither accepted nor rejected probes may stall the driver.
		WICaptureBoundedFocusSnapshot()
		Started := _BFS_PerformanceCounter()
		Loop 100
			WICaptureBoundedFocusSnapshot()
		ForegroundElapsedMs := (_BFS_PerformanceCounter() - Started)
			* 1000 / Frequency
		Assert(ForegroundElapsedMs < 750,
			"100 complete real foreground probes must stay below 750 ms total; actual="
			. Round(ForegroundElapsedMs, 2) . " ms")
	} finally {
		_WIResetFocusProcessCache()
		WIFocusProcessCache.process_id := SavedPid
		WIFocusProcessCache.process_handle := SavedHandle
		WIFocusProcessCache.process_name := SavedName
		WIFocusProcessCache.generation := SavedGeneration
		WIFocusProcessCache.acquire_fn := SavedAcquire
		WIFocusProcessCache.alive_fn := SavedAlive
		WIFocusProcessCache.close_fn := SavedClose
	}
}

Test("metrics focus: real resident primitives meet the input-thread latency budget (focus-refresh-resident-stall)",
	_BFS_ResidentFocusPrimitivesMeetBudget)

global _BFS_ProcessCleanupDebtState := 0

_BFS_ProcessCleanupDebtClose(ProcessHandle) {
	global _BFS_ProcessCleanupDebtState
	_BFS_ProcessCleanupDebtState["close_attempts"] += 1
	return _BFS_ProcessCleanupDebtState["accept_close"]
}

_BFS_ProcessCleanupDebtAcquire(ProcessId) {
	global _BFS_ProcessCleanupDebtState
	_BFS_ProcessCleanupDebtState["acquisitions"] += 1
	return {
		name: "cleanup-debt.exe",
		process_id: ProcessId,
		process_handle: 8001
	}
}

_BFS_ProcessHandleCleanupDebtBlocksReplacement() {
	global _BFS_ProcessCleanupDebtState
	SavedPid := WIFocusProcessCache.process_id
	SavedHandle := WIFocusProcessCache.process_handle
	SavedName := WIFocusProcessCache.process_name
	SavedGeneration := WIFocusProcessCache.generation
	SavedDebt := WIFocusProcessCache.cleanup_debt
	SavedDraining := WIFocusProcessCache.cleanup_draining
	SavedAcquire := WIFocusProcessCache.acquire_fn
	SavedAlive := WIFocusProcessCache.alive_fn
	SavedClose := WIFocusProcessCache.close_fn
	try {
		_BFS_ProcessCleanupDebtState := Map(
			"close_attempts", 0, "accept_close", false, "acquisitions", 0)
		WIFocusProcessCache.process_id := 7001
		WIFocusProcessCache.process_handle := 7002
		WIFocusProcessCache.process_name := "old-focus.exe"
		WIFocusProcessCache.cleanup_debt := []
		WIFocusProcessCache.cleanup_draining := false
		WIFocusProcessCache.acquire_fn := _BFS_ProcessCleanupDebtAcquire
		WIFocusProcessCache.alive_fn := (*) => true
		WIFocusProcessCache.close_fn := _BFS_ProcessCleanupDebtClose

		AssertFalse(_WIResetFocusProcessCache(),
			"a refused CloseHandle must report retained cleanup ownership")
		AssertEqual(1, WIFocusProcessCache.cleanup_debt.Length,
			"the exact native handle must remain reachable after refusal")
		AssertEqual(7002, WIFocusProcessCache.cleanup_debt[1])
		AssertFalse(_WIReadProcessIdentityCached(7003),
			"new identity admission must fail closed while cleanup debt remains")
		AssertEqual(0, _BFS_ProcessCleanupDebtState["acquisitions"],
			"no replacement handle may be opened before old debt is discharged")

		_BFS_ProcessCleanupDebtState["accept_close"] := true
		Identity := _WIReadProcessIdentityCached(7003)
		AssertTrue(IsObject(Identity),
			"a later accepted close must make identity acquisition retryable")
		AssertEqual(1, _BFS_ProcessCleanupDebtState["acquisitions"])
		AssertEqual(0, WIFocusProcessCache.cleanup_debt.Length)
		AssertTrue(_WIResetFocusProcessCache())
		AssertEqual(4, _BFS_ProcessCleanupDebtState["close_attempts"])
	} finally {
		WIFocusProcessCache.process_id := SavedPid
		WIFocusProcessCache.process_handle := SavedHandle
		WIFocusProcessCache.process_name := SavedName
		WIFocusProcessCache.generation := SavedGeneration
		WIFocusProcessCache.cleanup_debt := SavedDebt
		WIFocusProcessCache.cleanup_draining := SavedDraining
		WIFocusProcessCache.acquire_fn := SavedAcquire
		WIFocusProcessCache.alive_fn := SavedAlive
		WIFocusProcessCache.close_fn := SavedClose
	}
}

Test("metrics focus: refused process-handle cleanup blocks replacement "
	. "(focus-process-cleanup-debt)",
	_BFS_ProcessHandleCleanupDebtBlocksReplacement)

global _BFS_ProcessCleanupRaceState := 0

_BFS_ProcessCleanupRaceClose(ProcessHandle) {
	global _BFS_ProcessCleanupRaceState
	_BFS_ProcessCleanupRaceState["close_attempts"] += 1
	if !_BFS_ProcessCleanupRaceState["reentered"] {
		_BFS_ProcessCleanupRaceState["reentered"] := true
		_BFS_ProcessCleanupRaceState["result"] :=
			_WIReadProcessIdentityCached(8103)
	}
	return true
}

_BFS_ProcessCleanupRaceAcquire(ProcessId) {
	global _BFS_ProcessCleanupRaceState
	_BFS_ProcessCleanupRaceState["acquisitions"] += 1
	return {
		name: "cleanup-race.exe",
		process_id: ProcessId,
		process_handle: 8104
	}
}

_BFS_ProcessHandleCleanupStaysPublishedDuringNativeClose() {
	global _BFS_ProcessCleanupRaceState
	SavedPid := WIFocusProcessCache.process_id
	SavedHandle := WIFocusProcessCache.process_handle
	SavedName := WIFocusProcessCache.process_name
	SavedGeneration := WIFocusProcessCache.generation
	SavedDebt := WIFocusProcessCache.cleanup_debt
	SavedDraining := WIFocusProcessCache.cleanup_draining
	SavedAcquire := WIFocusProcessCache.acquire_fn
	SavedAlive := WIFocusProcessCache.alive_fn
	SavedClose := WIFocusProcessCache.close_fn
	try {
		_BFS_ProcessCleanupRaceState := Map(
			"close_attempts", 0, "reentered", false,
			"result", 0, "acquisitions", 0)
		WIFocusProcessCache.process_id := 8101
		WIFocusProcessCache.process_handle := 8102
		WIFocusProcessCache.process_name := "old-race.exe"
		WIFocusProcessCache.cleanup_debt := []
		WIFocusProcessCache.cleanup_draining := false
		WIFocusProcessCache.acquire_fn := _BFS_ProcessCleanupRaceAcquire
		WIFocusProcessCache.alive_fn := (*) => true
		WIFocusProcessCache.close_fn := _BFS_ProcessCleanupRaceClose

		AssertTrue(_WIResetFocusProcessCache())
		AssertFalse(IsObject(_BFS_ProcessCleanupRaceState["result"]),
			"reentrant acquisition must fail while the old handle is still closing")
		AssertEqual(0, _BFS_ProcessCleanupRaceState["acquisitions"],
			"cleanup must remain visibly owned throughout the native close call")
		AssertEqual(1, _BFS_ProcessCleanupRaceState["close_attempts"])
		AssertEqual(0, WIFocusProcessCache.cleanup_debt.Length)
	} finally {
		WIFocusProcessCache.process_id := SavedPid
		WIFocusProcessCache.process_handle := SavedHandle
		WIFocusProcessCache.process_name := SavedName
		WIFocusProcessCache.generation := SavedGeneration
		WIFocusProcessCache.cleanup_debt := SavedDebt
		WIFocusProcessCache.cleanup_draining := SavedDraining
		WIFocusProcessCache.acquire_fn := SavedAcquire
		WIFocusProcessCache.alive_fn := SavedAlive
		WIFocusProcessCache.close_fn := SavedClose
	}
}

Test("metrics focus: process cleanup stays published during native close "
	. "(focus-process-cleanup-race)",
	_BFS_ProcessHandleCleanupStaysPublishedDuringNativeClose)

global _BFS_ProcessCacheResetRaceState := 0

_BFS_ProcessCacheResetRaceAlive(ProcessHandle) {
	global _BFS_ProcessCacheResetRaceState
	_BFS_ProcessCacheResetRaceState["alive_calls"] += 1
	_WIResetFocusProcessCache()
	return true
}

_BFS_ProcessCacheResetRaceClose(ProcessHandle) {
	global _BFS_ProcessCacheResetRaceState
	_BFS_ProcessCacheResetRaceState["close_attempts"] += 1
	return false
}

_BFS_ProcessCacheHitRevalidatesAfterAliveProbe() {
	global _BFS_ProcessCacheResetRaceState
	SavedPid := WIFocusProcessCache.process_id
	SavedHandle := WIFocusProcessCache.process_handle
	SavedName := WIFocusProcessCache.process_name
	SavedGeneration := WIFocusProcessCache.generation
	SavedDebt := WIFocusProcessCache.cleanup_debt
	SavedDraining := WIFocusProcessCache.cleanup_draining
	SavedAcquire := WIFocusProcessCache.acquire_fn
	SavedAlive := WIFocusProcessCache.alive_fn
	SavedClose := WIFocusProcessCache.close_fn
	try {
		_BFS_ProcessCacheResetRaceState := Map(
			"alive_calls", 0, "close_attempts", 0)
		WIFocusProcessCache.process_id := 8201
		WIFocusProcessCache.process_handle := 8202
		WIFocusProcessCache.process_name := "cached-race.exe"
		WIFocusProcessCache.cleanup_debt := []
		WIFocusProcessCache.cleanup_draining := false
		WIFocusProcessCache.acquire_fn := 0
		WIFocusProcessCache.alive_fn := _BFS_ProcessCacheResetRaceAlive
		WIFocusProcessCache.close_fn := _BFS_ProcessCacheResetRaceClose

		Result := _WIReadProcessIdentityCached(8201)
		AssertFalse(IsObject(Result),
			"a cache hit retired during its alive probe must fail closed")
		AssertEqual(1, _BFS_ProcessCacheResetRaceState["alive_calls"])
		AssertEqual(1, _BFS_ProcessCacheResetRaceState["close_attempts"])
		AssertEqual(1, WIFocusProcessCache.cleanup_debt.Length,
			"the reset must retain its refused handle while the old read unwinds")
	} finally {
		WIFocusProcessCache.process_id := SavedPid
		WIFocusProcessCache.process_handle := SavedHandle
		WIFocusProcessCache.process_name := SavedName
		WIFocusProcessCache.generation := SavedGeneration
		WIFocusProcessCache.cleanup_debt := SavedDebt
		WIFocusProcessCache.cleanup_draining := SavedDraining
		WIFocusProcessCache.acquire_fn := SavedAcquire
		WIFocusProcessCache.alive_fn := SavedAlive
		WIFocusProcessCache.close_fn := SavedClose
	}
}

Test("metrics focus: cached identity revalidates after alive probe "
	. "(focus-process-cache-reset-race)",
	_BFS_ProcessCacheHitRevalidatesAfterAliveProbe)
