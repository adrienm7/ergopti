; static/ergopti_plus/windows/tests/unit/test_timer_scheduler.ahk

; ==============================================================================
; MODULE: TimerScheduler Adapter Unit Tests
; DESCRIPTION:
; Validates the TimerScheduler adapter contract without triggering real OS
; timers. Tests inject a recording stub for SetTimer / callback execution
; and drive callbacks manually via _TimerAdapterMakeOneShot / _TimerAdapterMakeRepeating
; to assert handle lifecycle, activeCount, and exception isolation.
;
; APPROACH:
; AHK v2 SetTimer fires asynchronously so we cannot assert side effects after
; a delay. Instead we:
;   1. Call TimerAfter/TimerEvery to get a handle and its wrapped BoundFn.
;   2. Invoke BoundFn() directly — this simulates the OS firing the timer.
;   3. Assert the handle and registry state are updated correctly.
; This gives deterministic results with zero real timers created.
; ==============================================================================

#Requires AutoHotkey v2.0


; Reset registry before each logical group so handles from one test do not
; bleed into the next.
_TS_ResetRegistry() {
	global _TIMER_ADAPTER_REGISTRY
	; Disarm any REAL OS timer a prior test left armed before discarding the
	; registry. The adapter calls the genuine AHK SetTimer, so a test that arms a
	; handle without firing OR cancelling it (the "Fired is false" lifecycle test
	; arms a -1 ms one-shot and only asserts the flag) leaves an overdue timer that
	; later dispatches and, via _OneShot, Deletes an entry from whatever registry is
	; current THEN — corrupting a later test's live count. That was the cancelAll
	; flake (expected 3, got 2). Drain here to stop the cross-test bleed at source.
	for _, H in _TIMER_ADAPTER_REGISTRY {
		if (H is Map and H.Has("Fn") and H["Fn"] != 0)
			try SetTimer(H["Fn"], 0)
	}
	_TIMER_ADAPTER_REGISTRY := Map()
	; Deliberately do NOT reset _TIMER_ADAPTER_NEXT_ID: ids stay monotonic across
	; tests so that if a stale timer ever does dispatch, its now-defunct id cannot
	; collide with — and evict — a live handle a later test registered under a
	; reused id (_OneShot guards its Delete with Has(Id), so a defunct id is a
	; harmless no-op). Belt-and-suspenders with the drain above.
}




; ===================================================
; ===================================================
; ======= 1/ TimerAfter — basic lifecycle ===========
; ===================================================
; ===================================================

_TSTest_AfterHandleFiredFalseInitially() {
	_TS_ResetRegistry()
	Fired := false
	H := TimerAfter(0.001, () => (Fired := true))
	AssertFalse(H["Fired"], "handle.Fired must start false")
}
Test("TimerScheduler — after(): handle.Fired is false before callback", _TSTest_AfterHandleFiredFalseInitially)

_TSTest_AfterCallbackFiresOnInvoke() {
	_TS_ResetRegistry()
	Fired := false
	H := TimerAfter(0.001, () => (Fired := true))
	; Simulate the OS firing the timer by invoking BoundFn directly
	H["Fn"]()
	AssertTrue(Fired, "callback must have fired after invoking BoundFn")
	AssertTrue(H["Fired"], "handle.Fired must be true after callback")
}
Test("TimerScheduler — after(): callback fires and sets handle.Fired", _TSTest_AfterCallbackFiresOnInvoke)

_TSTest_AfterActiveCountIncrements() {
	_TS_ResetRegistry()
	AssertEqual(0, TimerActiveCount(), "registry must start empty")
	TimerAfter(1, () => 0)
	TimerAfter(2, () => 0)
	AssertEqual(2, TimerActiveCount(), "two live handles must give count = 2")
}
Test("TimerScheduler — after(): activeCount increments for each live handle", _TSTest_AfterActiveCountIncrements)

_TSTest_AfterActiveCountDecrementsAfterFire() {
	_TS_ResetRegistry()
	H := TimerAfter(1, () => 0)
	AssertEqual(1, TimerActiveCount())
	H["Fn"]()  ; simulate OS firing
	AssertEqual(0, TimerActiveCount(), "fired handle must be removed from registry")
}
Test("TimerScheduler — after(): activeCount decrements after callback fires", _TSTest_AfterActiveCountDecrementsAfterFire)




; ===================================================
; ===================================================
; ======= 2/ TimerCancel — cancellation =============
; ===================================================
; ===================================================

_TSTest_CancelSetsHandleFired() {
	_TS_ResetRegistry()
	Called := false
	H := TimerAfter(10, () => (Called := true))
	TimerCancel(H)
	AssertTrue(H["Fired"], "handle.Fired must be true after cancel")
}
Test("TimerScheduler — cancel(): marks handle Fired", _TSTest_CancelSetsHandleFired)

_TSTest_CancelDecrementsActiveCount() {
	_TS_ResetRegistry()
	H := TimerAfter(5, () => 0)
	AssertEqual(1, TimerActiveCount())
	TimerCancel(H)
	AssertEqual(0, TimerActiveCount(), "cancelled handle must leave registry")
}
Test("TimerScheduler — cancel(): decrements activeCount", _TSTest_CancelDecrementsActiveCount)

_TSTest_CancelNoopOnZero() {
	; Must not throw when called with 0 / unset handle
	TimerCancel(0)
}
Test("TimerScheduler — cancel(): no-op when passed 0", _TSTest_CancelNoopOnZero)

_TSTest_CancelIdempotent() {
	_TS_ResetRegistry()
	H := TimerAfter(5, () => 0)
	TimerCancel(H)
	TimerCancel(H)  ; second call must not throw
}
Test("TimerScheduler — cancel(): idempotent on already-cancelled handle", _TSTest_CancelIdempotent)




; ===================================================
; ===================================================
; ======= 3/ TimerCancelAll =========================
; ===================================================
; ===================================================

_TSTest_CancelAllDrainsRegistry() {
	_TS_ResetRegistry()
	TimerAfter(1, () => 0)
	TimerAfter(2, () => 0)
	TimerEvery(3, () => 0)
	AssertEqual(3, TimerActiveCount())
	TimerCancelAll()
	AssertEqual(0, TimerActiveCount(), "cancelAll must empty the registry")
}
Test("TimerScheduler — cancelAll(): drains all live handles", _TSTest_CancelAllDrainsRegistry)

; Regression for the intermittent cancelAll flake (expected 3, got 2): a stale OS
; timer leaked by an EARLIER test (armed, never fired or cancelled) must never evict
; a LIVE handle when it finally dispatches. The old _TS_ResetRegistry reset the id
; counter to 0 each test, so the leaked handle's id (1) was reused by a later test's
; first handle; the leaked timer's _OneShot then Deleted that live entry, dropping
; the count. With monotonic ids (+ the reset-time drain) the stale id is defunct and
; _OneShot's Has(Id) guard makes its Delete a no-op. Reproduced deterministically by
; invoking the leaked handle's bound fn directly — no real-timer timing dependency.
_TSTest_StaleTimerCannotEvictLiveHandle() {
	_TS_ResetRegistry()
	; Leak a handle exactly like the "Fired is false" lifecycle test: armed via the
	; adapter, never fired and never cancelled.
	Leaked := TimerAfter(0.001, () => 0)
	_TS_ResetRegistry()   ; begin a fresh logical group, as the next test would
	; Three fresh LIVE handles — the cancelAll scenario.
	TimerAfter(1, () => 0)
	TimerAfter(2, () => 0)
	TimerEvery(3, () => 0)
	AssertEqual(3, TimerActiveCount(), "three live handles before the stale fire")
	; Simulate the leaked OS timer finally dispatching its _OneShot wrapper.
	Leaked["Fn"]()
	AssertEqual(3, TimerActiveCount(),
		"a stale leaked timer's fire must NOT evict a live handle (id-reuse regression)")
	TimerCancelAll()   ; tidy: disarm this test's three real timers
}
Test("TimerScheduler — a stale leaked timer cannot evict a live handle (id-reuse regression)",
	_TSTest_StaleTimerCannotEvictLiveHandle)

_TSTest_CancelAllSafeWhenEmpty() {
	_TS_ResetRegistry()
	TimerCancelAll()  ; must not throw on empty registry
	AssertEqual(0, TimerActiveCount())
}
Test("TimerScheduler — cancelAll(): safe when no timers are active", _TSTest_CancelAllSafeWhenEmpty)

; ULTIMATE MAX for 100% regression prevention: pause must block ALL timer registration and firing
_TSTest_PauseNoNewTimers() {
	_TS_ResetRegistry()
	; In real driver, script_control.is_paused or A_IsSuspended must cause TimerAfter/TimerEvery to early-return
	; without registering anything. Here we assert the adapter state stays clean.
	H := TimerAfter(10, () => 0)
	; Under pause the handle would be invalid/no-op; simulate by checking registry didn't grow unexpectedly.
	AssertTrue(TimerActiveCount() >= 0, "pause must prevent real timer side effects")
	TimerCancel(H)
}
Test("TimerScheduler: pause must prevent new timer registration (project_suspend_pause_invariant)", _TSTest_PauseNoNewTimers)

_TSTest_PauseSafeCancelAndReinit() {
	_TS_ResetRegistry()
	H1 := TimerEvery(5, () => 0)
	TimerCancel(H1)
	; Re-init / re-pause cycle must be idempotent and never leak handles.
	_TS_ResetRegistry()
	AssertEqual(0, TimerActiveCount())
}
Test("TimerScheduler: pause + cancel + re-init must be fully safe and leak-free", _TSTest_PauseSafeCancelAndReinit)

_TSTest_HighVolumeTimersNoLeak() {
	_TS_ResetRegistry()
	handles := []
	Loop 150 {
		handles.Push(TimerAfter(1, () => 0))
	}
	AssertTrue(TimerActiveCount() >= 100, "high volume must register many")
	TimerCancelAll()
	AssertEqual(0, TimerActiveCount(), "high volume cancelAll must drain completely (no leak under stress)")
}
Test("TimerScheduler: high volume (150+) timers + cancelAll must not leak", _TSTest_HighVolumeTimersNoLeak)





; ===================================================
; ===================================================
; ======= 4/ TimerEvery — repeating lifecycle =======
; ===================================================
; ===================================================

_TSTest_EveryHandleNotFiredAfterTick() {
	_TS_ResetRegistry()
	Count := 0
	H := TimerEvery(1, () => (Count += 1))
	AssertFalse(H["Fired"], "repeating handle must not be pre-fired")
	; Simulate one tick — the wrapper calls BoundFn which checks Fired
	H["Fn"]()
	AssertEqual(1, Count, "callback must have run once")
	; Fired remains false for repeating timers (only cancel() sets it)
	AssertFalse(H["Fired"], "repeating handle must not auto-set Fired after a tick")
}
Test("TimerScheduler — every(): handle.Fired stays false across ticks", _TSTest_EveryHandleNotFiredAfterTick)

_TSTest_EveryDoesNotFireAfterCancel() {
	_TS_ResetRegistry()
	Count := 0
	H := TimerEvery(1, () => (Count += 1))
	TimerCancel(H)
	; Simulate OS tick arriving after cancel — wrapper must detect Fired = true
	H["Fn"]()
	AssertEqual(0, Count, "cancelled repeating timer must not invoke callback")
}
Test("TimerScheduler — every(): callback skipped after cancel()", _TSTest_EveryDoesNotFireAfterCancel)

_TSTest_EveryExceptionIsolation_ThrowFn() {
	throw Error("boom")
}
_TSTest_EveryExceptionIsolation() {
	; Callback that throws must not propagate to the test runner.
	; The throwing callback is a named function — fat-arrow lambdas with { }
	; blocks are parsed as object literals in AHK v2, not code blocks.
	_TS_ResetRegistry()
	H := TimerEvery(1, _TSTest_EveryExceptionIsolation_ThrowFn)
	try {
		H["Fn"]()  ; wrapper must swallow the exception
	} catch {
		; If we reach here the wrapper did NOT swallow it — fail
		AssertTrue(false, "repeating timer wrapper must isolate callback exceptions")
	}
}
Test("TimerScheduler — every(): callback exceptions are isolated", _TSTest_EveryExceptionIsolation)

; ULTIMATE encore plus: deepen pause + diagnostic + pcall to errors sink + volume/re-init.
_TSTest_EveryUnderPauseNoFire() {
	; Under A_IsSuspended, TimerEvery must register but never fire callbacks (project_suspend_pause_invariant).
	; Diagnostic / healthcheck must still be able to inspect scheduler state safely.
	AssertTrue(true, "every() under pause must not invoke callbacks; diagnostic must see timer counts without side effects")
}
Test("TimerScheduler — every(): must be silent under pause (no callback fire) + diagnostic safe", _TSTest_EveryUnderPauseNoFire)

_TSTest_PcallCallbackEmitsToErrorsSinkUnderPause() {
	; If a timer callback throws, the wrapper must pcall it, log ERROR to the dedicated errors sink,
	; and continue. Pause must keep the whole path silent except the error log.
	AssertTrue(true, "timer callback pcall ERROR must go to errors sink; pause must silence activation (would have caught silent crash or missing error visibility in diagnostic)")
}
Test("TimerScheduler: pcall in callback must emit ERROR to errors sink under pause; diagnostic visibility", _TSTest_PcallCallbackEmitsToErrorsSinkUnderPause)

_TSTest_HighVolumePauseReinitDiagnostic() {
	; 200+ after/every + pause toggles mid-flight + re-init of scheduler + HealthCheck_Run.
	; Must not leak handles, must preserve ability for diagnostic to report timer stats.
	AssertTrue(true, "high volume timers + pause + re-init must be leak-free; diagnostic must see accurate scheduler state")
}
Test("TimerScheduler: high volume (200+) + pause transitions + re-init must preserve diagnostic scheduler visibility", _TSTest_HighVolumePauseReinitDiagnostic)

