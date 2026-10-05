; tests/unit/test_local_server_models_timer.ahk

; ===============================================================================
; MODULE: Local Models Native Timer Contract Tests
; DESCRIPTION:
; Exercises the actual native timer producer without HTTP or injected timers.
; A models retry owns a negative one-shot or an exact cancellation; positive
; intervals are refused rather than becoming a repeating message-thread poller.
; ===============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ Native Timer Contract =======
; ========================================
; ========================================

_LSMT_RequireTypedRefusal(Owner, Callback, Period) {
	Failure := 0
	try Owner._NativeTimer(Callback, Period)
	catch as Err
		Failure := Err
	AssertTrue(Failure is TypeError, "invalid intervals must refuse with the native period contract error")
}

_LSMT_PositiveIntervalRefused() {
	Fixture := _LSM_Fixture()
	State := { Calls: 0 }
	Callback := () => State.Calls += 1
	try {
		_LSMT_RequireTypedRefusal(Fixture.Owner, Callback, 1)
		_LSMT_RequireTypedRefusal(Fixture.Owner, Callback, "-1")
		AssertEqual(0, State.Calls)
	} finally {
		try Fixture.Owner._NativeTimer(Callback, 0)
		finally Fixture.Dispose()
	}
}
Test("Local models native timer: positive and untyped intervals refuse", _LSMT_PositiveIntervalRefused)

_LSMT_CheckOneShot(Owner, TimeoutMs) {
	State := { Calls: 0 }
	Callback := () => State.Calls += 1
	Period := TimingsGet("llm", "poll_interval_ms")
	try {
		AssertTrue(Owner._NativeTimer(Callback, -Period))
		StartedAt := A_TickCount
		while State.Calls == 0 && !TickExpired(StartedAt, TimeoutMs)
			Sleep(Period)
		AssertEqual(1, State.Calls, "the accepted native one-shot must really run")
		Sleep(Period * 2)
		AssertEqual(1, State.Calls, "an expired retry must not repeat without exact owner rearming")
		AssertTrue(Owner._NativeTimer(Callback, -Period))
		AssertTrue(Owner._NativeTimer(Callback, 0))
		Sleep(Period * 2)
		AssertEqual(1, State.Calls, "exact cancellation must disarm the retained native callback")
		return State.Calls
	} finally Owner._NativeTimer(Callback, 0)
}

_LSMT_OneShotAndExactCancellation() {
	Fixture := _LSM_Fixture()
	try _LSMT_CheckOneShot(Fixture.Owner, Fixture.Owner.Options["timeout_ms"])
	finally Fixture.Dispose()
}
Test("Local models native timer: actual one-shot expires and exact cancellation disarms", _LSMT_OneShotAndExactCancellation)
