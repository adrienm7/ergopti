; tests/unit/test_keylogger_wts_registration.ahk

; ==============================================================================
; MODULE: Keylogger WTS Registration Transaction Tests
; DESCRIPTION:
; Drives the production WTS subscription helper through typed refusal,
; exception, retry, and recovery outcomes without touching the Windows API.
;
; ROOT CAUSE ENCODED:
; WTSRegisterSessionNotification returns a BOOL. Publishing ``wts_registered``
; without consuming that verdict permanently suppresses retries and silently
; loses every later lock/unlock event.
; ==============================================================================

#Requires AutoHotkey v2.0+





; =====================================
; =====================================
; ======= 1/ Deterministic port =======
; =====================================
; =====================================

_KLWTS_Reset() {
	KLWatch.wts_registered := false
	KLWatch.wts_failure_reported := false
	KLWatch.wts_retry_timer := false
}

_KLWTS_Register(State, _Hwnd, _Scope) {
	State["register_calls"] += 1
	if State.Get("throw", false)
		throw Error("injected WTS registration failure")
	return State["result"]
}

_KLWTS_Schedule(State, RetryFn, DelayMs) {
	State["schedule_calls"] += 1
	State["retry_fn"] := RetryFn
	State["delay_ms"] := DelayMs
	return State.Get("schedule_result", 1)
}

_KLWTS_State(Result := 0) {
	return Map("result", Result, "register_calls", 0, "schedule_calls", 0,
		"schedule_result", 1)
}

_KLWTS_Unregister(State, Hwnd) {
	State["unregister_calls"] += 1
	if State.Get("throw", false)
		throw Error("injected WTS unregistration failure")
	return State["result"]
}

_KLWTS_UnregisterState(Result := 0) {
	return Map("result", Result, "unregister_calls", 0)
}





; ======================================
; ======================================
; ======= 2/ Verdict publication =======
; ======================================
; ======================================

_KLWTS_RefusalNeverPublishesFalseAuthority() {
	for Refusal in [0, "0", "1", ""] {
		_KLWTS_Reset()
		State := _KLWTS_State(Refusal)
		Result := _KL_Watchers_TryRegisterWts(
			_KLWTS_Register.Bind(State), _KLWTS_Schedule.Bind(State))
		AssertEqual(false, Result,
			"only a typed nonzero BOOL may authorize WTS publication")
		AssertEqual(false, KLWatch.wts_registered,
			"refusal must leave session notifications unpublished")
		AssertEqual(1, State["register_calls"])
		AssertEqual(1, State["schedule_calls"],
			"every refusal must retain one recovery attempt")
		AssertEqual(-KLWatchConst.WTS_REGISTER_RETRY_MS, State["delay_ms"])
		AssertTrue(IsObject(KLWatch.wts_retry_timer),
			"the exact retry callback must remain owned until fire or Stop")
	}
}
Test("keylogger WTS: false and string verdicts cannot publish registration "
	. "(keylogger-wts-false-success-latch)",
	_KLWTS_RefusalNeverPublishesFalseAuthority)

_KLWTS_TypedSuccessPublishesWithoutRetry() {
	_KLWTS_Reset()
	State := _KLWTS_State(1)
	AssertEqual(true, _KL_Watchers_TryRegisterWts(
		_KLWTS_Register.Bind(State), _KLWTS_Schedule.Bind(State)))
	AssertEqual(true, KLWatch.wts_registered)
	AssertEqual(0, State["schedule_calls"],
		"successful registration must not leave a redundant retry")
}
Test("keylogger WTS: typed success is the only published authority "
	. "(keylogger-wts-false-success-latch)",
	_KLWTS_TypedSuccessPublishesWithoutRetry)





; =====================================
; =====================================
; ======= 3/ Retry lifecycle ===========
; =====================================
; =====================================

_KLWTS_ExceptionRetainsRecovery() {
	_KLWTS_Reset()
	State := _KLWTS_State()
	State["throw"] := true
	AssertEqual(false, _KL_Watchers_TryRegisterWts(
		_KLWTS_Register.Bind(State), _KLWTS_Schedule.Bind(State)))
	AssertEqual(false, KLWatch.wts_registered)
	AssertEqual(1, State["schedule_calls"],
		"an API exception must not destroy the only future registration attempt")
}
Test("keylogger WTS: API exception retains one owned retry "
	. "(keylogger-wts-false-success-latch)", _KLWTS_ExceptionRetainsRecovery)

_KLWTS_RetryCanRecoverAndReleasesHandle() {
	_KLWTS_Reset()
	State := _KLWTS_State(0)
	AssertEqual(false, _KL_Watchers_TryRegisterWts(
		_KLWTS_Register.Bind(State), _KLWTS_Schedule.Bind(State)))
	State["result"] := 1
	State["retry_fn"].Call()
	AssertEqual(true, KLWatch.wts_registered,
		"a later typed success must restore lock/unlock observation")
	AssertEqual(2, State["register_calls"])
	AssertEqual(1, State["schedule_calls"],
		"successful recovery must not re-arm itself")
	AssertEqual(false, IsObject(KLWatch.wts_retry_timer),
		"the fired one-shot must release its lifecycle handle")
}
Test("keylogger WTS: refused registration recovers on its owned retry "
	. "(keylogger-wts-false-success-latch)",
	_KLWTS_RetryCanRecoverAndReleasesHandle)

_KLWTS_SchedulerRefusalDoesNotPublishPhantomHandle() {
	_KLWTS_Reset()
	State := _KLWTS_State(0)
	State["schedule_result"] := 0
	AssertEqual(false, _KL_Watchers_TryRegisterWts(
		_KLWTS_Register.Bind(State), _KLWTS_Schedule.Bind(State)))
	AssertEqual(false, IsObject(KLWatch.wts_retry_timer),
		"a refused timer arm must not latch a nonexistent recovery callback")
}
Test("keylogger WTS: timer refusal cannot latch phantom recovery "
	. "(keylogger-wts-false-success-latch)",
	_KLWTS_SchedulerRefusalDoesNotPublishPhantomHandle)





; ===========================================
; ===========================================
; ======= 4/ Unregistration ownership =======
; ===========================================
; ===========================================

_KLWTS_UnregisterFailureRetainsAuthority() {
	for Refusal in [0, "0", "1", ""] {
		_KLWTS_Reset()
		KLWatch.wts_registered := true
		State := _KLWTS_UnregisterState(Refusal)
		AssertEqual(false, _KL_Watchers_TryUnregisterWts(
			_KLWTS_Unregister.Bind(State)),
			"only a typed nonzero BOOL may release WTS ownership")
		AssertEqual(true, KLWatch.wts_registered,
			"a refused unregistration must retain the exact live authority")
		AssertEqual(1, State["unregister_calls"])
	}

	_KLWTS_Reset()
	KLWatch.wts_registered := true
	State := _KLWTS_UnregisterState()
	State["throw"] := true
	AssertEqual(false, _KL_Watchers_TryUnregisterWts(
		_KLWTS_Unregister.Bind(State)))
	AssertEqual(true, KLWatch.wts_registered,
		"an API exception must retain WTS ownership for a later cleanup retry")
}
Test("keylogger WTS: failed unregistration retains exact ownership "
	. "(keylogger-wts-unregister-owner)",
	_KLWTS_UnregisterFailureRetainsAuthority)

_KLWTS_UnregisterTypedSuccessReleasesAuthority() {
	_KLWTS_Reset()
	KLWatch.wts_registered := true
	State := _KLWTS_UnregisterState(1)
	AssertEqual(true, _KL_Watchers_TryUnregisterWts(
		_KLWTS_Unregister.Bind(State)))
	AssertEqual(false, KLWatch.wts_registered,
		"typed success must be the only authority release boundary")
	AssertEqual(1, State["unregister_calls"])
}
Test("keylogger WTS: typed unregistration success releases ownership "
	. "(keylogger-wts-unregister-owner)",
	_KLWTS_UnregisterTypedSuccessReleasesAuthority)
