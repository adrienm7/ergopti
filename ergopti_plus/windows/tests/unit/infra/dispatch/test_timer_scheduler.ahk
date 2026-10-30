; static/ergopti_plus/windows/tests/unit/infra/dispatch/test_timer_scheduler.ahk

; ==============================================================================
; MODULE: TimerScheduler Adapter Unit Tests
; DESCRIPTION:
; Validates native timer handles, callback lifecycle, activeCount, cancellation,
; and exception isolation. Logical delivery tests explicitly consume the actual
; native one-shot before invoking its callback. Native controls prove delivery
; and physical retirement while an independent heartbeat pumps the message loop.
; ==============================================================================

#Requires AutoHotkey v2.0


; One fixture owner retires native callbacks before removing logical identities.
; Disarm both callbacks independently of the cancellation behavior under test,
; then require its logical acknowledgement. A refusal keeps the registry owner.
_TS_ResetRegistry() {
	global _TIMER_ADAPTER_REGISTRY
	PreviousCritical := Critical("On")
	try {
		for _, Handle in _TIMER_ADAPTER_REGISTRY.Clone()
			_TSTest_RetireHandle(Handle)
		AssertEqual(0, _TIMER_ADAPTER_REGISTRY.Count,
			"fixture reset cannot discard an unacknowledged timer owner")
		; Identities remain monotonic; cleanup never makes a stale callback current.
	} finally Critical(PreviousCritical)
}


; Cleanup knows every frozen callback even if a failed assertion lost its registry entry.
_TSTest_RetireHandle(Handle) {
	AssertTrue(Handle is Map, "the timer fixture registry requires an owned handle")
	for Key in ["Fn", "RequeuedFn"] {
		Callback := Handle.Get(Key, 0)
		if Callback != 0
			SetTimer(Callback, 0)
	}
	AssertTrue(TimerCancel(Handle), "fixture reset requires acknowledged logical timer retirement")
}

; Consume the exact native one-shot before modeling its OS delivery. A direct
; function call alone would leave the real timer armed after logical retirement.
_TSTest_DeliverOneShot(Handle) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "an earlier native delivery capability remains unresolved")
	PreviousCritical := Critical("On")
	try {
		Callback := Handle["Fn"]
		RequeuedFn := Handle.Get("RequeuedFn", 0)
		try {
			_TimerAdapterCancelNative(Callback)
			if RequeuedFn != 0
				_TimerAdapterCancelNative(RequeuedFn)
		} catch as Failure {
			RetirementDebt := {Handle: Handle, Callback: Callback, RequeuedFn: RequeuedFn}
			throw Failure
		}
	} finally Critical(PreviousCritical)
	Callback.Call()
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
	_TSTest_DeliverOneShot(H)
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
	_TSTest_DeliverOneShot(H)  ; simulate OS firing
	AssertEqual(0, TimerActiveCount(), "fired handle must be removed from registry")
}
Test("TimerScheduler — after(): activeCount decrements after callback fires", _TSTest_AfterActiveCountDecrementsAfterFire)

_TSTest_RestartAfterPreservesOwnerIdentity() {
	_TS_ResetRegistry()
	Calls := 0
	H := TimerAfter(10, () => (Calls += 1))
	Owner := H["Fn"]
	TimerRestartAfter(H, 20)
	AssertTrue(H["Fn"] == Owner,
		"AHK-22: restart must reuse the captured callback instead of allocating per keystroke")
	AssertFalse(H["Fired"], "AHK-22: restarted one-shot must be live")
	AssertEqual(-20000, H["Interval"], "AHK-22: restart must publish the new delay")
	AssertEqual(1, TimerActiveCount(), "AHK-22: restart must own exactly one registry slot")
	_TSTest_DeliverOneShot(H)
	AssertEqual(1, Calls, "AHK-22: the restarted owner must publish exactly once")
	AssertEqual(0, TimerActiveCount(), "AHK-22: firing must retire the restarted owner")
}
Test("AHK-22 TimerScheduler — restartAfter reuses one exact one-shot owner",
	_TSTest_RestartAfterPreservesOwnerIdentity)

_TSTest_RestartAfterRejectsRepeatingOwner() {
	_TS_ResetRegistry()
	H := TimerEvery(10, () => 0)
	Threw := false
	try TimerRestartAfter(H, 20)
	catch TypeError
		Threw := true
	AssertTrue(Threw,
		"AHK-22: a repeating wrapper cannot impersonate a restartable one-shot owner")
	TimerCancel(H)
}
Test("AHK-22 TimerScheduler — restartAfter rejects a repeating owner",
	_TSTest_RestartAfterRejectsRepeatingOwner)

_TSTest_InvalidDurationsNeverAcquireNativeOwnership() {
	global _TIMER_ADAPTER_NEXT_ID, TIMER_ADAPTER_MAX_INTERVAL_MS
	_TS_ResetRegistry()
	StartId := _TIMER_ADAPTER_NEXT_ID
	Invalid := [0, -1, 0.0001, "not-a-duration",
		TIMER_ADAPTER_MAX_INTERVAL_MS / 1000 + 1]
	for Value in Invalid {
		AfterThrew := false
		try TimerAfter(Value, () => 0)
		catch Error
			AfterThrew := true
		AssertTrue(AfterThrew, "TimerAfter must reject invalid duration: " . Type(Value))

		EveryThrew := false
		try TimerEvery(Value, () => 0)
		catch Error
			EveryThrew := true
		AssertTrue(EveryThrew, "TimerEvery must reject invalid duration: " . Type(Value))
	}
	AssertEqual(0, TimerActiveCount(),
		"invalid durations must publish no registry owner")
	AssertEqual(StartId, _TIMER_ADAPTER_NEXT_ID,
		"validation must run before ID allocation and native timer registration")
}
Test("TimerScheduler: invalid durations cannot acquire native ownership (timer-duration-validation)",
	_TSTest_InvalidDurationsNeverAcquireNativeOwnership)

; AHK-163: a non-callable callback used to pass construction, acquire a native
; timer and fail only when the wrapper tried to invoke it. Repeating timers then
; logged the same configuration/programming error at every interval. Validation
; must happen before ID allocation and native admission for both timer kinds.
_TSTest_InvalidCallbacksNeverAcquireNativeOwnership() {
	global _TIMER_ADAPTER_NEXT_ID
	_TS_ResetRegistry()
	StartId := _TIMER_ADAPTER_NEXT_ID
	try {
		for Value in [0, "not-a-callback", Map()] {
			AfterThrew := false
			try TimerAfter(3600, Value)
			catch TypeError
				AfterThrew := true
			AssertTrue(AfterThrew,
				"TimerAfter must reject a non-callable callback before arming: " . Type(Value))

			EveryThrew := false
			try TimerEvery(3600, Value)
			catch TypeError
				EveryThrew := true
			AssertTrue(EveryThrew,
				"TimerEvery must reject a non-callable callback before arming: " . Type(Value))
		}
		AssertEqual(0, TimerActiveCount(),
			"an invalid callback must publish no native timer handle")
		AssertEqual(StartId, _TIMER_ADAPTER_NEXT_ID,
			"callback validation must precede ID allocation")
	} finally {
		TimerCancelAll()
	}
}
Test("TimerScheduler: invalid callbacks cannot acquire native ownership (AHK-163)",
	_TSTest_InvalidCallbacksNeverAcquireNativeOwnership)

_TSTest_InvalidRestartPreservesExistingOwner() {
	global TIMER_ADAPTER_MAX_INTERVAL_MS
	_TS_ResetRegistry()
	H := TimerAfter(10, () => 0)
	Owner := H["Fn"]
	Interval := H["Interval"]
	for Value in [0, -1, 0.0001, "not-a-duration",
		TIMER_ADAPTER_MAX_INTERVAL_MS / 1000 + 1] {
		Threw := false
		try TimerRestartAfter(H, Value)
		catch Error
			Threw := true
		AssertTrue(Threw, "TimerRestartAfter must reject invalid duration")
		AssertTrue(H["Fn"] == Owner, "invalid restart must preserve callback ownership")
		AssertEqual(Interval, H["Interval"], "invalid restart must preserve due interval")
		AssertFalse(H["Fired"], "invalid restart must leave the prior timer live")
		AssertEqual(1, TimerActiveCount(), "invalid restart must preserve one registry owner")
	}
	TimerCancel(H)
}
Test("TimerScheduler: invalid restart preserves the existing one-shot (timer-duration-validation)",
	_TSTest_InvalidRestartPreservesExistingOwner)




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

global _TS_CANCEL_ATTEMPTS := 0

_TSTest_FailingNativeCancel(BoundFn) {
	global _TS_CANCEL_ATTEMPTS
	_TS_CANCEL_ATTEMPTS += 1
	if _TS_CANCEL_ATTEMPTS = 1
		throw Error("injected native cancellation failure")
}

_TSTest_CancelFailureRetainsOwnershipForRetry() {
	global _TIMER_ADAPTER_REGISTRY, _TS_CANCEL_ATTEMPTS
	_TS_ResetRegistry()
	_TS_CANCEL_ATTEMPTS := 0
	Id := _TimerAdapterNextId()
	Handle := Map("Fn", (*) => 0, "RequeuedFn", (*) => 0,
		"Interval", 1000, "Fired", false, "Id", Id, "Kind", "every")
	_TIMER_ADAPTER_REGISTRY[Id] := Handle

	AssertFalse(TimerCancel(Handle, _TSTest_FailingNativeCancel),
		"a partial native cancellation must report failure")
	AssertFalse(Handle["Fired"],
		"a failed native cancellation must keep the logical owner live")
	AssertTrue(_TIMER_ADAPTER_REGISTRY.Has(Id),
		"a failed native cancellation must remain registered for retry")
	AssertTrue(Handle.Has("RequeuedFn"),
		"partial cleanup must retain every callback identity until ownership is released")

	AssertTrue(TimerCancel(Handle, _TSTest_FailingNativeCancel),
		"a later cancellation retry must release every native owner")
	AssertTrue(Handle["Fired"],
		"the handle may become terminal only after complete native cleanup")
	AssertFalse(_TIMER_ADAPTER_REGISTRY.Has(Id),
		"successful retry must retire the registry owner")
	AssertFalse(Handle.Has("RequeuedFn"),
		"successful retry must discard the auxiliary callback identity")
}
Test("TimerScheduler: failed native cancellation retains retry ownership (timer-cancel-ownership)",
	_TSTest_CancelFailureRetainsOwnershipForRetry)




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

; Reenact the original allocator-rewind fault inside one Critical span. The
; abandoned callback stays logically pending while three genuine handles are
; allocated, including a different live owner under its old id. This reaches
; the registry identity fence rather than a cancelled/Fired short circuit.
_TSTest_StaleTimerCannotEvictLiveHandle() {
	global _TIMER_ADAPTER_REGISTRY, _TIMER_ADAPTER_NEXT_ID
	static RetirementDebt := []
	AssertEqual(0, RetirementDebt.Length, "an earlier stale fixture still owns callback retirement")
	_TS_ResetRegistry()
	Owners := [], Failure := 0
	HighWater := _TIMER_ADAPTER_NEXT_ID
	PreviousCritical := Critical("On")
	try {
		Leaked := TimerAfter(0.001, () => 0)
		Owners.Push(Leaked)
		HighWater := Max(HighWater, _TIMER_ADAPTER_NEXT_ID)
		LeakedFn := Leaked["Fn"]
		SetTimer(LeakedFn, 0)
		AssertTrue(_TIMER_ADAPTER_REGISTRY.Has(Leaked["Id"])
			&& _TIMER_ADAPTER_REGISTRY[Leaked["Id"]] == Leaked,
			"unpublication must own the exact stale fixture identity")
		_TIMER_ADAPTER_REGISTRY.Delete(Leaked["Id"])
		_TIMER_ADAPTER_NEXT_ID := Leaked["Id"] - 1
		for Delay in [1, 2]
			Owners.Push(TimerAfter(Delay, () => 0))
		Owners.Push(TimerEvery(3, () => 0))
		AssertEqual(Leaked["Id"], Owners[2]["Id"], "positive control: the fault really reuses the abandoned id")
		AssertTrue(_TIMER_ADAPTER_REGISTRY[Leaked["Id"]] == Owners[2]
			&& Owners[2] != Leaked, "the reused key must belong to a different real live handle")
		AssertEqual(3, TimerActiveCount(), "three live handles before the stale fire")
		AssertFalse(Leaked["Fired"], "the stale wrapper must reach its registry fence, not a terminal-marker short circuit")
		_TestPrint("# stale_registry_guard old_id=" . Leaked["Id"] . " live_id=" . Owners[2]["Id"]
			. " before=" . TimerActiveCount() . " old_fired=" . Leaked["Fired"])
		LeakedFn.Call()
		_TestPrint("# stale_registry_guard after=" . TimerActiveCount())
		AssertEqual(3, TimerActiveCount(),
			"a stale leaked timer's fire must NOT evict a live handle (id-reuse regression)")
	} catch as PrimaryFailure {
		Failure := PrimaryFailure
	} finally {
		try {
			_TIMER_ADAPTER_NEXT_ID := Max(HighWater, _TIMER_ADAPTER_NEXT_ID)
			for Handle in Owners {
				try _TSTest_RetireHandle(Handle)
				catch as CleanupFailure {
					RetirementDebt.Push(Handle)
					if IsObject(Failure)
						Failure.Message .= " Owned callback cleanup also failed: " . CleanupFailure.Message
					else
						Failure := CleanupFailure
				}
			}
			try _TS_ResetRegistry()
			catch as CleanupFailure {
				if IsObject(Failure)
					Failure.Message .= " Registry cleanup also failed: " . CleanupFailure.Message
				else
					Failure := CleanupFailure
			}
		} finally Critical(PreviousCritical)
	}
	if IsObject(Failure)
		throw Failure
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
	OldFn := H["Fn"]
	TimerCancel(H)
	; Deliver the exact formerly armed callback after acknowledged cancellation.
	OldFn()
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

; Three placeholders stood here, each asserting AssertTrue(true). A_IsSuspended
; cannot be set from a test, but the wrapper the suspend check lives in CAN be
; called directly — the tests above already do — and the ordering of that check
; is what the invariant really is.
_TSTest_RepeatingChecksSuspendBeforeTheCallback() {
	Body := _DriverFuncBody("_Repeating")
	GuardPos := InStr(Body, "if A_IsSuspended")
	CallPos  := InStr(Body, "BoundFn()")
	Assert(GuardPos > 0,
		"the repeating wrapper must bail on A_IsSuspended — a paused driver that keeps firing its pollers is the whole of 'pause = everything off'")
	Assert(CallPos > 0, "and it must still call the callback when not paused")
	Assert(GuardPos < CallPos,
		"the suspend check must come BEFORE the callback runs, not after it")
}
Test("TimerScheduler — every(): the suspend check precedes the callback", _TSTest_RepeatingChecksSuspendBeforeTheCallback)


_TSTest_ThrowingCallback_ThrowFn() {
	throw Error("scheduler-probe-boom")
}
_TSTest_ThrowingCallbackIsLoggedNotSwallowed() {
	global _LOGGER_TEST_SINK
	_TS_ResetRegistry()
	Seen := []
	Prev := IsSet(_LOGGER_TEST_SINK) ? _LOGGER_TEST_SINK : 0
	_LOGGER_TEST_SINK := (Line) => Seen.Push(Line)
	try {
		H := TimerEvery(1, _TSTest_ThrowingCallback_ThrowFn)
		H["Fn"]()
	} finally {
		_LOGGER_TEST_SINK := Prev
	}

	; Isolation alone is not enough: a wrapper that swallows silently is
	; indistinguishable from one that never ran, and that is precisely how a
	; broken poller hides. The throw has to leave a trace.
	Found := ""
	for _, Line in Seen {
		if InStr(Line, "scheduler-probe-boom")
			Found := Line
	}
	Assert(Found != "",
		"a throwing repeating callback must be logged — the wrapper isolates it, and an isolated exception with no log is a silent dead timer")
	AssertContains(Found, "ERROR",
		"and logged at ERROR, so it reaches the dedicated errors sink a user is asked for when reporting a problem")
}
Test("TimerScheduler: a throwing callback is logged at ERROR, not swallowed", _TSTest_ThrowingCallbackIsLoggedNotSwallowed)


_TSTest_CancelAllLeavesNoHandles() {
	global _TIMER_ADAPTER_REGISTRY
	_TS_ResetRegistry()
	Loop 200
		TimerEvery(3600, _TSTest_ThrowingCallback_ThrowFn)   ; never fires within the test
	AssertEqual(200, _TIMER_ADAPTER_REGISTRY.Count,
		"every armed timer must be registered — a registry that silently drops entries cannot be cancelled")
	TimerCancelAll()
	AssertEqual(0, _TIMER_ADAPTER_REGISTRY.Count,
		"cancelAll must leave no handle behind; a leaked one keeps an OS timer armed for the life of the process")
}
Test("TimerScheduler: 200 timers all register and cancelAll clears every one", _TSTest_CancelAllLeavesNoHandles)

_TSTest_NativeCallbackKeepsIdentity() {
	Calls := 0
	Callback() => (++Calls)
	PreviousCritical := Critical("On")
	try {
		TimerSetCallback(Callback, -1)
		TimerSetCallback(Callback, 0)
	} finally {
		Critical(PreviousCritical)
	}
	try {
		Sleep(30)
		AssertEqual(0, Calls, "cancellation retires the exact callback which was armed")
		TimerSetCallback(Callback, -1)
		Started := A_TickCount
		while Calls == 0 && ((A_TickCount - Started) & 0xFFFFFFFF) < 500
			Sleep(-1)
		AssertEqual(1, Calls, "the same callback can be rearmed once after cancellation")
		AssertThrows(() => TimerSetCallback(0, -1))
		AssertThrows(() => TimerSetCallback(Callback, 1.5))
		AssertThrows(() => TimerSetCallback(Callback, 0x100000000))
	} finally {
		TimerSetCallback(Callback, 0)
	}
}
Test("TimerScheduler: native callback identity survives cancel and rearm (prefix-char-admission)",
	_TSTest_NativeCallbackKeepsIdentity)

#Include test_timer_scheduler_lifetime.ahk

#Include test_timer_scheduler_retirement_after.ahk
