; tests/unit/infra/dispatch/test_timer_scheduler_retirement_after.ahk

; ==============================================================================
; MODULE: Timer Scheduler Retirement Continuation Controls
; DESCRIPTION:
; AFTER-only retained-callback models preserve restart and successor authority.
; Public timers use real native admission/cancellation; retained calls are logical
; deliveries, not a claim that Windows delivered a cancelled timer message.
; ==============================================================================

#Requires AutoHotkey v2.0+

_TSRA_Log(State, Line) {
	if InStr(Line, "ERROR") {
		State["errors"] += 1
		if !InStr(Line, "expected rearm failure") && !IsObject(State["failure"])
			State["failure"] := Error("Unexpected timer control error: " . Line)
	}
}

_TSRA_Callback(State) {
	State["calls"] += 1
	if State["mode"] == "rearm-throw" && State["calls"] == 1 {
		Handle := State["handle"]
		TimerRestartAfter(Handle, 60)
		State["successor"] := Handle["Fn"]
		State["native"].Push(Handle["Fn"])
		throw Error("expected rearm failure")
	}
}

_TSRA_Exercise(State) {
	global _TIMER_ADAPTER_REGISTRY
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "an earlier exact timer cleanup must finish first")
	Handle := 0, Primary := 0, WasSuspended := A_IsSuspended
	try {
		Handle := TimerAfter(60, _TSRA_Callback.Bind(State))
		State["handle"] := Handle
		OldFn := Handle["Fn"]
		State["native"].Push(OldFn)
		switch State["mode"] {
			case "old-primary":
				AssertTrue(TimerCancel(Handle))
				TimerRestartAfter(Handle, 60)
				Successor := Handle["Fn"]
				State["native"].Push(Successor)
				OldFn.Call()
				AssertEqual(0, State["calls"], "a retired primary cannot consume a fresh restart")
				AssertTrue(Handle["Fn"] == Successor && !Handle["Fired"])
			case "rearm-throw":
				OldFn.Call()
				Successor := State["successor"]
				AssertEqual(1, State["calls"])
				AssertEqual(1, State["errors"], "the old throw must retain its real error report")
				AssertTrue(Handle["Fn"] == Successor && !Handle["Fired"],
					"the old callback/error finalizer cannot erase its reentrant successor")
			case "old-requeue":
				PreviousCritical := Critical("On")
				try {
					Suspend(true)
					OldFn.Call()
					OldRequeue := Handle["RequeuedFn"]
					State["native"].Push(OldRequeue)
					Suspend(false)
					TimerRestartAfter(Handle, 60)
				} finally {
					Suspend(WasSuspended)
					Critical(PreviousCritical)
				}
				Successor := Handle["Fn"]
				AssertTrue(Successor == OldFn, "an ACTIVE restart keeps its primary identity")
				OldRequeue.Call()
				AssertEqual(0, State["calls"], "retained old requeue authority cannot migrate to the restarted primary")
				AssertFalse(Handle.Has("RequeuedFn"))
				AssertTrue(Handle["Fn"] == Successor && !Handle["Fired"])
		}
		AssertTrue(_TIMER_ADAPTER_REGISTRY.Has(Handle["Id"])
			&& _TIMER_ADAPTER_REGISTRY[Handle["Id"]] == Handle,
			"the exact successor remains registered before its own delivery")
		Before := State["calls"]
		Successor.Call()
		AssertEqual(Before + 1, State["calls"], "the successor remains functional exactly once")
		AssertTrue(Handle["Fired"] && !_TIMER_ADAPTER_REGISTRY.Has(Handle["Id"]))
		if IsObject(State["failure"])
			throw State["failure"]
	} catch as Failure {
		Primary := Failure
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		CleanupFailure := 0
		try {
			if IsObject(Handle)
				AssertTrue(TimerCancel(Handle), "the exact real timer must acknowledge native cancellation")
		} catch as Failure
			CleanupFailure := Failure
		; A logical .Call() does not consume the armed native timer. Retain each
		; exact admitted callback separately and cancel it even after SUT Fn:=0.
		for NativeCallback in State["native"] {
			try _TimerAdapterCancelNative(NativeCallback)
			catch as Failure {
				if !IsObject(CleanupFailure)
					CleanupFailure := Failure
			}
		}
		if IsObject(CleanupFailure) {
			RetirementDebt := {Handle: Handle, Callbacks: State["native"], State: State}
			if !IsObject(Primary)
				Primary := CleanupFailure
			else
				Primary.Message .= " Cleanup also failed: " . CleanupFailure.Message
		} else {
			; Break only fixture edges after ALL actual native cancellations ACK.
			State["handle"] := 0, State["successor"] := 0
			State["native"] := []
		}
	}
	if IsObject(Primary)
		throw Primary
}

_TSRA_ArmPort(State, Callback, Period) {
	AssertTrue(Callback == State["callback"], "rollback must address the exact admitted callback")
	State["periods"].Push(Period)
	if Period != 0 {
		; Fault injection follows a real native admission of this exact wrapper.
		_TimerAdapterSetNative(Callback, Period)
		throw State["first"]
	}
	if State["refuse"]
		throw Error("logical rollback refusal")
	_TimerAdapterCancelNative(Callback)
}

_TSRA_CancelPort(State, Callback) {
	_TSRA_ArmPort(State, Callback, 0)
}

_TSRA_Rollback(State) {
	global _TIMER_ADAPTER_REGISTRY
	for Kind in ["after", "every"] {
		for Refuse in [false, true] {
			Port := Map("periods", [], "first", Error("logical admission refusal"), "refuse", Refuse)
			Handle := Kind == "after" ? TimerAfter(60, _TSRA_Callback.Bind(State)) : TimerEvery(60, _TSRA_Callback.Bind(State))
			Callback := Handle["Fn"]
			Port["callback"] := Callback
			BeforeCalls := State["calls"], Failure := 0
			try {
				try _TimerAdapterCommitNative(Handle, Callback, Handle["Interval"], _TSRA_ArmPort.Bind(Port))
				catch as Caught
					Failure := Caught
				AssertTrue(Failure == Port["first"], "rollback must preserve the exact original failure")
				AssertEqual(2, Port["periods"].Length)
				AssertEqual(Handle["Interval"], Port["periods"][1])
				AssertEqual(0, Port["periods"][2], "throwing admission still needs an exact cancellation attempt")
				; Consume the real native timer before modeling its retained delivery.
				; This is not an acknowledgment from the fault-injected rollback port.
				_TimerAdapterCancelNative(Callback)
				Callback.Call()
				AssertEqual(BeforeCalls, State["calls"],
					"failed admission cannot authorize user work while rollback acknowledgment is unknown")
				if Refuse {
					AssertTrue(_TIMER_ADAPTER_REGISTRY[Handle["Id"]] == Handle)
					AssertTrue(Handle["Fn"] == Callback && Handle["Fired"],
						"rejected work stays inactive while its exact cancellation capability remains reachable")
					Port["refuse"] := false
					AssertTrue(TimerCancel(Handle, _TSRA_CancelPort.Bind(Port)),
						"the same logical capability can be retired by an acknowledged retry")
				} else {
					AssertFalse(_TIMER_ADAPTER_REGISTRY.Has(Handle["Id"]))
					AssertTrue(Handle["Fired"] && Handle["Fn"] == 0)
				}
			} finally {
				Port["refuse"] := false
				AssertTrue(TimerCancel(Handle, _TSRA_CancelPort.Bind(Port)))
			}
		}
	}
}

_TSRA_Case(Mode) {
	global _TIMER_ADAPTER_REGISTRY
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	State := Map("mode", Mode, "calls", 0, "errors", 0, "failure", 0, "handle", 0, "successor", 0, "native", [])
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	try {
		AssertFalse(A_IsSuspended, "timer continuation controls require an unsuspended process")
		AssertEqual(0, _TIMER_ADAPTER_REGISTRY.Count,
			"the fixture must not cancel or park foreign native timers")
		AssertFalse(SavedLogger.FlushActive,
			"a foreign logger flush cannot be detached by a timer continuation control")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := _TSRA_Log.Bind(State), _LOGGER_REPEAT_ENABLED := false
		_LOGGER_ERROR_ENABLED := true
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		Critical("Off")
		if Mode == "rollback"
			_TSRA_Rollback(State)
		else
			_TSRA_Exercise(State)
	} finally {
		Critical("On")
		try {
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Value in SavedExtra
				%Name% := Value
			for Name, Saved in SavedOptional
				%Name% := Saved.Present ? Saved.Value : unset
		} finally Critical(PreviousCritical)
	}
}


Test("Timer retirement AFTER: retired primary cannot consume a fresh restart (timer-scheduler-retirement-after)",
	_TSRA_Case.Bind("old-primary"))
Test("Timer retirement AFTER: old throw preserves a reentrant successor (timer-scheduler-retirement-after)",
	_TSRA_Case.Bind("rearm-throw"))
Test("Timer retirement AFTER: retired suspended reply cannot consume an active restart (timer-scheduler-retirement-after)",
	_TSRA_Case.Bind("old-requeue"))
Test("Timer retirement AFTER: admission errors require an exact rollback acknowledgment (timer-scheduler-retirement-after)",
	_TSRA_Case.Bind("rollback"))
