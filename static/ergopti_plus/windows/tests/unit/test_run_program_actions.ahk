; tests/unit/test_run_program_actions.ahk

_RPA_StringStages() {
	; Independently authored fixture strings; no user paths/argv enter diagnostics.
	for Vector in [
		Map("source", '"C:\\Program Files\\été\\program.exe",0', "value", "C:\Program Files\été\program.exe"),
		Map("source", '"trail\\",0', "value", "trail\"),
		Map("source", '"\"quote\"",0', "value", '"quote"'),
		Map("source", '"\\u0000",0', "value", "\u0000"),
		Map("source", '"日本語",0', "value", "日本語")
	] {
		Text := Vector["source"], Position := 1
		try Canonical := _JsonParseString(&Text, &Position)
		catch Any {
			Assert(false, "program stage canonical-string raised")
		}
		Assert(Canonical == Vector["value"], "program stage canonical-string bytes")
		Assert(SubStr(Text, Position) == ",0", "program stage canonical-string cursor")
		Position := 1
		try Actual := _ProgramParameterString(Text, &Position)
		catch Any {
			Assert(false, "program stage parameter-string raised")
		}
		Assert((Actual is String) && Actual == Vector["value"], "program stage parameter-string bytes")
		Assert(SubStr(Text, Position) == ",0", "program stage parameter-string cursor")
	}
	Position := 1
	AssertFalse(_ProgramParameterString('"\u0000",0', &Position), "program stage unescaped NUL refusal")
	Scalar := '{"version":1,"executable":"C:\\missing program\\script.exe","arguments":["","trail\\","\"quote\"","\\u0000","日本語"]}'
	Actual := ProgramParameterParse(Scalar)
	Assert(Actual is Map, "program stage descriptor pure fictional path")
	Assert(Actual["executable"] == "C:\missing program\script.exe", "program stage descriptor executable bytes")
	Assert(Actual["arguments"].Length == 5, "program stage descriptor argument count")
	Assert(Actual["arguments"][1] == "", "program stage descriptor empty argument")
	Assert(Actual["arguments"][4] == "\u0000", "program stage descriptor escaped NUL literal")
}
Test("user program: closed canonical string and parameter cursor stages", _RPA_StringStages)

_RPA_ProgramCorpus() {
	global _SharedDir, JSON_NULL
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\action_parameters\program_vectors.json"))
	Count := 0
	for Vector in Corpus["cases"] {
		Windows := false
		for Platform in Vector["platforms"]
			if Platform == "ahk"
				Windows := true
		if !Windows
			continue
		Actual := ProgramParameterParse(Vector["value"])
		Expected := Vector["expected"]
		if Expected == JSON_NULL {
			AssertFalse(Actual, Vector["id"] . ": invalid scalar must refuse")
		} else {
			Assert(Actual is Map, Vector["id"] . ": actual program scalar parses")
			AssertEqual(Expected["executable"], Actual["executable"], Vector["id"] . ": executable bytes")
			AssertEqual(Expected["arguments"].Length, Actual["arguments"].Length, Vector["id"] . ": argument count")
			for Index, Argument in Expected["arguments"]
				AssertEqual(Argument, Actual["arguments"][Index], Vector["id"] . ": literal argument")
		}
		Count += 1
	}
	Assert(Count >= 20, "the independent Windows parameter corpus actually runs")
}
Test("user program: actual JSON typed scalar corpus", _RPA_ProgramCorpus)

_RPA_WithFixture(Body) {
	global ConfigurationFile, GestureAssignments, GestureActionParameters, KeyboardShortcutAssignments
	global _UserProgramEntries, _UserProgramGeneration, _UserProgramPaused, _UserProgramAcquiring
	AssertEqual(0, _UserProgramEntries.Count, "native fixture starts without borrowed program debt")
	AssertFalse(IsObject(_UserProgramAcquiring), "native fixture cannot borrow an acquisition")
	SavedFile := ConfigurationFile
	SavedGestures := GestureAssignments
	SavedKeyboard := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedParameters := GestureActionParameters
	SavedPaused := _UserProgramPaused
	Directory := A_Temp . "\program106_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Directory)
	ConfigurationFile := Directory . "\configuration.toml"
	Script := Directory . "\été 日本 program.ahk"
	Output := Directory . "\literal.receipt"
	FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n"
		. 'for Index, Value in A_Args {`n'
		. ' if Index > 1`n'
		. '  FileAppend(StrLen(Value) . ":" . Value, A_Args[1], "UTF-8-RAW")`n'
		. '}`nExitApp(0)`n', Script, "UTF-8")
	Scalar := '{"version":1,"executable":' . JsonStringLiteral(A_AhkPath)
		. ',"arguments":[' . JsonStringLiteral(Script) . ',' . JsonStringLiteral(Output)
		. ',"","two words","日本語","line\nnext"]}'
	GestureAssignments := Map("tap_3", "run_program")
	KeyboardShortcutAssignments := Map("ctrl_p", "run_program")
	GestureActionParameters := Map("gesture__tap_3__run_program", Scalar, "keyboard__ctrl_p__run_program", Scalar)
	FileAppend('[gestures]`ntap_3 = "run_program"`n[shortcuts.keyboard]`nctrl_p = "run_program"`n'
		. '[action_parameters]`n"gesture__tap_3__run_program" = ' . JsonStringLiteral(Scalar)
		. '`n"keyboard__ctrl_p__run_program" = ' . JsonStringLiteral(Scalar) . '`n', ConfigurationFile, "UTF-8")
	_UserProgramPaused := false
	Context := Map("directory", Directory, "script", Script, "output", Output, "scalar", Scalar)
	try Body.Call(Context)
	finally {
		Deadline := A_TickCount + 5000
		while !ProgramActions_Stop(true) && A_TickCount < Deadline
			Sleep(10)
		AssertEqual(0, _UserProgramEntries.Count, "owned native child is retired before fixture cleanup")
		SetTimer(ProgramActions_Poll, 0)
		ConfigurationFile := SavedFile
		GestureAssignments := SavedGestures
		KeyboardShortcutAssignments := IsSet(SavedKeyboard) ? SavedKeyboard : unset
		GestureActionParameters := SavedParameters
		_UserProgramPaused := SavedPaused
		if !Context.Get("preserve_directory", false)
			DirDelete(Directory, true)
	}
}

_RPA_WaitSettled() {
	global _UserProgramEntries
	Deadline := A_TickCount + 5000
	while _UserProgramEntries.Count != 0 && A_TickCount < Deadline
		Sleep(10)
	AssertEqual(0, _UserProgramEntries.Count, "native tree reports strict terminal settlement")
}

_RPA_NativeGestureAndKeyboard(Context) {
	GestureInvokeAction("run_program", "gesture__tap_3")
	_RPA_WaitSettled()
	AssertEqual("0:9:two words3:日本語9:line`nnext", FSReadUtf8Exact(Context["output"]),
		"real gesture invocation preserves literal empty/Unicode/newline arguments")
	FileDelete(Context["output"])
	GestureInvokeAction("run_program", "keyboard__ctrl_p")
	_RPA_WaitSettled()
	AssertEqual("0:9:two words3:日本語9:line`nnext", FSReadUtf8Exact(Context["output"]),
		"real keyboard invocation shares the executable/argv owner")
}
Test("user program: real native gesture and keyboard argv", _RPA_WithFixture.Bind(_RPA_NativeGestureAndKeyboard))

_RPA_ForeignSource(Context) {
	global ConfigurationFile
	Snapshot := _ProgramActions_Snapshot("gesture__tap_3")
	Assert(Snapshot is Map, "actual admitted source was captured")
	Foreign := '[gestures]`ntap_3 = "none"`n'
	FileDelete(ConfigurationFile)
	FileAppend(Foreign, ConfigurationFile, "UTF-8")
	AssertThrows(_ProgramActions_BeforeAdopt.Bind(Snapshot), "foreign source cannot borrow a held native start")
	AssertFalse(ProgramActions_Run("gesture__tap_3"), "fresh canonical assignment mismatch refuses")
	AssertEqual(Foreign, FSReadUtf8Exact(ConfigurationFile), "program refusal preserves the foreign source")
	AssertFalse(FileExist(Context["output"]), "source refusal never executes the private child")
}
Test("user program: held source and fresh binding refuse foreign replacement", _RPA_WithFixture.Bind(_RPA_ForeignSource))

_RPA_NativeCancellation(Context) {
	global _UserProgramEntries
	FileDelete(Context["script"])
	FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`nSleep(30000)`n", Context["script"], "UTF-8")
	Started := ProgramActions_Run("gesture__tap_3")
	AssertEqual(true, Started, "actual native long-running child starts")
	AssertEqual(1, _UserProgramEntries.Count, "exact native program owner is retained")
	Receipt := ProgramActions_Stop(true)
	if Receipt != true
		AssertFalse(ProgramActions_Run("keyboard__ctrl_p"), "unsettled cancelled tree prevents replacement")
	_RPA_WaitSettled()
	AssertEqual(true, ProgramActions_Stop(true), "physical retirement eventually acknowledges")
	AssertFalse(ProgramActions_Run("gesture__tap_3"), "paused native owner cannot acquire another program")
	AssertFalse(FileExist(Context["output"]), "retired child never publishes the literal-output receipt")
}
Test("user program: actual native cancellation and retained pause", _RPA_WithFixture.Bind(_RPA_NativeCancellation))

_RPA_MissingExecutable(Context) {
	global GestureActionParameters, ConfigurationFile
	Scalar := '{"version":1,"executable":' . JsonStringLiteral(Context["directory"] . "\missing.exe") . ',"arguments":[]}'
	GestureActionParameters := Map("gesture__tap_3__run_program", Scalar)
	FileDelete(ConfigurationFile)
	FileAppend('[gestures]`ntap_3 = "run_program"`n[action_parameters]`n"gesture__tap_3__run_program" = '
		. JsonStringLiteral(Scalar) . '`n', ConfigurationFile, "UTF-8")
	Before := FSReadUtf8Exact(ConfigurationFile)
	AssertFalse(ProgramActions_Run("gesture__tap_3"), "real missing executable refuses actual native launch")
	_RPA_WaitSettled()
	AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile), "launch refusal preserves exact canonical source")
	AssertFalse(FileExist(Context["output"]), "refused executable publishes no private output")
}
Test("user program: actual native launch refusal preserves canonical data", _RPA_WithFixture.Bind(_RPA_MissingExecutable))

_RPA_ShutdownRetirementEnvelope() {
	Body := _StripFullLineComments(_DriverFuncBody("Ergopti_OnShutdown"))
	Assert(Body != "", "the real shutdown owner must be source-visible")
	Reason := InStr(Body, "_LifecycleShutdownReason := reason", true)
	Left := InStr(Body, "GestureReleaseLeftClick()", true)
	Right := InStr(Body, "GestureReleaseRightClick()", true)
	Nav := InStr(Body, "LLM_NavEventOwner_PrepareShutdown()", true)
	Bundle := InStr(Body, "ReloadTerminalHandoffClaim(reason)", true)
	Modifiers := InStr(Body, "TapHoldShutdownReleaseGate()", true)
	Program := InStr(Body, "ProgramActions_Stop(A_IsSuspended)", true)
	FullSave := InStr(Body, "_ConfigFullSaveSettleTerminal(ShutdownOwners)", true)
	Assert(Reason > 0 && Left > Reason && Right > Left && Nav > Right
		&& Bundle > Nav && Modifiers > Bundle && Program > Modifiers && FullSave > Program,
		"program retirement follows held-input release and borrows the reversible shutdown envelope")
	Gate := SubStr(Body, Program, FullSave - Program)
	AssertContains(Gate, "ProgramStopped is Integer",
		"missing or malformed program receipts must retain shutdown debt")
	AssertContains(Gate, "ProgramStopped == 1", "only exact terminal acknowledgement accepts")
	AssertContains(Gate, "_Updater_DeferExitIntentRetry()", "program debt schedules the updater exit retry")
	AssertContains(Gate, "_Updater_DeferRecoveryHandoffRetry()", "program debt schedules recovery retry")
	AssertContains(Gate, 'return _LifecycleRefuseShutdown("a user program tree is still alive")',
		"program debt uses the shared bounded refusal and pending-reload compensation")
	AssertFalse(InStr(Body, "return 1", true), "a program tree cannot bypass the shutdown veto budget")
	AssertContains(Body, "_ConfigWriteTerminalRelease(ShutdownOwners)", "refusal releases an owned config bundle")
	AssertContains(Body, "LLM_NavEventOwner_CancelShutdown()", "refusal compensates native admission")
	Reload := _StripFullLineComments(_DriverFuncBody("_ReloadPreservingSuspendNonCritical"))
	Assert(Reload != "", "the real reload preflight must be source-visible")
	AssertContains(Reload, "ProgramActions_Stop(A_IsSuspended)",
		"refused reload preflight preserves actual native pause posture")
}
Test("user program: shutdown retirement joins the bounded compensated envelope", _RPA_ShutdownRetirementEnvelope)

_RPA_EnvelopeDone(State, Code, Output, Errors) {
	State["code"] := Code
	State["output"] := Output
	State["errors"] := Errors
	State["calls"] += 1
}

_RPA_ExactNativeShutdownEnvelope() {
	Root := A_Temp . "\program_shutdown106_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the shutdown child fixture has a private owner")
	DirCreate(Root)
	CanRetire := true
	try {
		Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n"
		; The extracted handler names unrelated terminal owners that this envelope
		; never reaches. Their unset warnings are expected, not startup evidence.
		Source .= "#Warn VarUnset, Off`n"
		for Name in ["Ergopti_OnShutdown", "_LifecycleRefuseShutdown",
				"LifecycleShutdownVetoHonored", "_LifecycleForceReleaseHeldInput",
				"_ReloadPreservingSuspendNonCritical", "ProgramActions_Stop", "_ProgramActions_Retire"] {
			Body := _DriverFuncBody(Name)
			Assert(Body != "", "the exact production owner is extracted: " . Name)
			Source .= Body . "`n"
		}
		Driver := _DriverSourceNoComments()
		Assert(RegExMatch(Driver, "m)^global LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS := [^`r`n]+", &Budget),
			"the native child borrows the actual production budget declaration")
		Source .= Budget[0] . "`n"
		Source .= 'global _LifecycleShutdownVetoAttempts := 0' . "`n"
		Source .= 'global _LifecycleShutdownReason := ""' . "`n"
		Source .= 'global _UserProgramEntries := Map()' . "`n"
		Source .= 'global _UserProgramGeneration := 0' . "`n"
		Source .= 'global _UserProgramPaused := false' . "`n"
		Source .= 'global _UserProgramAcquiring := 0' . "`n"
		Source .= 'global _RPA_EnvelopeState := Map()' . "`n"
		Source .= '#Include ' . A_ScriptDir . "\support\run_program_shutdown_envelope.ahk`n"
		Harness := Root . "\shutdown.ahk"
		FileAppend(Source, Harness, "UTF-8")
		State := Map("calls", 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Harness], _RPA_EnvelopeDone.Bind(State))
		try {
			AssertEqual(1, Handle.start(), "the exact production shutdown child starts")
			Started := A_TickCount
			while !State["calls"] && TickElapsed(Started) < 10000 {
				_SR_TreePoll()
				Sleep(10)
			}
			AssertEqual(1, State["calls"], "the native envelope completes exactly once within its bound")
			AssertEqual(0, State["code"], "exact shutdown/reload production bodies execute: "
				. State["output"] . State["errors"])
			AssertEqual("", State["errors"], "native shutdown envelope reports no hidden execution error")
			AssertEqual("program-shutdown-envelope-ok", State["output"], "all active/paused refusal cases run")
		} finally {
			Retired := Handle.terminate()
			CanRetire := (Retired is Integer) && Retired == 1
			AssertTrue(CanRetire, "the exact shutdown child tree is physically retired before fixture removal")
		}
	} finally {
		if CanRetire
			DirDelete(Root, true)
	}
}
Test("user program: exact native shutdown and reload preserve refusal ownership", _RPA_ExactNativeShutdownEnvelope)

_RPA_WithCapturedProgramLogs(Body, Context) {
	global _LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED, _LOGGER_REPEAT_ENABLED
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_COUNT, _LOGGER_DEDUP_LEVEL, _LastErrTime
	Saved := [_LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED, _LOGGER_REPEAT_ENABLED,
		_LOGGER_DEDUP_KEY, _LOGGER_DEDUP_COUNT, _LOGGER_DEDUP_LEVEL, _LastErrTime]
	Logs := []
	Context["logs"] := Logs
	try {
		LoggerSetTestSink((Line) => Logs.Push(Line))
		_LOGGER_ERROR_ENABLED := true
		_LOGGER_REPEAT_ENABLED := false
		_RPA_ClearProgramLogs(Context)
		Body.Call(Context)
	} finally {
		_LOGGER_TEST_SINK := Saved[1]
		_LOGGER_ERROR_ENABLED := Saved[2]
		_LOGGER_REPEAT_ENABLED := Saved[3]
		_LOGGER_DEDUP_KEY := Saved[4]
		_LOGGER_DEDUP_COUNT := Saved[5]
		_LOGGER_DEDUP_LEVEL := Saved[6]
		_LastErrTime := Saved[7]
	}
}

_RPA_ClearProgramLogs(Context) {
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_COUNT
	Context["logs"].Length := 0
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_COUNT := 0
}

_RPA_ProgramDiagnostics(Context) {
	Lines := []
	for Line in Context["logs"] {
		AssertFalse(InStr(Line, Context["script"], true), "program diagnostics never disclose the executable argument path")
		AssertFalse(InStr(Line, "private-stdout106", true), "program diagnostics never disclose child stdout")
		AssertFalse(InStr(Line, "private-stderr106", true), "program diagnostics never disclose child stderr")
		AssertFalse(InStr(Line, "private-receipt106", true), "program diagnostics never disclose malformed status content")
		if InStr(Line, "[UserProgram]", true)
			Lines.Push(Line)
	}
	return Lines
}

_RPA_NativeNonzeroDiagnostic(Context) {
	FileDelete(Context["script"])
	FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n"
		. 'FileAppend("private-stdout106", "*", "UTF-8-RAW")`n'
		. 'FileAppend("private-stderr106", "**", "UTF-8-RAW")`n'
		. 'ExitApp(37)`n', Context["script"], "UTF-8")
	AssertEqual(true, ProgramActions_Run("gesture__tap_3"), "actual nonzero native child starts under canonical admission")
	_RPA_WaitSettled()
	Lines := _RPA_ProgramDiagnostics(Context)
	AssertEqual(1, Lines.Length, "actual admitted nonzero completion emits exactly one private-safe error")
	AssertContains(Lines[1], "User program exited with status 37.", "the native exit status remains visible")
	AssertContains(Lines[1], "[ERROR]", "a nonzero native completion is an error rather than success")
}
Test("user program: actual native nonzero exit exposes only its closed status",
	_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPA_NativeNonzeroDiagnostic)))

_RPA_IndependentLiteralScript(Context) {
	global ConfigurationFile, GestureActionParameters, _UserProgramEntries, _SR_TreeOwnedTasks
	Binding := "gesture__tap_3"
	Executable := Context["directory"] . "\AutoHotkey été 日本 copy.exe"
	Gate := Context["directory"] . "\release native child.gate"
	EnvName := "ERGOPTI_PROGRAM_LITERAL_106"
	SavedEnvironment := EnvGet(EnvName)
	ProcessObserver := 0, JobObserver := 0, NativeState := 0
	CanRemoveFixture := false
	Values := ["", "two words", "日本語", "é", "e" . Chr(0x301),
		"a" . Chr(34) . "b" . Chr(39), "a" . Chr(96) . "b",
		"$(touch must-not-interpolate)", "%ERGOPTI_PROGRAM_LITERAL_106%",
		"line`nnext", "C:\folder with spaces\"]
	; Independent byte expectations are fixed here, never generated by the
	; program parser, command-line composer or native child implementation.
	Expected := "11`n0:`n9:74776F20776F726473`n9:E697A5E69CACE8AA9E`n2:C3A9`n"
		. "3:65CC81`n4:61226227`n3:616062`n"
		. "29:2428746F756368206D7573742D6E6F742D696E746572706F6C61746529`n"
		. "29:254552474F5054495F50524F4752414D5F4C49544552414C5F31303625`n"
		. "9:6C696E650A6E657874`n22:433A5C666F6C6465722077697468207370616365735C`n"
	try {
		FileCopy(A_AhkPath, Executable, false)
		AssertEqual(FileGetSize(A_AhkPath), FileGetSize(Executable),
			"the actual runtime is copied to the owned Unicode/spaced executable path")
		FileDelete(Context["script"])
		; This real BOM script uses only AHK primitives. The owned gate keeps its
		; process alive until independent process and Job observers are retained.
		Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n"
			. 'if A_Args.Length != 13`n ExitApp(74)`n'
			. 'Receipt := (A_Args.Length - 2) . Chr(10)`n'
			. 'for Index, Value in A_Args {`n'
			. ' if Index <= 2`n  continue`n'
			. ' Bytes := Buffer(StrPut(Value, "UTF-8"))`n'
			. ' Count := StrPut(Value, Bytes, "UTF-8") - 1`n'
			. ' Receipt .= Count . ":"`n'
			. ' loop Count`n  Receipt .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))`n'
			. ' Receipt .= Chr(10)`n}`n'
			. 'FileAppend(Receipt, A_Args[1], "UTF-8-RAW")`n'
			. 'FileAppend("private-stdout106", "*", "UTF-8-RAW")`n'
			. 'FileAppend("private-stderr106", "**", "UTF-8-RAW")`n'
			. 'Started := A_TickCount`n'
			. 'while !FileExist(A_Args[2]) {`n'
			. ' if A_TickCount - Started >= 30000`n  ExitApp(74)`n'
			. ' Sleep(10)`n}`nExitApp(37)`n'
		FileAppend(Source, Context["script"], "UTF-8")
		Arguments := ["/ErrorStdOut", Context["script"], Context["output"], Gate]
		for Value in Values
			Arguments.Push(Value)
		EncodedArguments := "["
		for Index, Argument in Arguments
			EncodedArguments .= (Index > 1 ? "," : "") . JsonStringLiteral(Argument)
		EncodedArguments .= "]"
		Scalar := '{"version":1,"executable":' . JsonStringLiteral(Executable)
			. ',"arguments":' . EncodedArguments . '}'
		GestureActionParameters := Map("gesture__tap_3__run_program", Scalar, "keyboard__ctrl_p__run_program", Scalar)
		FileDelete(ConfigurationFile)
		FileAppend('[gestures]`ntap_3 = "run_program"`n[shortcuts.keyboard]`nctrl_p = "run_program"`n'
			. '[action_parameters]`n"gesture__tap_3__run_program" = ' . JsonStringLiteral(Scalar)
			. '`n"keyboard__ctrl_p__run_program" = ' . JsonStringLiteral(Scalar) . '`n', ConfigurationFile, "UTF-8")
		EnvSet(EnvName, "must-not-expand-private106")
		AssertEqual(true, ProgramActions_Run(Binding), "the actual Unicode/spaced runtime and script start")
		Assert(_UserProgramEntries.Has(Binding), "the exact private action owner remains live behind its gate")
		Entry := _UserProgramEntries[Binding]
		PreviousCritical := Critical("On")
		try {
			Pid := Entry["handle"].processId()
			for _, State in _SR_TreeOwnedTasks {
				if State["Pid"] == Pid && State["Executable"] == Executable {
					NativeState := State
					break
				}
			}
			Assert(NativeState is Map, "the observers borrow only this exact live native task")
			ProcessObserver := _SRTOW_OpenExactProcess(Pid)
			JobObserver := _SRTOW_DuplicateNativeHandle(NativeState["JobHandle"])
		} finally Critical(PreviousCritical)
		Assert(ProcessObserver != 0 && JobObserver != 0, "independent native observers are retained before release")
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(ProcessObserver), "the exact child is alive before release")
		Assert(_SRTOW_ExactJobActiveProcessCount(JobObserver) > 0, "the exact Job contains its gated live process")
		AssertEqual(false, NativeState["CaptureOutput"], "private script streams are physically discarded")
		AssertEqual(true, NativeState["PrivateDiagnostics"], "native failures use closed private diagnostics")
		AssertEqual("", NativeState["TmpFile"], "discard mode allocates no capture file")
		AssertEqual("", NativeState["CaptureDir"], "discard mode allocates no capture directory")
		Started := A_TickCount
		while !FileExist(Context["output"]) && TickElapsed(Started) < 5000
			Sleep(10)
		Assert(FileExist(Context["output"]) != "", "the actual independent script records every argument before exit")
		AssertEqual(Expected, FSReadUtf8Exact(Context["output"]),
			"literal byte receipt preserves empty/Unicode/NFD/quotes/backticks/dollars/percent/newline/slash")
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(ProcessObserver), "argument receipt alone cannot settle the live child")
		FileAppend("release", Gate, "UTF-8-RAW")
		_RPA_WaitSettled()
		Assert(_SRTOW_WaitForExactProcessExit(ProcessObserver), "the exact root HANDLE is signalled before completion is accepted")
		AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(JobObserver), "the duplicate exact Job proves complete physical retirement")
		AssertEqual(0, NativeState["ProcessHandle"], "the production owner retires its native root capability")
		AssertEqual(0, NativeState["JobHandle"], "the production owner retires its native Job capability")
		Lines := _RPA_ProgramDiagnostics(Context)
		AssertEqual(1, Lines.Length, "the admitted script emits one closed nonzero diagnostic")
		AssertContains(Lines[1], "User program exited with status 37.", "the real script's native exit status remains exact")
		for Line in Context["logs"] {
			AssertFalse(InStr(Line, Executable, true), "private diagnostics never reveal the copied executable path")
			AssertFalse(InStr(Line, "must-not-expand-private106", true), "private diagnostics never reveal argument expansion data")
		}
	} finally {
		try {
			Deadline := A_TickCount + 5000
			StopReceipt := ProgramActions_Stop(true)
			while !((StopReceipt is Integer) && StopReceipt == 1) && A_TickCount < Deadline {
				Sleep(10)
				StopReceipt := ProgramActions_Stop(true)
			}
			; A failed primary assertion remains red. Cleanup owns the duplicate Job
			; directly so even a premature callback cannot orphan its native child.
			if JobObserver && _SRTOW_ExactJobActiveProcessCount(JobObserver) != 0
				Assert(DllCall("Kernel32\TerminateJobObject", "Ptr", JobObserver,
					"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int"), "failed-fixture cleanup stops only its exact Job")
			ProcessExited := !ProcessObserver || _SRTOW_WaitForExactProcessExit(ProcessObserver)
			Deadline := A_TickCount + 5000
			while JobObserver && _SRTOW_ExactJobActiveProcessCount(JobObserver) != 0 && A_TickCount < Deadline
				Sleep(10)
			JobEmpty := !JobObserver || _SRTOW_ExactJobActiveProcessCount(JobObserver) == 0
			CanRemoveFixture := ProcessExited && JobEmpty && _UserProgramEntries.Count == 0
				&& (StopReceipt is Integer) && StopReceipt == 1
			Context["preserve_directory"] := !CanRemoveFixture
			Assert(CanRemoveFixture, "native observers and strict owner receipt must prove retirement before fixture removal")
		} finally {
			if !CanRemoveFixture
				Context["preserve_directory"] := true
			; Attempt both native closes before asserting either receipt, and restore
			; the borrowed environment even when an observer refuses its close.
			try {
				ProcessClosed := !ProcessObserver || DllCall("Kernel32\CloseHandle", "Ptr", ProcessObserver, "Int")
			} finally {
				try {
					JobClosed := !JobObserver || DllCall("Kernel32\CloseHandle", "Ptr", JobObserver, "Int")
				} finally EnvSet(EnvName, SavedEnvironment)
			}
			Assert(ProcessClosed, "the exact process observer is closed")
			Assert(JobClosed, "the exact Job observer is closed")
		}
	}
}
Test("user program: independent Unicode script preserves literal bytes private streams and exact native Job retirement",
	_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPA_IndependentLiteralScript)))

_RPA_CompletionSuppression(Context) {
	global _UserProgramEntries, _UserProgramGeneration, _UserProgramPaused
	Binding := "gesture__tap_3"
	for Mode in ["cancelled", "generation", "paused", "source", "replaced", "successful"] {
		_RPA_ClearProgramLogs(Context)
		Snapshot := _ProgramActions_Snapshot(Binding)
		Assert(Snapshot is Map, "completion suppression captures an actual canonical source")
		Entry := Map("binding", Binding, "snapshot", Snapshot, "cancelled", Mode == "cancelled")
		Replacement := Map("binding", Binding, "fixture", true)
		_UserProgramEntries[Binding] := Mode == "replaced" ? Replacement : Entry
		try {
			if Mode == "generation"
				_UserProgramGeneration += 1
			if Mode == "paused"
				_UserProgramPaused := true
			if Mode == "source" {
				FileDelete(Snapshot["path"])
				FileAppend('[gestures]`ntap_3 = "none"`n', Snapshot["path"], "UTF-8")
			}
			AssertTrue(_ProgramActions_Done(Entry, Mode == "successful" ? 0 : 37,
				"private-stdout106", "private-stderr106"), "actual completion owner handles the private receipt")
			AssertEqual(0, _RPA_ProgramDiagnostics(Context).Length,
				Mode . " completion does not emit an obsolete program error")
			if Mode == "replaced"
				Assert(_UserProgramEntries.Get(Binding, 0) == Replacement,
					"obsolete completion preserves the replacement's exact ownership")
			else
				AssertFalse(_UserProgramEntries.Has(Binding), "settled completion releases its exact current entry")
		} finally {
			_UserProgramPaused := false
			if Mode == "source" {
				FileDelete(Snapshot["path"])
				FileAppend(Snapshot["source"], Snapshot["path"], "UTF-8")
			}
			if _UserProgramEntries.Has(Binding) && (_UserProgramEntries[Binding] == Entry
					|| _UserProgramEntries[Binding] == Replacement)
				_UserProgramEntries.Delete(Binding)
		}
	}
}
Test("user program: actual completion suppresses cancelled stale paused and successful diagnostics",
	_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPA_CompletionSuppression)))

_RPA_MalformedCompletion(Context) {
	global _UserProgramEntries
	Binding := "gesture__tap_3"
	for Receipt in ["37", "private-receipt106", Map("private-receipt106", true), -1, 0x100000000, "missing"] {
		_RPA_ClearProgramLogs(Context)
		Snapshot := _ProgramActions_Snapshot(Binding)
		Assert(Snapshot is Map, "malformed completion starts from admitted canonical data")
		Entry := Map("binding", Binding, "snapshot", Snapshot, "cancelled", false)
		_UserProgramEntries[Binding] := Entry
		try {
			Missing := (Receipt is String) && Receipt == "missing"
			Completed := Missing ? _ProgramActions_Done(Entry)
				: _ProgramActions_Done(Entry, Receipt, "private-stdout106", "private-stderr106")
			AssertTrue(Completed,
				"an observed physical completion retires its exact entry even with malformed status")
			Lines := _RPA_ProgramDiagnostics(Context)
			AssertEqual(1, Lines.Length, "malformed completion is visible through one closed generic diagnostic")
			AssertContains(Lines[1], "User program returned an invalid exit status.",
				"malformed status cannot be coerced to successful or formatted into private diagnostics")
			AssertFalse(_UserProgramEntries.Has(Binding), "malformed status does not retain fictitious physical process debt")
		} finally {
			if _UserProgramEntries.Get(Binding, 0) == Entry
				_UserProgramEntries.Delete(Binding)
		}
	}
}
Test("user program: malformed completion never formats untrusted private status",
	_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPA_MalformedCompletion)))

_RPA_UnsetKeyboardBody(Context) {
	global KeyboardShortcutAssignments
	Assert(KeyboardShortcutAssignments is Map, "fixture initializes the actual keyboard assignment owner")
	AssertEqual("run_program", KeyboardShortcutAssignments.Get("ctrl_p", ""), "fixture initializes the keyboard binding")
	AssertEqual(Context["scalar"], GestureGetActionParameter("gesture__tap_3", "run_program"),
		"fixture uses the actual acknowledged action parameter owner")
}

_RPA_UnsetKeyboardRestored() {
	global KeyboardShortcutAssignments
	Saved := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	try {
		KeyboardShortcutAssignments := unset
		_RPA_WithFixture(_RPA_UnsetKeyboardBody)
		AssertFalse(IsSet(KeyboardShortcutAssignments), "fixture restores an originally unset owner")
	} finally KeyboardShortcutAssignments := IsSet(Saved) ? Saved : unset
}
Test("user program: native fixture owns and restores an unset keyboard map", _RPA_UnsetKeyboardRestored)

_RPA_PollPort(State, Callback, Period) {
	Assert(HasMethod(Callback, "Call"), "poll retains one callable native identity")
	State["calls"].Push(Map("callback", Callback, "period", Period))
	if Period == 0 {
		if State["cancel"] == "throw"
			throw Error("controlled poll cancellation refusal")
		return State["cancel"]
	}
	Assert(Period < 0, "poll schedules one-shot cleanup instead of a repeating typing-thread stall")
	if State["schedule"] == "throw"
		throw Error("controlled poll schedule refusal")
	if State["schedule"] == "early" {
		State["early_receipt"] := Callback.Call()
		return true
	}
	if State["schedule"] == "stop" {
		State["stop_receipt"] := ProgramActions_Stop(true)
		return true
	}
	return State["schedule"]
}

class _RPA_ControlledPollHandle {
	__New(State) {
		this.State := State
	}
	terminate() {
		this.State["terminations"] += 1
		return this.State["retire"]
	}
}

_RPA_PollCustody() {
	global _UserProgramPollOwner, _UserProgramEntries, _UserProgramPaused
	AssertEqual(0, _UserProgramEntries.Count, "controlled timer test borrows no native program")
	AssertFalse(IsObject(_UserProgramPollOwner), "controlled timer test borrows no timer")
	SavedPaused := _UserProgramPaused
	State := Map("calls", [], "schedule", true, "cancel", true, "retire", false, "terminations", 0)
	Port := _RPA_PollPort.Bind(State)
	try {
		AssertTrue(_ProgramActions_EnsurePoll(Port), "literal timer admission owns its bound callback")
		Owner := _UserProgramPollOwner
		Callback := Owner["callback"]
		for Refusal in [false, "", "throw"] {
			State["cancel"] := Refusal
			AssertFalse(_ProgramActions_StopPoll(), "false unknown and throwing cancellation retains debt")
			Assert(_UserProgramPollOwner == Owner, "exact refused timer capability remains retained")
			AssertFalse(ProgramActions_Run("gesture__tap_3"), "timer debt blocks successor acquisition")
		}
		State["cancel"] := true
		Owner["active"] := true
		AssertFalse(_ProgramActions_StopPoll(), "an active callback prevents terminal acknowledgement")
		Assert(_UserProgramPollOwner == Owner, "active native callback retains the same owner")
		Owner["active"] := false
		AssertTrue(_ProgramActions_StopPoll(), "fresh exact cancellation settles the inactive owner")
		AssertFalse(IsObject(_UserProgramPollOwner), "acknowledged timer capability retires")
		for Call in State["calls"]
			Assert(Call["callback"] == Callback, "every inverse uses the original exact native callback")
		for Refusal in [false, "", "throw"] {
			State["schedule"] := Refusal, State["cancel"] := false
			AssertFalse(_ProgramActions_EnsurePoll(Port), "refused timer acquisition cannot become success")
			Assert(IsObject(_UserProgramPollOwner), "ambiguous schedule retains its exact cancellation capability")
			State["cancel"] := true
			AssertTrue(_ProgramActions_StopPoll(), "strict compensation retires a refused schedule")
		}
		State["schedule"] := "early"
		AssertFalse(_ProgramActions_EnsurePoll(Port), "callback before same-call timer admission cannot become success")
		AssertEqual(false, State["early_receipt"], "early native callback cannot run cleanup before admission")
		AssertFalse(IsObject(_UserProgramPollOwner), "exact compensation retires an early consumed callback")
		State["schedule"] := "stop"
		AssertFalse(_ProgramActions_EnsurePoll(Port), "cancellation during timer acquisition refuses activation")
		AssertEqual(false, State["stop_receipt"], "acquiring timer cannot acknowledge early shutdown")
		AssertFalse(IsObject(_UserProgramPollOwner), "acquisition compensation retires the exact timer")
		State["schedule"] := true
		AssertTrue(_ProgramActions_EnsurePoll(Port), "a fresh timer can start after physical compensation")
		Current := _UserProgramPollOwner
		AssertFalse(Callback.Call(), "old retired callback cannot act on the new owner")
		Assert(_UserProgramPollOwner == Current, "old callback preserves the fresh exact owner")
		AssertTrue(_ProgramActions_StopPoll(), "the final owned timer retires")
		AssertTrue(_ProgramActions_EnsurePoll(Port), "physical retirement debt owns a cleanup callback")
		DebtOwner := _UserProgramPollOwner
		DebtCallback := DebtOwner["callback"]
		Entry := Map("binding", "gesture__controlled-poll", "cancelled", false,
			"handle", _RPA_ControlledPollHandle(State), "snapshot", 0, "started", A_TickCount)
		_UserProgramEntries[Entry["binding"]] := Entry
		AssertFalse(ProgramActions_Stop(true), "refused physical retirement cannot acknowledge stop")
		Assert(_UserProgramEntries.Get(Entry["binding"], 0) == Entry, "the exact refused handle remains owned")
		Assert(_UserProgramPollOwner == DebtOwner && DebtOwner["scheduled"],
			"refused physical retirement preserves an actually scheduled cleanup callback")
		AssertFalse(DebtOwner["cancelled"], "physical debt must not cancel its only retry callback")
		Assert(State["calls"][-1]["callback"] == DebtCallback && State["calls"][-1]["period"] < 0,
			"stop rearms the same exact one-shot callback while physical debt remains")
		State["retire"] := true
		AssertTrue(DebtCallback.Call(), "the retained exact callback retries physical retirement")
		AssertEqual(2, State["terminations"], "physical termination is retried after the refused attempt")
		AssertFalse(_UserProgramEntries.Has(Entry["binding"]), "strict physical receipt retires the exact entry")
		AssertFalse(IsObject(_UserProgramPollOwner), "physical retirement also settles its exact callback")
	} finally {
		State["cancel"] := true
		State["retire"] := true
		AssertTrue(ProgramActions_Stop(SavedPaused), "controlled program cleanup must actually acknowledge")
		AssertTrue(_ProgramActions_StopPoll(), "controlled timer cleanup must actually acknowledge")
		_UserProgramPaused := SavedPaused
	}
}
Test("user program: exact one-shot poll retains refused acquisition and callback debt", _RPA_PollCustody)
