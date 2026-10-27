; tests/unit/infra/dispatch/test_timer_scheduler_suspend.ahk

; ==============================================================================
; MODULE: TimerScheduler Suspend/Re-queue Regression Tests
; DESCRIPTION:
; Regression tests for F25 -- cancel-of-requeued-timer bug.
; When a one-shot timer fires while A_IsSuspended is true, _OneShot re-queues
; itself via a new closure stored in SetTimer. Before F25 the original handle
; had no reference to that re-queued closure, so TimerCancel could not reach it
; and the timer fired indefinitely.
;
; APPROACH:
; Keep the logical handle and source invariants. Cancellation cases also use
; actual native delivery to prove arming, observe exact cancellation requests,
; and watch the same callback after its due time. An independent native
; heartbeat proves that this observation window really pumps timers.
; ==============================================================================

#Requires AutoHotkey v2.0


_TS_ResetRegistrySuspend() {
	global _TIMER_ADAPTER_REGISTRY
	for _, H in _TIMER_ADAPTER_REGISTRY {
		if (H is Map and H.Has("Fn") and H["Fn"] != 0)
			try SetTimer(H["Fn"], 0)
	}
	_TIMER_ADAPTER_REGISTRY := Map()
}

; A real native delivery proves the requeue callback is armed before cancellation.
_TSSuspTest_NativePulse(Ledger) {
	Ledger.Calls += 1
}

_TSSuspTest_ObservedNativeCancel(Calls, Callback) {
	_TimerAdapterCancelNative(Callback)
	Calls.Push(Callback)
}

_TSSuspTest_NativeRequeueCancellation(Mode) {
	global _TIMER_ADAPTER_REGISTRY
	static NativePeriodMs := 10, DeliveryDeadlineMs := 1000, ObservationMs := 100
	static NativeRetirementDebt := []
	AssertEqual(0, NativeRetirementDebt.Length, "an earlier exact native callback still needs retirement")
	AssertFalse(A_IsCritical || A_IsSuspended, "native controls require interruptible timer delivery")
	AssertEqual(0, _TIMER_ADAPTER_REGISTRY.Count, "the native fixture cannot retire foreign timers")
	Owners := [], Cancelled := [], Original := {Calls: 0}, Heartbeat := {Calls: 0}
	HeartbeatFn := _TSSuspTest_NativePulse.Bind(Heartbeat)
	Failure := 0, CleanupFailures := []
	try {
		Loop Mode == "all" ? 2 : 1 {
			Ledger := {Calls: 0}
			Owner := {Ledger: Ledger, Callback: _TSSuspTest_NativePulse.Bind(Ledger),
				Handle: 0, Primary: 0, PositiveCalls: 0}
			Owners.Push(Owner)
			SetTimer(Owner.Callback, -NativePeriodMs)
			Started := DllCall("Kernel32\GetTickCount64", "UInt64")
			while Ledger.Calls == 0 && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < DeliveryDeadlineMs
				Sleep(1)
			AssertEqual(1, Ledger.Calls, "positive control: the exact native requeue callback really delivers once")
			Owner.PositiveCalls := Ledger.Calls
			Ledger.Calls := 0
		}
		PreviousCritical := Critical("On")
		try {
			for Owner in Owners {
				Owner.Handle := TimerAfter(10, _TSSuspTest_NativePulse.Bind(Original))
				Owner.Primary := Owner.Handle["Fn"]
				Owner.Handle["RequeuedFn"] := Owner.Callback
				SetTimer(Owner.Callback, -NativePeriodMs)
			}
			if Mode == "all"
				AssertTrue(TimerCancelAll(), "cancelAll acknowledges the genuine native requests")
			else {
				AssertTrue(TimerCancel(Owners[1].Handle, _TSSuspTest_ObservedNativeCancel.Bind(Cancelled)),
					"cancel acknowledges the genuine native requests")
				if Mode == "twice"
					AssertTrue(TimerCancel(Owners[1].Handle, _TSSuspTest_ObservedNativeCancel.Bind(Cancelled)),
						"duplicate cancellation acknowledges the already settled owner")
			}
			for Owner in Owners {
				AssertTrue(Owner.Handle["Fired"], "the cancelled handle retains its terminal marker")
				AssertFalse(Owner.Handle.Has("RequeuedFn"), "the cancelled handle retires its requeue reference")
			}
			AssertEqual(0, TimerActiveCount(), "all exact cancelled owners leave the registry")
		} finally Critical(PreviousCritical)

		SetTimer(HeartbeatFn, NativePeriodMs)
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while DllCall("Kernel32\GetTickCount64", "UInt64") - Started < ObservationMs
			Sleep(1)
		AssertTrue(Heartbeat.Calls > 0, "an independent native heartbeat proves the observation window pumped timers")
		for Owner in Owners
			_TestPrint("# native_requeue mode=" . Mode . " positive=" . Owner.PositiveCalls
				. " late=" . Owner.Ledger.Calls . " heartbeat=" . Heartbeat.Calls
				. " observed_cancel_requests=" . Cancelled.Length)
		for Owner in Owners
			AssertEqual(0, Owner.Ledger.Calls, "a cancelled native requeue must not dispatch after its due time")
		AssertEqual(0, Original.Calls, "cancellation cannot dispatch the original user callback")
		if Mode != "all" {
			AssertEqual(2, Cancelled.Length, "the actual native cancellation retires primary and requeue exactly once")
			AssertEqual(ObjPtr(Owners[1].Primary), ObjPtr(Cancelled[1]), "native cancellation targets the exact primary")
			AssertEqual(ObjPtr(Owners[1].Callback), ObjPtr(Cancelled[2]), "native cancellation targets the exact armed requeue")
		}
	} catch as PrimaryFailure {
		Failure := PrimaryFailure
	} finally {
		PreviousCritical := Critical("On")
		try {
			Callbacks := [HeartbeatFn]
			for Owner in Owners {
				Callbacks.Push(Owner.Callback)
				if IsObject(Owner.Primary)
					Callbacks.Push(Owner.Primary)
			}
			for Callback in Callbacks {
				try _TimerAdapterCancelNative(Callback)
				catch as CleanupFailure {
					NativeRetirementDebt.Push(Callback)
					CleanupFailures.Push(CleanupFailure.Message)
				}
			}
			for Owner in Owners {
				if Owner.Handle is Map {
					try AssertTrue(TimerCancel(Owner.Handle), "fixture cleanup must acknowledge its exact timer owner")
					catch as CleanupFailure {
						NativeRetirementDebt.Push(Owner)
						CleanupFailures.Push(CleanupFailure.Message)
					}
				}
			}
		} finally Critical(PreviousCritical)
	}
	for Message in CleanupFailures {
		if IsObject(Failure)
			Failure.Message .= " Native callback cleanup also failed: " . Message
		else
			Failure := Error("Native callback cleanup failed: " . Message)
	}
	if IsObject(Failure)
		throw Failure
}





; =====================================================================
; =====================================================================
; ======= 1/ RequeuedFn stored when suspend branch is taken ===========
; =====================================================================
; =====================================================================

; When a one-shot fires during suspension the _OneShot wrapper stores a
; re-queued closure under handle["RequeuedFn"]. Simulate this by manually
; populating the key and verify TimerCancel reads and clears it.
_TSSuspTest_CancelClearsRequeuedFn() {
	_TS_ResetRegistrySuspend()
	Called := false
	H := TimerAfter(10, () => (Called := true))
	; Simulate the suspend-requeue path: store a sentinel closure as RequeuedFn
	; (the real path sets this in _OneShot when A_IsSuspended is true).
	SentinelFired := false
	Sentinel := () => (SentinelFired := true)
	H["RequeuedFn"] := Sentinel
	; Cancel the handle -- must drain RequeuedFn via SetTimer(RequeuedFn, 0).
	; Logical handle state remains required alongside the native observations
	; below, which prove that the exact armed callback cannot dispatch later.
	TimerCancel(H)
	AssertTrue(H["Fired"], "handle.Fired must be true after cancel with RequeuedFn set")
	AssertFalse(Called, "original callback must not have fired on cancel")
	_TSSuspTest_NativeRequeueCancellation("cancel")
}
Test("TimerScheduler/suspend F25 -- cancel sets Fired even when RequeuedFn is present", _TSSuspTest_CancelClearsRequeuedFn)


; Verify that TimerCancel succeeds (no exception) when RequeuedFn is set to 0.
; Handles with RequeuedFn absent or 0 must follow the normal cancel path.
_TSSuspTest_CancelSafeWithRequeuedFnZero() {
	_TS_ResetRegistrySuspend()
	H := TimerAfter(10, () => 0)
	H["RequeuedFn"] := 0
	TimerCancel(H)
	AssertTrue(H["Fired"], "cancel must succeed when RequeuedFn is 0")
}
Test("TimerScheduler/suspend F25 -- cancel is safe when RequeuedFn is 0", _TSSuspTest_CancelSafeWithRequeuedFnZero)


; Idempotent cancel with RequeuedFn: calling cancel twice must not throw.
_TSSuspTest_CancelIdempotentWithRequeuedFn() {
	_TS_ResetRegistrySuspend()
	H := TimerAfter(10, () => 0)
	Sentinel := () => 0
	H["RequeuedFn"] := Sentinel
	TimerCancel(H)
	TimerCancel(H)  ; second call must not throw
	AssertTrue(H["Fired"], "handle must remain Fired after double cancel")
	_TSSuspTest_NativeRequeueCancellation("twice")
}
Test("TimerScheduler/suspend F25 -- cancel is idempotent when RequeuedFn is set", _TSSuspTest_CancelIdempotentWithRequeuedFn)




; ===========================================================================
; ===========================================================================
; ======= 2/ RequeuedFn cleared when the timer actually fires ===============
; ===========================================================================
; ===========================================================================

; When the one-shot fires normally (not suspended), it must clear RequeuedFn
; from the handle so a stale reference is never left dangling.
_TSSuspTest_RequeuedFnClearedOnNormalFire() {
	_TS_ResetRegistrySuspend()
	Fired := false
	H := TimerAfter(10, () => (Fired := true))
	; Pre-populate RequeuedFn as if a prior suspend cycle set it, but the
	; re-queue itself was never armed (simulates partial lifecycle).
	H["RequeuedFn"] := () => 0
	; Simulate normal OS fire -- _OneShot runs without A_IsSuspended.
	_TSTest_DeliverOneShot(H)
	AssertTrue(Fired, "callback must have fired on normal invocation")
	AssertTrue(H["Fired"], "handle.Fired must be true after normal fire")
	; RequeuedFn must have been removed by the firing path.
	AssertFalse(H.Has("RequeuedFn"), "RequeuedFn must be cleared when timer fires normally")
}
Test("TimerScheduler/suspend F25 -- RequeuedFn is removed when the one-shot fires normally", _TSSuspTest_RequeuedFnClearedOnNormalFire)


; TimerCancelAll must also reach RequeuedFn on every handle in the registry.
_TSSuspTest_CancelAllDrainsRequeuedFn() {
	_TS_ResetRegistrySuspend()
	H1 := TimerAfter(10, () => 0)
	H2 := TimerAfter(20, () => 0)
	H1["RequeuedFn"] := () => 0
	H2["RequeuedFn"] := () => 0
	TimerCancelAll()
	AssertTrue(H1["Fired"], "H1 must be Fired after cancelAll with RequeuedFn")
	AssertTrue(H2["Fired"], "H2 must be Fired after cancelAll with RequeuedFn")
	AssertEqual(0, TimerActiveCount(), "registry must be empty after cancelAll")
	_TSSuspTest_NativeRequeueCancellation("all")
}
Test("TimerScheduler/suspend F25 -- cancelAll cancels handles that carry RequeuedFn", _TSSuspTest_CancelAllDrainsRequeuedFn)




; =====================================================================
; =====================================================================
; ======= 3/ Source-structure guard (static assertions) ===============
; =====================================================================
; =====================================================================

; Verify that the fix is present in the adapter source by reading the file
; and asserting the key identifiers exist. This is a canary that fails if
; someone removes the RequeuedFn tracking without updating the tests.
; The read used to be wrapped in a try that turned an unreadable source into
; AssertTrue(true) — so a renamed or moved adapter did not fail this canary, it
; silenced it. A structural guard that cannot find the structure has to say so.
; _DriverDirConcat throws when the directory holds no .ahk file, which is both
; the read and the proof that the read found something.
_TSSuspTest_SourceContainsRequeuedFnWrite() {
	src := _DriverDirConcat("adapters")
	; The suspend branch must store the closure in BoundHandle["RequeuedFn"].
	AssertTrue(InStr(src, "RequeuedFn") > 0,
		"adapter source must contain RequeuedFn tracking (F25 fix absent)")
	; TimerCancel must read RequeuedFn and pass it to SetTimer.
	AssertTrue(InStr(src, 'Handle.Has("RequeuedFn")') > 0,
		"TimerCancel must check Handle.Has(RequeuedFn) (F25 cancel path absent)")
}
Test("TimerScheduler/suspend F25 -- adapter source contains RequeuedFn fix (structural guard)", _TSSuspTest_SourceContainsRequeuedFnWrite)
