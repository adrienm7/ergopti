; tests/unit/llm_nav_event_owner/test_stop_diagnostics.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Stop Diagnostics
; DESCRIPTION:
; Observes real logger output while the injected native port retains or retires
; profile ownership. No keyboard hook is installed.
; ==============================================================================

#Requires AutoHotkey v2.0

_LNEO_StopDiagnosticNativeError(*) {
	_LLM_NavEventOwnerNativeRequireOk(3, "private-stop-diagnostic-sentinel")
}

_LNEO_StopDiagnosticCount(Lines, Level, Detail) {
	Count := 0
	for Line in Lines {
		AssertFalse(InStr(Line, "private-stop-diagnostic-sentinel"),
			"native operation text must not escape through stop diagnostics")
		AssertFalse(InStr(Line, "injected navigation-owner stop failure"),
			"arbitrary exception messages must not escape through stop diagnostics")
		if InStr(Line, "[" . Level . "] [LLM.nav]") && InStr(Line, Detail)
			Count += 1
	}
	return Count
}

_LNEO_StopDiagnosticsRetainOwnershipAndThrottle() {
	global _LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED, _LOGGER_DEBUG_ENABLED
	global _LLM_NavEventOwnerReportTimes, _LLM_NavEventOwnerProfileOwners
	global _LLM_NavEventOwnerActiveProfileToken
	SavedSink := _LOGGER_TEST_SINK
	SavedError := _LOGGER_ERROR_ENABLED
	SavedDebug := _LOGGER_DEBUG_ENABLED
	SavedReports := _LLM_NavEventOwnerReportTimes
	try {
		_LOGGER_ERROR_ENABLED := true
		_LOGGER_DEBUG_ENABLED := true
		for Mode in ["refuse", "throw", "native_error", "pending"] {
			State := _LNEO_Setup()
			try {
				Swap := LLM_NavEventOwner_BeginProfileSwap(
					_LNEO_ProfilePlan(), ["a", "b"], 1, ["a", "b"], State.Port)
				AssertTrue(Swap is Map && LLM_NavEventOwner_CommitProfileSwap(Swap))
				Token := _LLM_NavEventOwnerActiveProfileToken
				_LLM_NavEventOwnerReportTimes := Map()
				Captured := []
				LoggerSetTestSink((Line) => Captured.Push(Line))
				State.StopMode := Mode
				if Mode == "native_error"
					State.Port["stop"] := _LNEO_StopDiagnosticNativeError
				AssertFalse(LLM_NavEventOwner_Stop(), Mode . ": stop is not acknowledged")
				AssertTrue(_LLM_NavEventOwnerProfileOwners.Has(Token),
					Mode . ": diagnostics must not retire an unacknowledged owner")
				ExpectedErrors := Mode == "pending" ? 0 : 1
				AssertEqual(ExpectedErrors,
					_LNEO_StopDiagnosticCount(Captured, "ERROR", "stage=native_stop"),
					Mode . ": the first actual failure must be observable")
				if Mode == "refuse"
					AssertEqual(1, _LNEO_StopDiagnosticCount(Captured, "ERROR",
						"outcome=refused result_type=Integer result_code=0"))
				else if Mode != "pending"
					AssertEqual(1, _LNEO_StopDiagnosticCount(Captured, "ERROR",
						"outcome=exception error_type=Error"))
				if Mode == "native_error"
					AssertEqual(1, _LNEO_StopDiagnosticCount(Captured, "ERROR",
						"native_status=3 native_error=0"), "native codes must survive the catch")
				if Mode == "pending"
					AssertEqual(1, _LNEO_StopDiagnosticCount(Captured, "DEBUG",
						"outcome=pending"), "pending is a progress transition, not an error")
				; Break logger dedup so only the owner's throttle can suppress this retry.
				LoggerDebug("StopDiagnosticTest", "Between repeated stop attempts.")
				AssertFalse(LLM_NavEventOwner_Stop())
				AssertEqual(ExpectedErrors,
					_LNEO_StopDiagnosticCount(Captured, "ERROR", "stage=native_stop"),
					Mode . ": repeated failure must not flood the logger")
				if Mode == "pending"
					AssertEqual(1, _LNEO_StopDiagnosticCount(Captured, "DEBUG", "outcome=pending"))
				State.Port["stop"] := _LNEO_PortStop.Bind(State)
				State.StopMode := "accept"
				AssertTrue(LLM_NavEventOwner_Stop())
				AssertEqual(0, _LLM_NavEventOwnerProfileOwners.Count)
				AssertEqual(1, _LNEO_StopDiagnosticCount(Captured, "DEBUG", "outcome=stopped"),
					"recovery must report the acknowledged terminal state")
			} finally {
				State.Port["stop"] := _LNEO_PortStop.Bind(State)
				State.StopMode := "accept"
				_LNEO_Teardown()
				LoggerSetTestSink(SavedSink)
			}
		}
	} finally {
		LoggerSetTestSink(SavedSink)
		_LOGGER_ERROR_ENABLED := SavedError
		_LOGGER_DEBUG_ENABLED := SavedDebug
		_LLM_NavEventOwnerReportTimes := SavedReports
	}
}
Test("LLM nav event owner: stop diagnostics retain ownership and throttle retries (native-stop-diagnostics)",
	_LNEO_StopDiagnosticsRetainOwnershipAndThrottle)

; Actual DllCall boundary callbacks are local controls; no native hook is installed.
_LNEO_StartErrorNativeStart(State, Hwnd, WakeMessage) {
	State.Events.Push("start")
	return State.Status
}

_LNEO_StartErrorNativeStop(State) {
	State.Events.Push("stop")
	State.ErrorCode := 0
	return 0
}

_LNEO_StartErrorNativeCode(State) {
	State.Events.Push("error")
	return State.ErrorCode
}

_LNEO_StartErrorBeforeCleanupCase(Status, MissingStop) {
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerExports
	SavedModule := _LLM_NavEventOwnerModule
	SavedExports := _LLM_NavEventOwnerExports
	Pointers := []
	State := {Status: Status, ErrorCode: 1234, Events: []}
	try {
		Exports := Map()
		for Description in [
			["ErgoptiNav_Start", _LNEO_StartErrorNativeStart.Bind(State), 2],
			["ErgoptiNav_Stop", _LNEO_StartErrorNativeStop.Bind(State), 0],
			["ErgoptiNav_GetLastOsError", _LNEO_StartErrorNativeCode.Bind(State), 0]
		] {
			Pointer := CallbackCreate(Description[2], "", Description[3])
			Pointers.Push(Pointer)
			if !MissingStop || Description[1] != "ErgoptiNav_Stop"
				Exports[Description[1]] := Pointer
		}
		; A controlled table exercises the real adapter; this sentinel never loads a DLL.
		_LLM_NavEventOwnerModule := 1
		_LLM_NavEventOwnerExports := Exports
		Failure := 0
		try _LLM_NavEventOwnerNativeStart(A_ScriptHwnd, 0x8001)
		catch as CapturedFailure
			Failure := CapturedFailure
		AssertTrue(Failure is Error, "the real native adapter must refuse the failed start")
		AssertTrue(Failure.HasOwnProp("NativeStatus"), "the primary native status must survive cleanup")
		AssertEqual(Status, Failure.NativeStatus)
		AssertEqual(Status == 6 ? 1234 : 0, Failure.NativeErrorCode)
		AssertEqual("start", State.Events[1])
		if Status == 6 {
			AssertEqual("error", State.Events[2], "the original OS error must be captured before cleanup")
			AssertContains(Failure.Message, "Win32 1234")
		}
		if MissingStop {
			AssertTrue(Failure.HasOwnProp("NativeCleanupError"))
			AssertTrue(Failure.NativeCleanupError is Error)
			AssertContains(Failure.Message, "native stop cleanup failed")
			AssertEqual(2, State.Events.Length)
			AssertEqual(1234, State.ErrorCode)
		} else {
			AssertEqual(Status == 6 ? 3 : 2, State.Events.Length)
			AssertEqual("stop", State.Events[State.Events.Length])
			AssertEqual(0, State.ErrorCode, "the control cleanup must actually erase the original code")
		}
	} finally {
		_LLM_NavEventOwnerModule := SavedModule
		_LLM_NavEventOwnerExports := SavedExports
		for Pointer in Pointers
			CallbackFree(Pointer)
	}
}
Test("native-start-error-custody: OS error survives actual adapter cleanup",
	_LNEO_StartErrorBeforeCleanupCase.Bind(6, false))
Test("native-start-error-custody: non-OS refusal still runs cleanup without an OS read",
	_LNEO_StartErrorBeforeCleanupCase.Bind(5, false))
Test("native-start-error-custody: cleanup lookup failure retains both errors",
	_LNEO_StartErrorBeforeCleanupCase.Bind(6, true))
