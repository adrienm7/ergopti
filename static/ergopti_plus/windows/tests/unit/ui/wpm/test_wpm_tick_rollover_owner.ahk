; tests/unit/ui/wpm/test_wpm_tick_rollover_owner.ahk

; ==============================================================================
; MODULE: WPM Tick Rollover Tests
; DESCRIPTION:
; A private child drives the genuine producer and calculator. Only each body's
; single native DWORD clock expression is replaced, never the math or the ring.
; ==============================================================================

#Requires AutoHotkey v2.0

_WPMR_ClockSource(Source, Symbol) {
	Masked := _DriverMaskNonCode(&Source)
	Pattern := "i)(?<![A-Za-z0-9_.])A_TickCount(?![A-Za-z0-9_])"
	AssertTrue(RegExMatch(Masked, Pattern, &Clock) > 0, "The real clock must exist in " . Symbol)
	AssertEqual(0, RegExMatch(Masked, Pattern, , Clock.Pos + Clock.Len), "Exactly one native clock is observed in " . Symbol)
	return SubStr(Source, 1, Clock.Pos - 1) . "_WPMR_Now()" . SubStr(Source, Clock.Pos + Clock.Len)
}

_WPMR_ChildSource() {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("WPMWidget_Calc", _DriverDir)
	AssertTrue(Owner != "", "The genuine WPM calculation must have its unique owner")
	Source := FileRead(Owner, "UTF-8")
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Name in ["WPMWidgetConst", "WPMWidget"] {
		Pattern := "ms)^class " . Name . " \{.*?^\}"
		AssertTrue(RegExMatch(Source, Pattern, &State) > 0, "The actual state class must exist: " . Name)
		AssertEqual(0, RegExMatch(Source, Pattern, , State.Pos + State.Len), "A state class may not be ambiguous: " . Name)
		Code .= State[0] . "`n"
	}
	for Symbol in ["_WPMWidget_TickDelta", "_WPMWidget_NeutralCategory", "WPMWidget_Push", "WPMWidget_Calc"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Every genuine WPM function must be nonempty: " . Symbol)
		if Symbol == "WPMWidget_Push" || Symbol == "WPMWidget_Calc"
			Body := _WPMR_ClockSource(Body, Symbol)
		Code .= Body . "`n"
	}
	return Code . "#Include " . _DriverDir . "\tests\fixtures\wpm_tick_rollover_body.ahk`n"
}

; Initialize the real registry even during a single-case replay, then restore
; the caller's exact caches and logger. No copied timing becomes a SUT default.
_WPMR_Timings() {
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
		return {Window: WindowMs, Minimum: MinimumMs, Digest: Digest}
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

_WPMR_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_WPMR_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired WPM child cannot be replaced")
	Timings := _WPMR_Timings()
	Directory := A_Temp . "\ergopti_wpm_rollover_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _WPMR_ChildSource()) != 0)
		_TestPrint("# wpm-tick-rollover-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath)) . " timings=" . Timings.Digest
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\wpm_tick_rollover_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory, Timings.Window, Timings.Minimum], _WPMR_Complete.Bind(State))
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
					_TestPrint("# wpm-tick-rollover-child " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	; The adapter merges native stdout/stderr; ErrorText is a completion diagnostic.
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS wpm-tick-rollover " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _WPMR_Mode in ["translated-current", "dword-rollover", "expired-and-minimum"]
	Test("WPM clock: " . _WPMR_Mode . " respects admitted event ages (wpm-tick-rollover-owner)", _WPMR_Case.Bind(_WPMR_Mode))
