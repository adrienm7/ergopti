; tests/unit/test_local_server_queue_timer.ahk

; ==============================================================================
; MODULE: Local Server Native Queue Timer Tests
; DESCRIPTION:
; Exercises the actual logical owner's native one-shot producer. The shared
; native timer observation helpers load from test_local_server_models_timer.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Native Queue Timers =======
; ======================================
; ======================================

_LSOQT_InvalidIntervals() {
	Fixture := _LSO_Fixture()
	State := { Calls: 0 }
	Callback := () => State.Calls += 1
	try {
		_LSMT_RequireTypedRefusal(Fixture.Native, Callback, 1)
		_LSMT_RequireTypedRefusal(Fixture.Native, Callback, "-1")
		AssertEqual(0, State.Calls)
	} finally {
		try Fixture.Native._NativeTimer(Callback, 0)
		finally Fixture.Dispose()
	}
}
Test("local server native queue: positive and untyped intervals refuse", _LSOQT_InvalidIntervals)

_LSOQT_OneShotCancellation() {
	Fixture := _LSO_Fixture()
	try AssertEqual(1, _LSMT_CheckOneShot(Fixture.Native, Fixture.Owner.Options["timeout_ms"]),
		"the shared native observer must return its one delivered callback")
	finally Fixture.Dispose()
}
Test("local server native queue: actual one-shot expires and exact cancellation disarms", _LSOQT_OneShotCancellation)
