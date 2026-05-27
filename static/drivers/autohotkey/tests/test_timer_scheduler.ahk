; static/drivers/autohotkey/tests/test_timer_scheduler.ahk

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
	global _TIMER_ADAPTER_REGISTRY, _TIMER_ADAPTER_NEXT_ID
	_TIMER_ADAPTER_REGISTRY := Map()
	_TIMER_ADAPTER_NEXT_ID  := 0
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

_TSTest_CancelAllSafeWhenEmpty() {
	_TS_ResetRegistry()
	TimerCancelAll()  ; must not throw on empty registry
	AssertEqual(0, TimerActiveCount())
}
Test("TimerScheduler — cancelAll(): safe when no timers are active", _TSTest_CancelAllSafeWhenEmpty)





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

_TSTest_EveryExceptionIsolation() {
	; Callback that throws must not propagate to the test runner
	_TS_ResetRegistry()
	H := TimerEvery(1, () => { throw Error("boom") })
	try {
		H["Fn"]()  ; wrapper must swallow the exception
	} catch {
		; If we reach here the wrapper did NOT swallow it — fail
		AssertTrue(false, "repeating timer wrapper must isolate callback exceptions")
	}
}
Test("TimerScheduler — every(): callback exceptions are isolated", _TSTest_EveryExceptionIsolation)
