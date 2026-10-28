; tests/unit/ui/wpm/test_wpm_empty_source_hold_owner.ahk

; ==============================================================================
; MODULE: WPM Empty Source Hold Regression Tests
; DESCRIPTION:
; Real display/calculation/reset/producers run against an actual private compact
; GUI. Exact clock and idle-property observations preserve native-width time.
; ==============================================================================

#Requires AutoHotkey v2.0

_WPMZ_ObserveToken(Source, Token, Replacement) {
	Masked := _DriverMaskNonCode(&Source)
	Pattern := "i)(?<![A-Za-z0-9_.])" . Token . "(?![A-Za-z0-9_])"
	AssertTrue(RegExMatch(Masked, Pattern, &Found) > 0, "The actual observation token must exist: " . Token)
	AssertEqual(0, RegExMatch(Masked, Pattern, , Found.Pos + Found.Len), "Only one exact native token may be observed")
	return SubStr(Source, 1, Found.Pos - 1) . Replacement . SubStr(Source, Found.Pos + Found.Len)
}

; The framework's ordinary body cache deliberately handles block definitions.
; Retain the actual unique arrow line too, without copying its arithmetic.
_WPMZ_DeltaSource(Source) {
	Masked := _DriverMaskNonCode(&Source)
	Pattern := "im)^_WPMWidget_TickDelta\([^`r`n)]*\)[ `t`r`n]*(=>|\{)"
	AssertTrue(RegExMatch(Masked, Pattern, &Definition) > 0, "The real delta definition must exist")
	AssertEqual(0, RegExMatch(Masked, Pattern, , Definition.Pos + Definition.Len), "The real delta definition must be unique")
	if Definition[1] == "{" {
		Body := _DriverExtractFunctionBody(&Source, "_WPMWidget_TickDelta")
		AssertTrue(Body != "", "The actual block definition must be extracted")
		return Body
	}
	LineEnd := InStr(Source, "`n", , Definition.Pos + Definition.Len)
	if !LineEnd
		LineEnd := StrLen(Source) + 1
	AssertTrue(Trim(SubStr(Masked, Definition.Pos + Definition.Len,
		LineEnd - Definition.Pos - Definition.Len), " `t`r") != "", "The real arrow expression must be nonempty")
	return SubStr(Source, Definition.Pos, LineEnd - Definition.Pos)
}

_WPMZ_ChildSource(Canon) {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("WPMWidget_Tick", _DriverDir)
	AssertTrue(Owner != "", "The real WPM display owner must resolve")
	Source := FileRead(Owner, "UTF-8")
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Name in ["WPMWidgetConst", "WPMWidget"] {
		Pattern := "ms)^class " . Name . " \{.*?^\}"
		AssertTrue(RegExMatch(Source, Pattern, &State) > 0, "The actual complete WPM state class must exist")
		AssertEqual(0, RegExMatch(Source, Pattern, , State.Pos + State.Len), "The actual state class is unique")
		Code .= State[0] . "`n"
	}
	for Symbol in ["TickElapsed64", "_WPMWidget_TickDelta", "_WPMWidget_NeutralCategory", "_WPMWidget_ResetRolling",
		"WPMWidget_Push", "WPMWidget_Calc", "WPMWidget_Tick", "_WPMWidget_TooltipUp",
		"_WPMWidget_HideSurface", "WPMWidget_ResolveBgColor", "_WPMWidget_DarkenHex"] {
		Body := Symbol == "_WPMWidget_TickDelta" ? _WPMZ_DeltaSource(Source) : _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Each reached genuine function must exist: " . Symbol)
		for FunctionName, Phase in Map("WPMWidget_Push", "push", "WPMWidget_Calc", "calc", "WPMWidget_Tick", "tick") {
			if Symbol == FunctionName
				Body := _WPMZ_ObserveToken(Body, "A_TickCount", "_WPMZ_Now(" . Chr(34) . Phase . Chr(34) . ")")
		}
		if Symbol == "WPMWidget_Tick" {
			; Both delegates return their actual native properties unchanged. The
			; pair used by the real comparison is a prerequisite, never fabricated.
			Body := _WPMZ_ObserveToken(Body, "A_TimeIdleMouse", "_WPMZ_MouseIdle()")
			Body := _WPMZ_ObserveToken(Body, "A_TimeIdleKeyboard", "_WPMZ_KeyboardIdle()")
		}
		Code .= Body . "`n"
	}
	for Field, Value in Canon.Values {
		AssertTrue(RegExMatch(Field, "^[A-Z_]+$") > 0, "Canon field names must be fixed identifiers")
		if Value is Integer || Value is Float
			Literal := String(Value)
		else {
			AssertTrue(RegExMatch(Value, "^[0-9a-fA-F]{6}$") > 0, "Only authenticated RGB data becomes a string literal")
			Literal := Chr(34) . Value . Chr(34)
		}
		Code .= "WPMWidgetConst." . Field . " := " . Literal . "`n"
	}
	return Code . "#Include " . _DriverDir . "\tests\fixtures\wpm_empty_source_hold_owner_body.ahk`n"
}

_WPMZ_Canon() {
	global _SharedDir, _TimingsCache, _ParseTomlCache, _TomlReadFailures, _TomlUnreadableFiles
	global _LOGGER_FLUSH_ACTIVE, _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED
	global _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_SUB_PATHS, _LOGGER_SUB_PENDING, LOGGER_SUB_FILES
	global _HealthCheckWarnCount, _HealthCheckErrCount, _HealthCheckLastError
	AssertFalse(_LOGGER_FLUSH_ACTIVE, "An active foreign logger flush cannot be parked")
	LoggerState := _TLOG_CaptureLoggerState()
	Saved := {Timings: _TimingsCache, Parse: _ParseTomlCache, Failures: _TomlReadFailures,
		Unreadable: _TomlUnreadableFiles, Sink: _LOGGER_TEST_SINK, Repeat: _LOGGER_REPEAT_ENABLED,
		Clock: _LOGGER_CLOCK_FN, Stamp: _LOGGER_STAMP_FN,
		HadWarn: IsSet(_HealthCheckWarnCount), Warn: IsSet(_HealthCheckWarnCount) ? _HealthCheckWarnCount : 0,
		HadErrors: IsSet(_HealthCheckErrCount), Errors: IsSet(_HealthCheckErrCount) ? _HealthCheckErrCount : 0,
		HadLast: IsSet(_HealthCheckLastError), Last: IsSet(_HealthCheckLastError) ? _HealthCheckLastError : 0}
	Path := _SharedDir . "\modules\timings\constants.toml"
	Raw := FSReadBytesStrict(Path)
	VisualPath := _SharedDir . "\modules\wpm_widget\constants.toml"
	VisualRaw := FSReadBytesStrict(VisualPath)
	try {
		_ResetLogger()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		_LOGGER_SUB_PATHS := Map(), _LOGGER_SUB_PENDING := Map(), LOGGER_SUB_FILES := []
		_ParseTomlCache := Map(), _TomlReadFailures := Map(), _TomlUnreadableFiles := Map()
		TimingsLoadShared(_SharedDir)
		WindowMs := TimingsGet("keystats", "wpm_window_ms")
		MinimumMs := TimingsGet("keystats", "wpm_min_duration_ms")
		AssertTrue(WindowMs is Integer && MinimumMs is Integer && WindowMs > MinimumMs && MinimumMs > 0)
		Digest := CryptoSha256Bytes(Raw)
		AssertEqual(Digest, CryptoSha256Bytes(FSReadBytesStrict(Path)), "The actual shared timing source must remain unchanged")
		Visual := ParseTomlFile(VisualPath)
		AssertTrue(Visual is Map && Visual.Has("colors") && Visual.Has("transparency") && Visual.Has("graph"))
		Values := Map(
			"WINDOW_MS", WindowMs, "WPM_MIN_DURATION_MS", MinimumMs,
			"COLOR_HOLD_MS", TimingsGet("ui", "wpm_color_hold_ms"),
			"IDLE_HIDE_MS", TimingsGet("ui", "wpm_widget_idle_hide_ms"),
			"GRAPH_HISTORY", Integer(Visual["graph"]["history_samples"]),
			"ALPHA_ACTIVE", Integer(Visual["transparency"]["alpha_active"]),
			"UNIT_DARKEN", Float(Visual["compact"]["unit_strip_darken_factor"]))
		for Field, Key in Map("COLOR_BG_AI", "bg_ai", "COLOR_BG_MANUAL", "bg_manual",
			"COLOR_BG_IDLE", "bg_idle", "COLOR_TXT_ACTIVE", "text_active") {
			Color := Visual["colors"][Key]
			AssertTrue(RegExMatch(Color, "^#[0-9a-fA-F]{6}$") > 0, "Actual canon colors must be literal RGB data")
			Values[Field] := SubStr(Color, 2)
		}
		AssertTrue(Values["COLOR_HOLD_MS"] >= 2 && Values["COLOR_HOLD_MS"] < WindowMs
			&& Values["GRAPH_HISTORY"] > 0 && Values["ALPHA_ACTIVE"] > 0 && Values["ALPHA_ACTIVE"] <= 255)
		VisualDigest := CryptoSha256Bytes(VisualRaw)
		AssertEqual(VisualDigest, CryptoSha256Bytes(FSReadBytesStrict(VisualPath)), "The actual visual canon remains unchanged")
		return {Values: Values, Digest: Digest, VisualDigest: VisualDigest}
	} finally {
		_TimingsCache := Saved.Timings, _ParseTomlCache := Saved.Parse
		_TomlReadFailures := Saved.Failures, _TomlUnreadableFiles := Saved.Unreadable
		_TLOG_RestoreLoggerState(LoggerState)
		_LOGGER_TEST_SINK := Saved.Sink, _LOGGER_REPEAT_ENABLED := Saved.Repeat
		_LOGGER_CLOCK_FN := Saved.Clock, _LOGGER_STAMP_FN := Saved.Stamp
		if Saved.HadWarn
			_HealthCheckWarnCount := Saved.Warn
		else
			_HealthCheckWarnCount := unset
		if Saved.HadErrors
			_HealthCheckErrCount := Saved.Errors
		else
			_HealthCheckErrCount := unset
		if Saved.HadLast
			_HealthCheckLastError := Saved.Last
		else
			_HealthCheckLastError := unset
	}
}

_WPMZ_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_WPMZ_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired WPM child cannot be replaced")
	Canon := _WPMZ_Canon()
	Directory := A_Temp . "\ergopti_wpm_source_hold_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _WPMZ_ChildSource(Canon)) != 0)
		_TestPrint("# wpm-empty-source-hold-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath)) . " timings=" . Canon.Digest . " visual=" . Canon.VisualDigest
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\wpm_empty_source_hold_owner_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _WPMZ_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private WPM child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact WPM child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := Receipt is Integer && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# wpm-empty-source-hold-child " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	; The adapter merges native stdout/stderr; ErrorText is a completion diagnostic.
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS wpm-empty-source-hold-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}


for _WPMZ_Mode in ["ordinary-empty", "second-era-empty"]
	Test("WPM display: " . _WPMZ_Mode . " stays hidden until an admitted source (wpm-empty-source-hold-owner)", _WPMZ_Case.Bind(_WPMZ_Mode))
