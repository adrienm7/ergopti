; tests/unit/test_run_program_actions.ahk

_RPA_DescriptorPrimitiveStages() {
	Text := "{x", Position := 1
	Delimiter := SubStr(Text, Position++, 1)
	Assert(Delimiter == "{" && Position == 2, "program outer primitive postfix delimiter and cursor")
	Assert(RegExMatch("1,", "^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?", &Token),
		"program outer primitive version token is present")
	Assert(Token[0] == "1", "program outer primitive version token has exact span")
	try Version := JsonParse(Token[0])
	catch Any {
		Assert(false, "program outer primitive version decoder raised")
	}
	Assert((Version is Integer) && Version == 1, "program outer primitive version is native integer one")
	Data := Map()
	Data.CaseSense := "On"
	Data["version"] := Version
	Data["executable"] := "C:\missing program\script.exe"
	Data["arguments"] := []
	Assert(Data.Count == 3 && Data.Has("version") && Data.Has("arguments"),
		"program outer primitive three-field case-sensitive map")
	Assert(RegExMatch(Data["executable"], "^[A-Za-z]:[/\\]"),
		"program outer primitive fictional drive path is admitted")
	AssertFalse(RegExMatch(Data["executable"], "^\\\\[?.]\\"),
		"program outer primitive fictional drive is not a device path")
	Text := '"",0', Position := 1
	try Empty := _ProgramParameterString(Text, &Position)
	catch Any {
		Assert(false, "program outer primitive empty argument decoder raised")
	}
	Assert((Empty is String) && Empty == "" && SubStr(Text, Position) == ",0",
		"program outer primitive empty argument remains a string at its exact cursor")
	; Native InStr rejects an empty needle; EOF must short-circuit before that call.
	LegacyEOFRejected := false
	try InStr(" `t`r`n", SubStr("x", 2, 1))
	catch Any as Err {
		LegacyEOFRejected := Type(Err) == "ValueError"
	}
	Assert(LegacyEOFRejected, "program whitespace native empty needle has the observed ValueError class")
	for Vector in [
		Map("value", "", "position", 1, "expected", 1),
		Map("value", "x", "position", 2, "expected", 2),
		Map("value", " `t`r`n", "position", 1, "expected", 5),
		Map("value", " `t`r`nx", "position", 1, "expected", 5),
		Map("value", "x", "position", 1, "expected", 1)
	] {
		Position := Vector["position"]
		try _ProgramParameterWs(Vector["value"], &Position)
		catch Any {
			Assert(false, "program whitespace actual owner raised at an authored boundary")
		}
		AssertEqual(Vector["expected"], Position, "program whitespace actual owner exact cursor")
	}
	Scalar := '{"version":1,"executable":"C:\\missing program\\script.exe","arguments":[]}'
	for Padding in ["", " `t`r`n"] {
		Actual := _ProgramParameterParseWithStage(Scalar . Padding, &Stage)
		Assert(Actual is Map, "program whitespace complete descriptor stage: " . Stage)
		AssertEqual("done", Stage, "program whitespace complete descriptor terminal stage")
		AssertEqual("C:\missing program\script.exe", Actual["executable"],
			"program whitespace complete descriptor executable bytes")
		AssertEqual(0, Actual["arguments"].Length, "program whitespace complete descriptor empty argv")
	}
	AssertFalse(ProgramParameterParse(Scalar . " `t`r`nx"), "program whitespace trailing non-whitespace refuses")
	AssertFalse(ProgramParameterParse(""), "program whitespace empty descriptor refuses")

}
Test("user program: closed outer decoder native primitives", _RPA_DescriptorPrimitiveStages)

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
	Actual := _ProgramParameterParseWithStage(Scalar, &Stage)
	Assert(Actual is Map, "program stage actual descriptor decoder: " . Stage)
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

	; UTF-8 creation adds a physical BOM; exact source reads deliberately retain it.
	Probe := Context["directory"] . "\native-utf8-bom.receipt"
	AssertFalse(FileExist(Probe), "native BOM transport probe starts with its own absent file")
	try {
		FileAppend(Foreign, Probe, "UTF-8")
		Bytes := FileRead(Probe, "RAW")
		AssertEqual(StrPut(Foreign, "UTF-8") - 1 + 3, Bytes.Size, "native UTF-8 append has exact body bytes plus one BOM")
		Assert(NumGet(Bytes, 0, "UChar") == 0xEF && NumGet(Bytes, 1, "UChar") == 0xBB
			&& NumGet(Bytes, 2, "UChar") == 0xBF, "native UTF-8 append has the physical EF BB BF prefix")
		Observed := FSReadUtf8Exact(Probe)
		AssertEqual(Chr(0xFEFF) . Foreign, Observed, "native UTF-8 append adds exactly one physical BOM")
		AssertFalse(Observed == Foreign, "default BOM transport differs from the authored BOM-less source")
		AssertFalse(InStr(Observed, "`r"), "native UTF-8 append preserves authored LF without a newline option")
	} finally FileDelete(Probe)
	FileDelete(ConfigurationFile)
	FileAppend(Foreign, ConfigurationFile, "UTF-8-RAW")
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
				"_ReloadPreservingSuspendNonCritical", "ProgramActions_Stop", "_ProgramActions_Retire",
				"_ProgramActions_EnsurePoll", "_ProgramActions_StopPoll", "ProgramActions_Poll",
				"_ProgramActions_Admitted", "_ProgramActions_BindingAction",
				"TimerSetCallback", "_TimerAdapterSetNative"] {
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
		Source .= 'global _UserProgramPollOwner := 0' . "`n"
		Source .= 'global ConfigurationFile := ""' . "`n"
		Source .= 'global GestureAssignments := Map()' . "`n"
		Source .= 'global KeyboardShortcutAssignments := Map()' . "`n"
		Source .= 'global ScriptShortcutAssignments := Map()' . "`n"
		Source .= 'global TapKeyAssignments := Map()' . "`n"
		Source .= "global TIMER_ADAPTER_MAX_INTERVAL_MS := " . TIMER_ADAPTER_MAX_INTERVAL_MS . "`n"
		Source .= 'global _RPA_EnvelopeTimings := Map("aux_shell_cleanup_retry_ms", '
			. TimingsGet("gestures", "aux_shell_cleanup_retry_ms") . ', "aux_shell_timeout_ms", '
			. TimingsGet("gestures", "aux_shell_timeout_ms") . ")`n"
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
				; The captured exact image already contains its initial physical BOM.
				Probe := Context["directory"] . "\native-utf8-restore.receipt"
				AssertFalse(FileExist(Probe), "native restoration probe starts with its own absent file")
				try {
					Assert(SubStr(Snapshot["source"], 1, 1) == Chr(0xFEFF),
						"the actual canonical snapshot retains its original physical BOM")
					FileAppend(Snapshot["source"], Probe, "UTF-8")
					Bytes := FileRead(Probe, "RAW")
					AssertEqual(StrPut(Snapshot["source"], "UTF-8") - 1 + 3, Bytes.Size,
						"default restoration adds three physical BOM bytes to the captured image")
					for Offset in [0, 3]
						Assert(NumGet(Bytes, Offset, "UChar") == 0xEF && NumGet(Bytes, Offset + 1, "UChar") == 0xBB
							&& NumGet(Bytes, Offset + 2, "UChar") == 0xBF, "default restoration has two physical BOM prefixes")
					AssertEqual(Chr(0xFEFF) . Snapshot["source"], FSReadUtf8Exact(Probe),
						"default UTF-8 restoration duplicates the captured physical BOM")
				} finally FileDelete(Probe)
				FileDelete(Snapshot["path"])
				FileAppend(Snapshot["source"], Snapshot["path"], "UTF-8-RAW")
				AssertEqual(Snapshot["source"], FSReadUtf8Exact(Snapshot["path"]),
					"completion restoration preserves the exact captured source bytes")
				Assert(_ProgramActions_Snapshot(Binding) is Map,
					"completion restoration preserves actual canonical admission for the next mode")
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

; Explicit surrounding State fixture; native operations are production functions.
_RPA_ConstructorFixtureState(Context) {
	global _SR_TaskCounter
	return Map("TaskId", ++_SR_TaskCounter, "Executable", A_AhkPath,
		"Command", _SR_BuildDirectCommandLine(A_AhkPath, [Context["script"], Context["output"], "must-not-run106"]),
		"TmpFile", "", "CaptureDir", "", "CaptureOutput", false,
		"PrivateDiagnostics", true, "MaxOutputBytes", 0, "BadArgIndex", 0,
		"ValidationError", "", "OnDone", 0, "BeforeNativeAdopt", 0,
		"Starting", false, "Started", false, "TerminationRequested", false,
		"PendingTerminationCallback", 0, "TerminalClaimed", false,
		"TerminalClaim", 0, "TreeQuiesced", false, "FinalizationPending", false,
		"AccountingDiagnosticLogged", false, "AccountingFailureCount", 0,
		"RootReaped", false, "ExitQueryDiagnostic", "", "ExitCode", 0,
		"Detached", false, "ProcessHandle", 0, "ThreadHandle", 0,
		"JobHandle", 0, "Pid", 0)
}

; Registered native constructor regressions; actual Windows execution is required.
; The surrounding State and handle are explicit fixtures; start/terminate,
; native creation, physical teardown, private logging and ProgramActions_Stop
; are the actual candidate production functions.

_RPA_ConstructorFailure(Mode, Context) {
	global _SR_TaskCounter, _SR_TreeNativeDebts, _SR_TreeOwnedTasks
	global _UserProgramEntries, _UserProgramAcquiring, _UserProgramPaused
	Context["preserve_directory"] := true
	RequestCallback := Mode == "request-before-bind"
	AssertEqual(0, _SR_TreeNativeDebts.Count, "fixture cannot borrow another native debt")
	AssertEqual(0, _SR_TreeOwnedTasks.Count, "fixture cannot borrow another active tree")
	State := _RPA_ConstructorFixtureState(Context)
	Scope := Map("protected", 0, "observer", 0, "job_observer", 0,
		"carrier", 0, "create_reentry", 0, "adopt_reentry", 0, "done", 0)
	ProtectFromClose := 0x0002
	Binding := "gesture__tap_3"
	Entry := Map("binding", Binding, "snapshot", _ProgramActions_Snapshot(Binding),
		"cancelled", false, "started", A_TickCount)
	Handle := {}
	Handle.terminate := (*) => _SR_TreeHandleTerminate(State, false)
	Handle.requestTerminate := (*) => _SR_TreeHandleTerminate(State, true)
	Entry["handle"] := Handle
	OnDone(ExitCode, Stdout, Stderr) {
		Scope["done"] += 1
		Scope["callback_root_signalled"] := _SRTOW_ExactProcessWait(Scope["observer"]) == SRTOW_WAIT_OBJECT_0
		Scope["callback_job_empty"] := _SRTOW_ExactJobActiveProcessCount(Scope["job_observer"]) == 0
		Scope["callback_claim_quiesced"] := Scope["carrier"]["Claim"]["TreeQuiesced"]
		Scope["callback_entry_current"] := _UserProgramEntries.Get(Binding, 0) == Entry
		Scope["callback_receipt"] := _ProgramActions_Done(Entry, ExitCode, Stdout, Stderr)
	}
	State["OnDone"] := OnDone
	_UserProgramEntries[Binding] := Entry
	Acquisition := Map("generation", Entry["snapshot"]["generation"])
	_UserProgramAcquiring := Acquisition
	Create(Application, Command, Flags, Startup, ProcessInfo) {
		PLC_CreateProcessWithInheritedHandles(Application, Command, Flags, Startup, ProcessInfo)
		Scope["protected"] := NumGet(ProcessInfo, 0, "Ptr")
		Pid := NumGet(ProcessInfo, 2 * A_PtrSize, "UInt")
		try {
			Scope["observer"] := _SRTOW_OpenExactProcess(Pid)
			if !DllCall("Kernel32\SetHandleInformation", "Ptr", Scope["protected"],
				"UInt", ProtectFromClose, "UInt", ProtectFromClose, "Int")
				throw OSError(A_LastError, "SetHandleInformation")
			Scope["protection_applied"] := true
			AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(Scope["observer"]),
				"actual root remains suspended before construction rollback")
			AssertFalse(_SR_TreeHandleStart(State), "constructor reentry cannot create a second native owner")
			if !RequestCallback
				AssertFalse(ProgramActions_Stop(false), "held constructor cancellation cannot acknowledge unadopted native ownership")
			Assert(_UserProgramEntries.Get(Binding, 0) == Entry, "constructor cancellation retains its exact program entry")
			Scope["create_reentry"] += 1
		} catch Any as Err {
			; CreateFn has not returned PROCESS_INFORMATION to the producer yet.
			; Any failed fixture assertion therefore retains its exact own capsule.
			FaultClaim := Map("ProcessHandle", Scope["protected"],
				"ThreadHandle", NumGet(ProcessInfo, A_PtrSize, "Ptr"),
				"JobHandle", 0, "Assigned", false, "PrivateDiagnostics", true)
			Scope["fault_claim"] := FaultClaim
			if Scope.Get("protection_applied", false)
				DllCall("Kernel32\SetHandleInformation", "Ptr", Scope["protected"],
					"UInt", ProtectFromClose, "UInt", 0, "Int")
			_SR_TreeQuiesceNative(FaultClaim, true)
			if FaultClaim["ProcessHandle"] == 0
				Scope["protected"] := 0
			throw Err
		}
	}
	RejectStreamClose(*) {
		if Mode == "stream-string"
			throw "private-receipt106"
		return false
	}
	Adopt(Carrier) {
		Assert(Carrier["Published"], "physical tuple is published into its durable per-call capsule before the port")
		AssertEqual(Scope["protected"], Carrier["Claim"]["ProcessHandle"], "handoff retains the exact protected root HANDLE")
		AssertEqual(false, Carrier["Claim"]["Assigned"], "failed pre-assignment creation cannot substitute Job existence for assignment")
		Scope["job_observer"] := _SRTOW_DuplicateNativeHandle(Carrier["Claim"]["JobHandle"])
		Assert(Scope["job_observer"] != 0, "fixture retains the actual native Job independently")
		if InStr(Mode, "after", true)
			AssertTrue(_SR_TreeAttachCreationFailure(Carrier), "fault can occur after exact-State binding")
		if RequestCallback {
			AssertFalse(State["TerminalClaimed"], "independent request occurs before State binding")
			AssertFalse(Handle.requestTerminate(), "requestTerminate cannot acknowledge a still-unbound suspended capsule")
			AssertTrue(State["TerminationRequested"], "published STARTING request latches its cancellation")
			Assert(State["PendingTerminationCallback"] == OnDone, "request retains the actual callable completion owner")
			AssertEqual(0, Scope["done"], "request cannot invoke completion before physical native cleanup")
		} else
			AssertFalse(ProgramActions_Stop(false), "adopter reentry cannot acknowledge protected native debt")
		Assert(_UserProgramEntries.Get(Binding, 0) == Entry, "adopter reentry retains its exact program entry")
		Scope["adopt_reentry"] += 1
		if Mode == "before-string" || Mode == "after-string"
			throw "private-receipt106"
		if InStr(Mode, "throw", true)
			throw Error("private-receipt106")
		if Mode == "malformed"
			return "private-receipt106"
		if InStr(Mode, "refuse", true)
			return false
		return _SR_TreeAttachCreationFailure(Carrier)
	}
	CreateFault(Executable, CommandLine, CapturePath, Carrier) {
		Scope["carrier"] := Carrier
		Carrier["AdoptFn"] := Adopt
		return _SR_TreeCreateSuspended(Executable, CommandLine, CapturePath,
			true, Create, RejectStreamClose, Carrier)
	}
	CanRemove := false
	try {
		AssertFalse(_SR_TreeHandleStart(State, CreateFault), "real protected-HANDLE construction failure refuses start")
		AssertEqual(1, Scope["create_reentry"], "actual native constructor cancellation scenario executes once")
		AssertEqual(1, Scope["adopt_reentry"], "actual fault-adoption cancellation scenario executes once")
		Claim := Scope["carrier"]["Claim"]
		Assert(State["TerminalClaim"] == Claim, "start catches the actual capsule instead of claiming empty State")
		AdoptionFailed := InStr(Mode, "refuse", true) || InStr(Mode, "throw", true)
			|| Mode == "before-string" || Mode == "after-string" || Mode == "malformed"
		AssertEqual(!!AdoptionFailed, Scope["carrier"]["AdoptionFailed"], "refusal and thrown/malformed receipt remain explicit")
		Assert(Claim["OwnerState"] == State, "physical debt retains its exact logical owner")
		AssertTrue(Claim["PrivateDiagnostics"], "failure capsule preserves private diagnostics")
		AssertFalse(Claim["TreeQuiesced"], "signalled root alone cannot acknowledge refused native close")
		AssertTrue(_SR_TreeNativeDebts.Has(ObjPtr(Claim)), "exact protected claim remains registered for native retry")
		if RequestCallback
			AssertFalse(Handle.requestTerminate(), "repeated requests retain callback ownership through physical close refusal")
		else
			AssertFalse(_ProgramActions_Retire(Entry), "program retirement cannot delete an entry whose exact HANDLE still refuses close")
		Assert(_UserProgramEntries.Get(Binding, 0) == Entry, "retirement preserves debt rather than dropping its entry")
		_UserProgramAcquiring := 0
		AssertFalse(_UserProgramPaused, "replacement refusal is not caused by the pause gate")
		AssertFalse(ProgramActions_Run("keyboard__ctrl_p"), "clearing acquisition cannot admit replacement while the retained physical entry owes native cleanup")
		AssertFalse(FileExist(Context["output"]), "failed constructor never resumes payload script")
		Assert(_SRTOW_WaitForExactProcessExit(Scope["observer"]), "rollback stops the exact native root")
		AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(Scope["job_observer"]), "the exact pre-assignment Job is physically empty")
		AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Scope["protected"],
			"UInt", ProtectFromClose, "UInt", 0, "Int"), "unprotect only the exact retained root HANDLE")
		Scope["protected"] := 0
		_SR_TreePoll()
		AssertEqual(0, Claim["ProcessHandle"], "native polling closes the actual protected root after refusal ends")
		AssertEqual(0, Claim["ThreadHandle"], "native polling retires the constructor thread capability")
		AssertEqual(0, Claim["JobHandle"], "native polling retires the actual Job capability")
		AssertFalse(_SR_TreeNativeDebts.Has(ObjPtr(Claim)), "native debt ends only after exact physical cleanup")
		if RequestCallback {
			AssertEqual(1, Scope["done"], "pending request callback runs exactly once after physical native retirement")
			AssertTrue(Scope["callback_root_signalled"], "callback observes its exact native root signalled")
			AssertTrue(Scope["callback_job_empty"], "callback observes its exact native Job empty")
			AssertTrue(Scope["callback_claim_quiesced"], "callback receives only a genuinely retired native claim")
			AssertTrue(Scope["callback_entry_current"], "actual private completion owns the exact current program entry")
			AssertTrue(Scope["callback_receipt"], "actual ProgramActions completion accepts only the physical owner callback")
			_SR_TreePoll()
			AssertEqual(1, Scope["done"], "later native polling cannot duplicate the retained request callback")
		} else {
			AssertEqual(0, Scope["done"], "hard constructor cancellation suppresses the actual private completion callback")
			AssertTrue(_ProgramActions_Retire(Entry), "the same program entry can retire after actual native debt ends")
		}
		AssertEqual(0, _UserProgramEntries.Count, "proved native cleanup permits exact entry deletion")
		_RPA_ProgramDiagnostics(Context)
		for Line in Context["logs"]
			AssertFalse(InStr(Line, A_AhkPath, true), "constructor failure never reveals the executable path")
		CanRemove := true
	} finally {
		Context["preserve_directory"] := true
		NativeClean := false, ProcessClosed := false, JobClosed := false
		try {
			_UserProgramAcquiring := 0
			try {
				if Scope["protected"]
					AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Scope["protected"],
						"UInt", ProtectFromClose, "UInt", 0, "Int"), "failed assertion retains recovery of exact native close refusal")
			} finally {
				try {
					if Scope.Has("fault_claim")
						AssertTrue(_SR_TreeQuiesceNative(Scope["fault_claim"], true), "failed protection fixture retires its actual process capability")
				} finally {
					Receipt := ProgramActions_Stop(true)
					NativeClean := (Receipt is Integer) && Receipt == 1
						&& (!Scope["observer"] || _SRTOW_WaitForExactProcessExit(Scope["observer"]))
						&& (!Scope["job_observer"] || _SRTOW_ExactJobActiveProcessCount(Scope["job_observer"]) == 0)
						&& (!Scope.Has("fault_claim") || Scope["fault_claim"].Get("TreeQuiesced", false))
					AssertTrue(NativeClean, "fixture removal requires strict actual native capability cleanup")
				}
			}
		} finally {
			try {
				ProcessClosed := !Scope["observer"] || DllCall("Kernel32\CloseHandle", "Ptr", Scope["observer"], "Int")
				AssertTrue(ProcessClosed, "close independent exact root observer")
			} finally {
				try {
					JobClosed := !Scope["job_observer"] || DllCall("Kernel32\CloseHandle", "Ptr", Scope["job_observer"], "Int")
					AssertTrue(JobClosed, "close independent exact Job observer")
				} finally {
					if CanRemove && NativeClean && ProcessClosed && JobClosed
						Context["preserve_directory"] := false
				}
			}
		}
	}
}

for Mode in ["normal", "before-refuse", "before-throw", "after-refuse", "after-throw", "malformed",
		"before-string", "after-string", "stream-string", "request-before-bind"]
	Test("user program: exact constructor debt survives " . Mode,
		_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPA_ConstructorFailure.Bind(Mode))))

_RPA_ConstructorNoRootFailure(Port, Context) {
	global _UserProgramEntries, _SR_TreeNativeDebts, _SR_TreeOwnedTasks
	Context["preserve_directory"] := true
	State := _RPA_ConstructorFixtureState(Context)
	Scope := Map("calls", 0, "job_observer", 0)
	Entry := Map("binding", "gesture__tap_3", "snapshot", _ProgramActions_Snapshot("gesture__tap_3"),
		"cancelled", false, "started", A_TickCount)
	Entry["handle"] := {terminate: (*) => _SR_TreeHandleTerminate(State, false)}
	_UserProgramEntries[Entry["binding"]] := Entry
	ThrowBeforeCreate(*) {
		Scope["calls"] += 1
		throw "private-receipt106"
	}
	BindNoRoot(Carrier) {
		AssertEqual(0, Carrier["Claim"]["ProcessHandle"], "CreateFn throws before creating any payload process")
		Scope["job_observer"] := _SRTOW_DuplicateNativeHandle(Carrier["Claim"]["JobHandle"])
		Assert(Scope["job_observer"] != 0, "before-create String fault still retains the real allocated Job")
		return _SR_TreeAttachCreationFailure(Carrier)
	}
	CreateFault(Executable, CommandLine, CapturePath, Carrier) {
		Carrier["AdoptFn"] := BindNoRoot
		return _SR_TreeCreateSuspended(Executable, CommandLine, CapturePath,
			true, ThrowBeforeCreate, _SR_TreeCloseLaunchStream, Carrier)
	}
	CanRemove := false
	try {
		Fn := Port == "start" ? ThrowBeforeCreate : CreateFault
		AssertFalse(_SR_TreeHandleStart(State, Fn), "non-Error creator fault is contained into a closed failed start")
		AssertEqual(1, Scope["calls"], "selected non-Error native boundary actually executes")
		AssertFalse(State["Starting"], "non-Error creation refusal cannot leave Starting permanently latched")
		AssertTrue(State["TreeQuiesced"], "no-root creation fault settles only its actual empty/native Job capabilities")
		AssertEqual(0, State["TerminalClaim"]["ProcessHandle"], "no process capability is manufactured by exception handling")
		AssertEqual(0, State["TerminalClaim"]["ThreadHandle"], "no thread capability remains after no-root refusal")
		AssertEqual(0, State["TerminalClaim"]["JobHandle"], "real allocated Job is retired after before-CreateFn refusal")
		AssertEqual(0, _SR_TreeNativeDebts.Count, "no-root refusal leaves no unpublished native debt")
		AssertEqual(0, _SR_TreeOwnedTasks.Count, "no-root refusal never publishes an active task")
		AssertFalse(FileExist(Context["output"]), "non-Error constructor refusal never executes the payload script")
		if Scope["job_observer"]
			AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(Scope["job_observer"]), "independent actual Job observer proves zero native process count")
		AssertTrue(_ProgramActions_Retire(Entry), "truthfully empty construction permits exact caller retirement")
		_RPA_ProgramDiagnostics(Context)
		CanRemove := true
	} finally {
		try {
			Receipt := ProgramActions_Stop(true)
			Assert((Receipt is Integer) && Receipt == 1, "no-root fixture cleanup retains strict actual caller acknowledgement")
		} finally {
			Closed := !Scope["job_observer"] || DllCall("Kernel32\CloseHandle", "Ptr", Scope["job_observer"], "Int")
			AssertTrue(Closed, "close independently retained no-root Job capability")
			if CanRemove && Closed && (Receipt is Integer) && Receipt == 1
				Context["preserve_directory"] := false
		}
	}
}
for Port in ["start", "create"]
	Test("user program: non-Error " . Port . " refusal has a closed no-root receipt",
		_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPA_ConstructorNoRootFailure.Bind(Port))))


; The shared catalogue owns provider commands. These fixtures only supply native
; receipts or independently authored scripts; none launches during discovery.
_RPP_Catalogue() {
	global _SharedDir
	Raw := FSReadUtf8ExactBounded(_SharedDir . "\modules\actions\program_providers.json", 65536)
	Assert(Raw is String, "provider tests read the actual bounded canonical catalogue")
	return Raw
}

_RPP_ControlledOwner() {
	State := Map("directory", "directory1", "script", "script1", "tool", "tool1",
		"route", "C:\owned106\scripts", "retired", true, "owner", 0, "move", "", "readable", true)
	Identity(Path) {
		if State["move"] == "invalidate" {
			State["move"] := ""
			State["owner"].Invalidate()
		}
		if Path == State["route"]
			return Map("kind", "directory", "token", State["directory"])
		if Path == State["route"] . "\été 日本.py"
			return Map("kind", "file", "token", State["script"], "readable", State["readable"], "executable", false)
		if Path == "C:\tool106\python3.exe"
			return Map("kind", "file", "token", State["tool"], "readable", true, "executable", true)
		return Map("kind", "missing", "token", "missing")
	}
	Interpreter(Commands, ProviderId) {
		if State["move"] == "readrevoke" {
			State["move"] := ""
			State["readable"] := false
		}
		if Commands[1] == "python3.exe"
			return Map("executable", "C:\tool106\python3.exe", "token", State["tool"])
		return false
	}
	Owner := ProgramProviderSession(_RPP_Catalogue(), Map(
		"route", (*) => State["route"], "identity", Identity,
		"interpreter", Interpreter, "list", (*) => Map("names", ["été 日本.py"], "truncated", false),
		"retire", (*) => State["retired"]))
	State["owner"] := Owner
	return State
}

_RPP_PolicyReceipts() {
	Catalogue := _RPP_Catalogue()
	AssertEqual(4, ProgramProviderCatalogue(Catalogue).Length, "only the four canonical Windows provider descriptors are admitted")
	AssertFalse(ProgramProviderCatalogue(StrReplace(Catalogue, '"version": 1', '"version": true')),
		"the native parser cannot erase the catalogue Boolean version distinction")
	AssertFalse(ProgramProviderCatalogue(StrReplace(Catalogue, '"ahk"', '"foreign"')),
		"foreign command platform metadata never becomes an installed Windows provider")
	for Pair in [['"id": "python"', '"id": "python\u0000suffix"'],
		['"python3.exe"', '"python3.exe\u0000suffix"'],
		['"/ErrorStdOut=UTF-8"', '"/ErrorStdOut=UTF-8\u0000suffix"']] {
		Corrupt := StrReplace(Catalogue, Pair[1], Pair[2], true)
		Assert(Corrupt != Catalogue, "each independently authored escaped-NUL mutation reaches metadata")
		AssertFalse(ProgramProviderCatalogue(Corrupt), "raw metadata NUL cannot truncate into an admitted catalogue scalar")
	}
	Literal := StrReplace(Catalogue, '"/ErrorStdOut=UTF-8"', '"/ErrorStdOut=UTF-8\\u0000"', true)
	Assert(Literal != Catalogue, "literal escaped-backslash metadata control reaches the canonical prefix")
	Assert(ProgramProviderCatalogue(Literal) is Array, "escaped backslash plus u0000 remains an ordinary metadata literal")
	for Role in ["route", "identity", "interpreter", "list"]
		for Thrown in ["private-metadata106", 41]
			_RPP_ThrowPort(Role, Thrown)
	State := _RPP_ControlledOwner(), Owner := State["owner"]
	Packet := Owner.Discover()
	Assert(Packet is Map, "actual shared discovery policy admits owned native receipts")
	AssertEqual(1, Packet["choices"].Length, "only the verified Python script is exposed")
	AssertEqual("été 日本.py", Packet["choices"][1]["label"], "page sees a basename instead of a machine path")
	Key := Packet["choices"][1]["key"]
	Scalar := Owner.Resolve(Key, ["", "two words", "日本語", "$(literal)", "%literal%", "line`nnext"])
	Parsed := ProgramParameterParse(Scalar)
	Assert(Parsed is Map, "provider resolves through the actual version-one program decoder")
	AssertEqual("C:\tool106\python3.exe", Parsed["executable"], "exact interpreter is preserved")
	AssertEqual(State["route"] . "\été 日本.py", Parsed["arguments"][1], "script is literal argv zero")
	AssertEqual("", Parsed["arguments"][2], "empty script argument remains literal")
	AssertEqual("$(literal)", Parsed["arguments"][5], "shell-looking argument never becomes a command")
	AssertEqual("%literal%", Parsed["arguments"][6], "percent text is never expanded")
	State["readable"] := false
	AssertFalse(Owner.Resolve(Key, []), "same physical script token does not excuse revoked read admission")
	State["readable"] := true
	State["move"] := "readrevoke"
	AssertFalse(Owner.Resolve(Key, []), "final script read admission is rechecked after interpreter callbacks")
	State["readable"] := true
	State["script"] := "replacement"
	AssertFalse(Owner.Resolve(Key, []), "same-named script replacement invalidates the captured choice")
	State["script"] := "script1"
	State["tool"] := "replacement"
	AssertFalse(Owner.Resolve(Key, []), "interpreter replacement invalidates the captured choice")
	State["tool"] := "tool1"
	State["move"] := "invalidate"
	AssertFalse(Owner.Resolve(Key, []), "native callback invalidation cannot lend its old choice to a successor")
	Packet := Owner.Discover()
	Assert(Packet is Map, "fresh discovery explicitly admits its own new generation")
	AssertFalse(Owner.Resolve(Key, []), "old opaque key cannot address the fresh generation")
	State["retired"] := false
	AssertFalse(Owner.Invalidate(), "refused native close remains a real retirement refusal")
	AssertFalse(Owner.Resolve(Packet["choices"][1]["key"], []), "logical invalidation happens even when physical close refuses")
	State["retired"] := true
	AssertTrue(Owner.Invalidate(), "same exact retirement capability can acknowledge its later retry")
}
Test("program providers: exact shared receipts and stale native choices", _RPP_PolicyReceipts)

_RPP_ThrowPort(Role, Thrown) {
	State := _RPP_ControlledOwner(), Owner := State["owner"]
	Original := Owner.Ports[Role]
	Fault(*) {
		throw Thrown
	}
	Owner.Ports[Role] := Fault
	AssertFalse(Owner.Discover(), "arbitrary native port exceptions return a closed discovery refusal")
	AssertFalse(IsObject(Owner.Current), "failed discovery cannot leave an admitted old choice")
	Owner.Ports[Role] := Original
	Packet := Owner.Discover()
	Assert(Packet is Map, "fresh exact ports can admit a new session after controlled discovery refusal")
	Key := Packet["choices"][1]["key"]
	if Role != "list" {
		; Resolve never invokes list: only its actual native observation ports are
		; injected here, so a missing callback cannot manufacture a passing test.
		Owner.Ports[Role] := Fault
		AssertFalse(Owner.Resolve(Key, []), "arbitrary resolution port exceptions cannot escape closed admission")
		Owner.Ports[Role] := Original
	}
	Retire := Owner.Ports["retire"]
	Owner.Ports["retire"] := Fault
	AssertFalse(Owner.Invalidate(), "arbitrary retirement exceptions remain an explicit cleanup refusal")
	AssertFalse(Owner.Resolve(Key, []), "logical invalidation fences choices while exact cleanup still refuses")
	Owner.Ports["retire"] := Retire
	State["retired"] := false
	AssertFalse(Owner.Invalidate(), "restored native cleanup still requires its actual admitted receipt")
	State["retired"] := true
	AssertTrue(Owner.Invalidate(), "same controlled owner acknowledges only a fresh successful cleanup receipt")
}

_RPP_RawMessage() {
	Good := ProgramProviderMessage('{"providerKey":"1:2","programArguments":["","日本語","\\u0000","line\nnext"]}')
	Assert(Good is Map, "raw page message retains its argument-array source")
	AssertEqual("", Good["arguments"][1], "empty page argument survives")
	AssertEqual("\u0000", Good["arguments"][3], "escaped backslash plus u0000 is an ordinary literal")
	AssertFalse(ProgramProviderMessage('{"providerKey":"1:2\u0000","programArguments":[]}'),
		"native key truncation cannot alias an existing opaque choice")
	AssertFalse(ProgramProviderMessage('{"providerKey":"1:2","programArguments":["a\u0000b"]}'),
		"native argument truncation is rejected by the exact raw scalar span")
	AssertFalse(ProgramProviderMessage('{"providerKey":"1:2","programArguments":[true]}'), "non-string page arguments refuse")
	AssertFalse(ProgramProviderMessage('{"providerKey":"../foreign","programArguments":[]}'), "foreign page keys refuse")
}
Test("program providers: lossless raw page arguments and opaque key rejection", _RPP_RawMessage)

_RPP_PickerRetirement() {
	global _ActPickWeb_ProgramOwner, _ActPickWeb_ProgramPacket, _ActPickWeb_ProgramDebt
	global _ActPickWeb_ProgramCapturing, _ActPickWeb_ProgramRetiring, _ActPickWeb_Confirming
	global _ActPickWeb_OnConfirm, _ActPickWeb_Gui, _ActPickWeb_ResetDone, _ActPickWeb_SessionEpoch
	global _GesturePickedParameter
	AssertEqual(0, _ActPickWeb_Gui, "headless picker controls allocate no native GUI")
	AssertEqual(0, _ActPickWeb_ProgramDebt.Length, "controlled picker starts without foreign discovery debt")
	Saved := Map("owner", _ActPickWeb_ProgramOwner, "packet", _ActPickWeb_ProgramPacket,
		"debt", _ActPickWeb_ProgramDebt, "reset", _ActPickWeb_ResetDone,
		"epoch", _ActPickWeb_SessionEpoch, "callback", _ActPickWeb_OnConfirm, "parameter", _GesturePickedParameter)
	try {
		for Mode in ["false", "throw", "success", "reentry"]
			for Manual in [false, true]
				_RPP_PickerMode(Mode, Manual)
	} finally {
		_ActPickWeb_ProgramOwner := Saved["owner"]
		_ActPickWeb_ProgramPacket := Saved["packet"]
		_ActPickWeb_ProgramDebt := Saved["debt"]
		_ActPickWeb_ResetDone := Saved["reset"]
		_ActPickWeb_SessionEpoch := Saved["epoch"]
		_ActPickWeb_OnConfirm := Saved["callback"]
		_GesturePickedParameter := Saved["parameter"]
		_ActPickWeb_ProgramCapturing := false
		_ActPickWeb_ProgramRetiring := false
		_ActPickWeb_Confirming := false
	}
}
_RPP_PickerMode(Mode, Manual) {
	global _ActPickWeb_ProgramOwner, _ActPickWeb_ProgramDebt, _ActPickWeb_ResetDone
	global _ActPickWeb_OnConfirm, _ActPickWeb_SessionEpoch, _GesturePickedParameter
	State := _RPP_ControlledOwner(), Calls := []
	Retire() {
		global _ActPickWeb_SessionEpoch
		if Mode == "throw"
			throw "private-retirement106"
		if Mode == "reentry" {
			_ActPickWeb_SessionEpoch += 1
			return true
		}
		return Mode == "success"
	}
	State["owner"].Ports["retire"] := Retire
	_ActPickWeb_ProgramOwner := State["owner"]
	_ActPickWeb_ProgramDebt := []
	_ActPickWeb_ResetDone := false
	_ActPickWeb_OnConfirm := Confirm
	Confirm(Id) {
		global _GesturePickedParameter
		Calls.Push(Map("id", Id, "parameter", _GesturePickedParameter))
	}
	_GesturePickedParameter := "sentinel106"
	Scalar := '{"version":1,"executable":"C:\\owned106\\program.exe","arguments":[]}'
	Id := Manual ? "run_program" : "send_text"
	Epoch := _ActPickWeb_SessionEpoch
	Result := _ActPickWeb_Confirm(Id, Manual, Scalar)
	if Mode == "success" {
		AssertTrue(Result, "ordinary confirmation requires actual exact retirement admission")
		AssertEqual(1, Calls.Length, "admitted ordinary confirmation assigns exactly once")
		if Manual {
			Assert(Calls[1]["parameter"] is Map, "manual scalar is offered only inside the admitted assignment")
			AssertEqual(Scalar, Calls[1]["parameter"]["value"], "admitted manual assignment receives exact literal scalar")
		}
	} else {
		AssertFalse(Result, "refusal or session reentry cannot assign an ordinary action")
		AssertEqual(0, Calls.Length, "retirement failure cannot invoke a captured assignment callback")
		AssertEqual("sentinel106", _GesturePickedParameter, "refused manual or ordinary confirmation cannot offer a parameter")
	}
	if Mode != "reentry" {
		AssertTrue(_ActPickWeb_ResetDone, "retirement refusal still tears down the current picker session")
		AssertEqual(Epoch + 1, _ActPickWeb_SessionEpoch, "only that closed session advances its generation")
	}
	if Mode == "false" || Mode == "throw" {
		AssertEqual(1, _ActPickWeb_ProgramDebt.Length, "exact discovery owner remains globally retained after refused confirmation")
		AssertEqual(State["owner"], _ActPickWeb_ProgramDebt[1], "retained picker debt preserves original owner identity")
		State["owner"].Ports["retire"] := (*) => true
		AssertTrue(_ActPickWeb_ProgramRetire(), "fresh retirement ACK closes the same retained owner")
		_ActPickWeb_ResetDone := false
		_ActPickWeb_OnConfirm := (Id) => Calls.Push(Id)
		AssertTrue(_ActPickWeb_Confirm("send_text"), "new session can confirm only after exact debt retirement")
		AssertEqual(1, Calls.Length, "successful retry never resurrects the refused old assignment")
	}
}

Test("program providers: actual picker refusal closes without assigning retained debt", _RPP_PickerRetirement)

; Test resources remain globally reachable if any exact cleanup receipt refuses.
; A directory marker alone is never used as a substitute for native custody.
global _RPP_TestOwners := []

_RPP_TestReserve(Context) {
	global _RPP_TestOwners
	for Pending in _RPP_TestOwners.Clone()
		_RPP_TestRetire(Pending)
	AssertEqual(0, _RPP_TestOwners.Length, "new native fixture cannot displace retained exact cleanup debt")
	Record := Map("context", Context, "native", 0, "owner", 0,
		"process", 0, "job", 0, "protected", 0, "program", false)
	Context["preserve_directory"] := true
	_RPP_TestOwners.Push(Record)
	return Record
}

_RPP_TestRetire(Record) {
	global _RPP_TestOwners
	Native := Record["native"], Owner := Record["owner"]
	Ready := true
	try {
		if Record["protected"] {
			if !DllCall("kernel32\SetHandleInformation", "Ptr", Record["protected"], "UInt", 2, "UInt", 0, "Int")
				Ready := false
			else Record["protected"] := 0
		}
	} catch Any {
		Ready := false
	}
	try {
		if IsObject(Native) && !Native.Retire()
			Ready := false
	} catch Any {
		Ready := false
	}
	try {
		if IsObject(Owner) && !Owner.Invalidate()
			Ready := false
	} catch Any {
		Ready := false
	}
	if Record["program"] || Record["job"] || Record["process"] {
		try {
			if Record["job"] && _SRTOW_ExactJobActiveProcessCount(Record["job"]) != 0
				if !DllCall("kernel32\TerminateJobObject", "Ptr", Record["job"], "UInt", 1, "Int")
					Ready := false
			ProgramActions_Stop(true)
			_RPA_WaitSettled()
			if !ProgramActions_Stop(true)
				Ready := false
		} catch Any {
			Ready := false
		}
	}
	; Do not drop a live group's last duplicate capability or an unsignalled root.
	try {
		if Record["job"] {
			if _SRTOW_ExactJobActiveProcessCount(Record["job"]) != 0
				Ready := false
			else if DllCall("kernel32\CloseHandle", "Ptr", Record["job"], "Int")
				Record["job"] := 0
			else Ready := false
		}
	} catch Any {
		Ready := false
	}
	try {
		if Record["process"] {
			if !_SRTOW_WaitForExactProcessExit(Record["process"])
				Ready := false
			else if DllCall("kernel32\CloseHandle", "Ptr", Record["process"], "Int")
				Record["process"] := 0
			else Ready := false
		}
	} catch Any {
		Ready := false
	}
	if !Ready || Record["job"] || Record["process"] || Record["protected"]
		return false
	for Index, Pending in _RPP_TestOwners
		if Pending == Record {
			_RPP_TestOwners.RemoveAt(Index)
			Record["context"]["preserve_directory"] := false
			return true
		}
	return false
}

_RPP_NativeDebt(Context) {
	global _RPP_TestOwners
	Record := _RPP_TestReserve(Context)
	Native := ProgramProvidersNative((*) => Context["directory"], (*) => "")
	Record["native"] := Native
	AssertTrue(Native.Retire(), "empty actual native inventory begins retired")
	PreviousCritical := Critical("On")
	try {
		Handle := DllCall("kernel32\CreateFileW", "Str", Context["script"], "UInt", 0,
			"UInt", 7, "Ptr", 0, "UInt", 3, "UInt", 0x00200000, "Ptr", 0, "Ptr")
		if Handle != -1
			Native.Debts.Push(Map("kind", "file", "handle", Handle))
	} finally Critical(PreviousCritical)

	try {
		Assert(Handle != -1, "native close-fault fixture acquires an actual exact file handle")
		Record["protected"] := Handle
		Assert(DllCall("kernel32\SetHandleInformation", "Ptr", Handle, "UInt", 2, "UInt", 2, "Int"),
			"the actual held handle is protected from close")
		AssertFalse(Native.Retire(), "actual refused CloseHandle does not clear native capability custody")
		AssertEqual(1, Native.Debts.Length, "exact protected native handle remains retained")
		AssertThrows(Native.List.Bind(Native, Context["directory"], 256), "retained close debt prevents successor enumeration")
		AssertEqual(Handle, Native.Debts[1]["handle"], "refused successor work cannot replace the exact original capability")
		Assert(DllCall("kernel32\SetHandleInformation", "Ptr", Handle, "UInt", 2, "UInt", 0, "Int"),
			"only the exact test-owned protection is removed")
		Record["protected"] := 0
		AssertTrue(Native.Retire(), "later strict native close retires that exact handle")
		AssertEqual(0, Native.Debts.Length, "no numeric handle remains available for accidental reuse")
		PreviousCritical := Critical("On")
		try Record["job"] := DllCall("kernel32\CreateJobObjectW", "Ptr", 0, "Ptr", 0, "Ptr")
		finally Critical(PreviousCritical)
		Assert(Record["job"] != 0, "observer cleanup control acquires an actual empty native Job")
		Assert(DllCall("kernel32\SetHandleInformation", "Ptr", Record["job"], "UInt", 2, "UInt", 2, "Int"),
			"the actual observer HANDLE is protected from close")
		AssertFalse(_RPP_TestRetire(Record), "refused observer close retains the exact test registry owner")
		AssertEqual(1, _RPP_TestOwners.Length, "failed observer cleanup remains globally owned across helper return")
		AssertEqual(Record, _RPP_TestOwners[1], "retained global capability is the original observer record")
		Assert(Record["job"] != 0, "refused close does not discard or replace the exact Job HANDLE")
		AssertThrows(_RPP_TestReserve.Bind(Context), "retained observer close debt prevents another fixture acquisition")
		Assert(DllCall("kernel32\SetHandleInformation", "Ptr", Record["job"], "UInt", 2, "UInt", 0, "Int"),
			"only the exact observer protection is removed before retry")

	} finally {
		if Record["job"]
			DllCall("kernel32\SetHandleInformation", "Ptr", Record["job"], "UInt", 2, "UInt", 0, "Int")
		AssertTrue(_RPP_TestRetire(Record), "exact native test registry must acknowledge physical metadata retirement")
	}
}
Test("program providers: actual protected native metadata close retains exact custody", _RPA_WithFixture.Bind(_RPP_NativeDebt))

_RPP_NativeScript(ProviderId, Context, RequiredCommand := "") {
	global GestureActionParameters, ConfigurationFile, _UserProgramEntries, _SR_TreeOwnedTasks
	global _UserProgramPaused
	Scripts := Context["directory"] . "\scripts", Tools := Context["directory"] . "\outils été 日本"
	DirCreate(Scripts), DirCreate(Tools)
	Gate := Context["directory"] . "\provider gate", Output := Context["output"]
	for Old in [Gate, Output]
		if FileExist(Old)
			FileDelete(Old)
	_RPA_ClearProgramLogs(Context)
	_UserProgramPaused := false
	ProcessObserver := 0, JobObserver := 0, NativeState := 0, Native := 0
	Owner := 0
	Record := _RPP_TestReserve(Context)
	Values := ["", "two words", "日本語", "e" . Chr(0x301), "$(literal106)", "%literal106%", "line`nnext", "quote" . Chr(34), "tick" . Chr(96), "semi" . Chr(59)]
	Expected := "10`n0:`n9:74776F20776F726473`n9:E697A5E69CACE8AA9E`n3:65CC81`n"
		. "13:24286C69746572616C31303629`n12:256C69746572616C31303625`n9:6C696E650A6E657874`n"
		. "6:71756F746522`n5:7469636B60`n5:73656D693B`n"
	; These UTF-8 byte counts and hex strings are authored independently. A wrong
	; provider CLI cannot regenerate the expected native receipt from its result.
	Context["preserve_directory"] := true
	try {
		if ProviderId == "autohotkey" {
			AssertFalse(A_IsCompiled, "native provider fixture requires the genuine interpreted runtime")
			if !FileExist(Tools . "\AutoHotkey64.exe")
				FileCopy(A_AhkPath, Tools . "\AutoHotkey64.exe", false)
			Script := Scripts . "\été 日本 fixture.ahk"
			Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n"
				. 'Result := (A_Args.Length - 2) . Chr(10)`n'
				. 'for Index, Value in A_Args {`n if Index <= 2`n  continue`n'
				. ' BufferBytes := Buffer(StrPut(Value, "UTF-8"))`n'
				. ' Count := StrPut(Value, BufferBytes, "UTF-8") - 1`n Result .= Count . ":"`n'
				. ' loop Count`n  Result .= Format("{:02X}", NumGet(BufferBytes, A_Index - 1, "UChar"))`n'
				. ' Result .= Chr(10)`n}`nFileAppend(Result, A_Args[1], "UTF-8-RAW")`n'
				. 'while !FileExist(A_Args[2])`n Sleep(10)`n'
				. 'FileAppend("private-stdout106", "*")`nFileAppend("private-stderr106", "**")`nExitApp(37)`n'
			Path := Tools
		} else if ProviderId == "python" {
			Script := Scripts . "\été 日本 fixture.py"
			Source := "import os, sys, time`n"
				. "data = [str(len(sys.argv) - 3)]`n"
				. "for value in sys.argv[3:]:`n    raw = value.encode('utf-8')`n    data.append(str(len(raw)) + ':' + raw.hex().upper())`n"
				. "with open(sys.argv[1], 'wb') as f: f.write(('\n'.join(data) + '\n').encode('utf-8'))`n"
				. "while not os.path.exists(sys.argv[2]): time.sleep(0.01)`n"
				. "sys.stdout.write('private-stdout106'); sys.stderr.write('private-stderr106'); sys.exit(37)`n"
			Path := EnvGet("PATH")
		} else {
			Script := Scripts . "\été 日本 fixture.ps1"
			Source := "$utf8 = New-Object System.Text.UTF8Encoding $false`n"
				. "$lines = @([string]($args.Count - 2))`n"
				. "for ($i = 2; $i -lt $args.Count; $i++) {`n"
				. " $raw = $utf8.GetBytes([string]$args[$i])`n"
				. " $lines += [string]$raw.Length + ':' + [BitConverter]::ToString($raw).Replace('-', '')`n}`n"
				. "[IO.File]::WriteAllText($args[0], [string]::Join([char]10, $lines) + [char]10, $utf8)`n"
				. "while (!(Test-Path -LiteralPath $args[1])) { Start-Sleep -Milliseconds 10 }`n"
				. "[Console]::Out.Write('private-stdout106'); [Console]::Error.Write('private-stderr106'); exit 37`n"
			Path := EnvGet("PATH")
		}
		if FileExist(Script)
			FileDelete(Script)
		FileAppend(Source, Script, "UTF-8")
		Native := ProgramProvidersNative((*) => Scripts, (*) => Path)
		Record["native"] := Native
		Ports := Native.Ports()
		if RequiredCommand != "" {
			Select(Commands, Id) {
				return Native.Interpreter(Id == ProviderId ? [RequiredCommand] : Commands, Id)
			}
			Ports["interpreter"] := Select
		}
		Owner := ProgramProviderSession(_RPP_Catalogue(), Ports)
		Record["owner"] := Owner
		Packet := Owner.Discover()
		Assert(Packet is Map, "actual Win32 enumeration produces a bounded public packet")
		Key := ""
		for Choice in Packet["choices"]
			if Choice["provider"] == ProviderId
				Key := Choice["key"]
		Assert(Key != "", "actual installed provider discovers its independently authored fixture script")
		AssertEqual(0, Native.Debts.Length, "discovery leaves no unacknowledged native enumeration or file handles")
		Args := [Output, Gate]
		for Value in Values
			Args.Push(Value)
		Scalar := Owner.Resolve(Key, Args)
		Assert(Scalar is String, "exact still-current native choice lowers to the existing literal scalar")
		Parsed := ProgramParameterParse(Scalar)
		Assert(Parsed is Map, "lowered native provider is accepted by the qualified decoder")
		if ProviderId == "autohotkey"
			AssertEqual(Tools . "\AutoHotkey64.exe", Parsed["executable"], "PATH resolution admits the owned Unicode/spaced actual interpreter")
		GestureActionParameters := Map("gesture__tap_3__run_program", Scalar)
		FileDelete(ConfigurationFile)
		FileAppend('[gestures]`ntap_3 = "run_program"`n[action_parameters]`n"gesture__tap_3__run_program" = '
			. JsonStringLiteral(Scalar) . '`n', ConfigurationFile, "UTF-8")
		Record["program"] := true
		AssertTrue(ProgramActions_Run("gesture__tap_3"), "real provider script starts through the actual canonical action owner")
		Entry := _UserProgramEntries["gesture__tap_3"]
		PreviousCritical := Critical("On")
		try {
			Pid := Entry["handle"].processId()
			for _, State in _SR_TreeOwnedTasks
				if State["Pid"] == Pid {
					NativeState := State
					break
				}
			Assert(NativeState is Map, "fixture retains only the exact live program owner")
			ProcessObserver := _SRTOW_OpenExactProcess(Pid)
			Record["process"] := ProcessObserver
			JobObserver := _SRTOW_DuplicateNativeHandle(NativeState["JobHandle"])
			Record["job"] := JobObserver
		} finally Critical(PreviousCritical)
		Assert(ProcessObserver && JobObserver, "exact process and duplicate Job stay retained before opening the fixture gate")
		AssertFalse(NativeState["CaptureOutput"], "actual provider streams are physically discarded")
		AssertTrue(NativeState["PrivateDiagnostics"], "actual provider diagnostics use closed native status")
		Deadline := A_TickCount + 5000
		while !FileExist(Output) && A_TickCount < Deadline
			Sleep(10)
		Assert(FileExist(Output) != "", "actual independently authored script records its own argv")
		AssertEqual(Expected, FSReadUtf8Exact(Output), "native provider CLI preserves every independent literal UTF-8 byte vector")
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(ProcessObserver), "receipt alone cannot retire the gated actual child")
		FileAppend("release", Gate, "UTF-8-RAW")
		_RPA_WaitSettled()
		Assert(_SRTOW_WaitForExactProcessExit(ProcessObserver), "exact native process HANDLE signals before completion")
		AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(JobObserver), "duplicate actual Job proves original group quiescence")
		AssertEqual(0, NativeState["ProcessHandle"], "actual process capability is retired")
		AssertEqual(0, NativeState["JobHandle"], "actual Job capability is retired")
		Lines := _RPA_ProgramDiagnostics(Context)
		AssertEqual(1, Lines.Length, "real provider nonzero completion emits one closed diagnostic")
		AssertContains(Lines[1], "User program exited with status 37.", "actual provider retains exact nonzero exit status")
		for Line in Context["logs"] {
			AssertFalse(InStr(Line, Script, true), "provider diagnostics never reveal the selected script path")
			AssertFalse(InStr(Line, Parsed["executable"], true), "provider diagnostics never reveal the selected interpreter path")
		}
		AssertTrue(Owner.Invalidate(), "exact native inventory closes without private capability debt")
	} finally {
		CleanupReceipt := _RPP_TestRetire(Record)
		ProcessClosed := Record["process"] == 0
		JobClosed := Record["job"] == 0
		Assert(ProcessClosed, "exact process observer closes")
		Assert(JobClosed, "exact duplicate Job observer closes")
		AssertTrue(CleanupReceipt, "all exact native fixture capabilities retire before directory cleanup")
	}
}
_RPP_NativeVariants(ProviderId, Context) {
	if ProviderId == "autohotkey"
		return _RPP_NativeScript(ProviderId, Context)
	; Every present fallback is independently invoked through actual policy/Job
	; ownership. A preferred tool never qualifies another executable's argv ABI.
	Providers := ProgramProviderCatalogue(_RPP_Catalogue()), Commands := []
	for Provider in Providers
		if Provider["id"] == ProviderId
			Commands := Provider["commands"]["ahk"].Clone()
	Assert(Commands.Length > 0, "native CLI variants come only from the canonical shared catalogue")
	Native := ProgramProvidersNative((*) => Context["directory"] . "\scripts")
	Record := _RPP_TestReserve(Context)
	Record["native"] := Native
	Present := []
	try {
		for Command in Commands {
			Target := Native.Interpreter([Command], ProviderId)
			if Target is Map
				Present.Push(Command)
			else AssertFalse(Target, "missing CLI variant is an explicit native absence receipt")
		}
		Assert(Present.Length > 0, "at least one real installed provider is required; no fake or skipped invocation")
	} finally AssertTrue(_RPP_TestRetire(Record), "variant eligibility handles retire before actual child allocation")
	for Command in Present
		_RPP_NativeScript(ProviderId, Context, Command)
}
for ProviderId in ["autohotkey", "python", "powershell"]
	Test("program providers: real installed " . ProviderId . " script argv and exact Job retirement",
		_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPP_NativeVariants.Bind(ProviderId))))
