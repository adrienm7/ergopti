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
/** Admit exactly the original three ordered child results and finite timings. */
_LNEO_StartCustodyReceiptValid(Tap) {
	Lines := StrSplit(StrReplace(Tap, "`r`n", "`n"), "`n")
	if InStr(StrReplace(Tap, "`r`n", ""), "`r") || Lines.Length == 0 || Lines[Lines.Length] != ""
		return false
	Lines.Pop()
	Position := 1
	Boots := Map()
	; Boot records are optional runtime frames; the exact mandatory census follows.
	while Position <= Lines.Length {
		if !RegExMatch(Lines[Position], "^# \[boot\] .+$")
			break
		if Boots.Has(Lines[Position])
			return false
		Boots[Lines[Position]] := true
		Position += 1
	}
	; Plan, selection, three RUNNING/result/timing triples, and final summary.
	if Lines.Length - Position + 1 != 12 || Lines[Position] !== "1..3"
		return false
	Position += 1
	if !RegExMatch(Lines[Position], "^# --only native-start-error-custody: - 3 of [1-9][0-9]* test\(s\) selected\.$")
		return false
	Position += 1
	Names := [
		"OS error survives actual adapter cleanup",
		"non-OS refusal still runs cleanup without an OS read",
		"cleanup lookup failure retains both errors"
	]
	for Index, Name in Names {
		Expected := "native-start-error-custody: " . Name
		if Lines[Position] !== "RUNNING " . Index . "/3 - " . Expected
			|| Lines[Position + 1] !== "ok " . Index . " - " . Expected
			|| !RegExMatch(Lines[Position + 2], "^# duration_ms " . Index . " [0-9]+(?:\.[0-9]+)?$")
			return false
		Position += 3
	}
	return Lines[Position] == "# 3 passed, 0 failed."
}

/** Receive the original controlled callbacks in a fresh native issuance realm. */
_LNEO_ReceiveStartErrorCase(Status, MissingStop) {
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerExports
	static Received := false
	; A real DLL issuance cannot be replaced by a callback table later in the
	; same process. Keep that production fence and isolate the original cases.
	if EnvGet("ERGOPTI_START_CUSTODY_CHILD") == A_ScriptFullPath
		&& InStr(A_ScriptName, ".ergopti_start_custody_child_") == 1
		return _LNEO_StartErrorBeforeCleanupCase(Status, MissingStop)
	if Received
		return
	ParentModule := _LLM_NavEventOwnerModule
	ParentExports := _LLM_NavEventOwnerExports
	TestsRoot := A_ScriptDir
	CanonicalPath := TestsRoot . "\run_all.ahk"
	Canonical := FileRead(CanonicalPath, "UTF-8")
	Id := DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount . "_" . Random(1, 0x7FFFFFFF)
	ChildName := ".ergopti_start_custody_child_" . Id . ".ahk"
	ChildPath := TestsRoot . "\" . ChildName
	ReceiptRoot := A_Temp . "\ergopti_start_custody_" . Id
	DirCreate(ReceiptRoot)
	TapPath := ReceiptRoot . "\child.tap"
	OutPath := ReceiptRoot . "\child.stdout.log"
	ErrPath := ReceiptRoot . "\child.stderr.log"
	SavedChild := EnvGet("ERGOPTI_START_CUSTODY_CHILD")
	SavedReceipt := EnvGet("ERGOPTI_AHK_RESULTS_FILE")
	AssertFalse(FileExist(ChildPath), "never replace an existing runner")
	try {
		; Preserve the entire canonical include graph, argument parser and watchdog.
		FileAppend(Canonical, ChildPath, "UTF-8")
		EnvSet("ERGOPTI_START_CUSTODY_CHILD", ChildPath)
		EnvSet("ERGOPTI_AHK_RESULTS_FILE", TapPath)
		Quote := Chr(34)
		ChildCommand := Quote . A_AhkPath . Quote . " /ErrorStdOut=UTF-8 " . Quote . ChildPath . Quote
			. " --only=native-start-error-custody: 1>" . Quote . OutPath . Quote
			. " 2>" . Quote . ErrPath . Quote
		Code := RunWait(Quote . A_ComSpec . Quote . " /D /C " . Quote . ChildCommand . Quote, TestsRoot, "Hide")
		AssertEqual(0, Code, "all original custody assertions must pass in the child; captures: " . ReceiptRoot)
		AssertTrue(FileExist(TapPath) && FileExist(OutPath) && FileExist(ErrPath))
		AssertEqual(0, FileGetSize(ErrPath), "child startup/parse diagnostics must refuse receiving")
		Tap := FileRead(TapPath, "UTF-8")
		AssertTrue(_LNEO_StartCustodyReceiptValid(Tap),
			"require exactly three ordered original RUNNING/result/timing pairs and one plan/summary")
		AssertEqual(ParentModule, _LLM_NavEventOwnerModule)
		AssertTrue(ParentExports == _LLM_NavEventOwnerExports)
		AssertEqual(Canonical, FileRead(CanonicalPath, "UTF-8"))
		Received := true
	} finally {
		EnvSet("ERGOPTI_START_CUSTODY_CHILD", SavedChild)
		EnvSet("ERGOPTI_AHK_RESULTS_FILE", SavedReceipt)
		SplitPath(ChildPath, &ActualName, &ActualDirectory)
		if ActualDirectory != TestsRoot || ActualName != ChildName
			throw Error("Refuse custody child cleanup outside its exact owned path.")
		if FileExist(ChildPath)
			FileDelete(ChildPath)
		; Keep complete raw streams and TAP after both success and refusal.
		FileAppend("# native-start-error-custody captures: " . ReceiptRoot . "`n", "*")
	}
}

Test("native-start-error-custody: OS error survives actual adapter cleanup",
	_LNEO_ReceiveStartErrorCase.Bind(6, false))
Test("native-start-error-custody: non-OS refusal still runs cleanup without an OS read",
	_LNEO_ReceiveStartErrorCase.Bind(5, false))
Test("native-start-error-custody: cleanup lookup failure retains both errors",
	_LNEO_ReceiveStartErrorCase.Bind(6, true))


/** Keep foreign, duplicated, reordered and case-only child records observable. */
_LNEO_StartCustodyReceiptControls() {
	ReceiptNames := [
		"OS error survives actual adapter cleanup",
		"non-OS refusal still runs cleanup without an OS read",
		"cleanup lookup failure retains both errors"
	]
	GoodReceipt := "1..3`n# --only native-start-error-custody: - 3 of 3 test(s) selected.`n"
	for ReceiptIndex, ReceiptName in ReceiptNames {
		GoodReceipt .= "RUNNING " . ReceiptIndex . "/3 - native-start-error-custody: " . ReceiptName . "`n"
		GoodReceipt .= "ok " . ReceiptIndex . " - native-start-error-custody: " . ReceiptName . "`n"
		GoodReceipt .= "# duration_ms " . ReceiptIndex . " 0.001`n"
	}
	GoodReceipt .= "# 3 passed, 0 failed.`n"
	AssertTrue(_LNEO_StartCustodyReceiptValid(GoodReceipt))
	AssertTrue(_LNEO_StartCustodyReceiptValid(StrReplace(GoodReceipt, "`n", "`r`n")))
	AssertTrue(_LNEO_StartCustodyReceiptValid("# [boot] controlled startup`n" . GoodReceipt))
	ReceiptLines := StrSplit(GoodReceipt, "`n")
	FirstBlock := ReceiptLines[3] . "`n" . ReceiptLines[4] . "`n" . ReceiptLines[5] . "`n"
	SecondBlock := ReceiptLines[6] . "`n" . ReceiptLines[7] . "`n" . ReceiptLines[8] . "`n"
	AssertTrue(InStr(GoodReceipt, FirstBlock . SecondBlock) > 0)
	BadReceipts := [
		"# [boot] repeated`n# [boot] repeated`n" . GoodReceipt,
		"# [boot]`n" . GoodReceipt,
		StrReplace(GoodReceipt, FirstBlock . SecondBlock, SecondBlock . FirstBlock),
		StrReplace(GoodReceipt, ReceiptLines[4] . "`n", ReceiptLines[4] . "`n" . ReceiptLines[4] . "`n"),
		StrReplace(GoodReceipt, FirstBlock, ""),
		GoodReceipt . "ok 4 - foreign case`n",
		GoodReceipt . "1..3`n",
		GoodReceipt . "# 3 passed, 0 failed.`n",
		GoodReceipt . "RUNNING 4/3 - foreign case`n",
		StrReplace(GoodReceipt, "ok 1 -", "not ok 1 -"),
		StrReplace(GoodReceipt, "RUNNING 1/3", "RUNNING 2/3"),
		StrReplace(GoodReceipt, "ok 1 -", "ok 2 -"),
		StrReplace(GoodReceipt, "RUNNING 1/3", "running 1/3"),
		StrReplace(GoodReceipt, "ok 1 -", "OK 1 -"),
		StrReplace(GoodReceipt, "OS error survives", "os error survives"),
		StrReplace(GoodReceipt, "# duration_ms 1 0.001", "# duration_ms 1 -1"),
		StrReplace(GoodReceipt, "# duration_ms 1 0.001", "# duration_ms 2 0.001"),
		StrReplace(GoodReceipt, "# 3 passed, 0 failed.", "# 2 passed, 0 failed."),
		StrReplace(GoodReceipt, "# 3 passed, 0 failed.", "# SKIP`n# 3 passed, 0 failed."),
		StrReplace(GoodReceipt, "# 3 passed, 0 failed.", "UNASSIGNED_DIAGNOSTIC`n# 3 passed, 0 failed."),
		SubStr(GoodReceipt, 1, StrLen(GoodReceipt) - 1)
	]
	for MalformedReceipt in BadReceipts
		AssertFalse(_LNEO_StartCustodyReceiptValid(MalformedReceipt),
			"a complete transcript cannot admit a foreign, missing or malformed record")
}
Test("native-start-error-receipt: complete child census refuses malformed records",
	_LNEO_StartCustodyReceiptControls)
