; tests/unit/ui/healthcheck/test_healthcheck_native64_uptime.ahk

; ==============================================================================
; MODULE: Healthcheck Native64 Uptime Arithmetic Tests
; DESCRIPTION: Native AHK evaluates the exact uptime assignments extracted from
; three real consumers. Only their clock token is projected onto typed logical
; inputs; no collector, public window or physical long-running session is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCUP_Quote(Text) {
	Escaped := StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34))
	Escaped := StrReplace(StrReplace(Escaped, "`r", Chr(96) . "r"), "`n", Chr(96) . "n")
	return Chr(34) . Escaped . Chr(34)
}

_HCUP_Statement(Name) {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol(Name, _DriverDir)
	Source := FSReadStrict(Owner), Code := _DriverMaskNonCode(&Source)
	AssertEqual(1, _DriverTopLevelDefinitionCount(&Code, Name), "The genuine uptime consumer needs one definition: " . Name)
	Body := _DriverExtractFunctionBody(&Source, Name)
	AssertTrue(Body != "", "The uptime consumer must resolve before inspecting its assignment: " . Name)
	Code := _DriverMaskNonCode(&Body)
	Pattern := "m)^[ `t]*UptimeSec[ `t]*:=[^`r`n]*\b_HealthCheckStartMs\b[^`r`n]*$"
	Position := RegExMatch(Code, Pattern, &StatementMatch)
	AssertTrue(Position > 0 && !RegExMatch(Code, Pattern, , Position + StatementMatch.Len[0]),
		"Exactly one real uptime assignment must read the session origin: " . Name)
	Statement := Trim(SubStr(Body, Position, StatementMatch.Len[0]), " `t`r")
	Code := _DriverMaskNonCode(&Statement)
	Position := RegExMatch(Code, "\bA_TickCount\b", &Clock)
	AssertTrue(Position > 0 && !RegExMatch(Code, "\bA_TickCount\b", , Position + Clock.Len[0]),
		"The arithmetic unit projects exactly one native clock token: " . Name)
	Projected := SubStr(Statement, 1, Position - 1) . "NowTick" . SubStr(Statement, Position + Clock.Len[0])
	Changed := 0
	Inverse := StrReplace(Projected, "NowTick", "A_TickCount", true, &Changed)
	AssertEqual(1, Changed, "The sole clock projection must have one inverse token: " . Name)
	AssertEqual(Statement, Inverse, "No uptime arithmetic may change in the projection: " . Name)
	return {Original: Statement, Projected: Projected}
}

_HCUP_Program(Mode) {
	switch Mode {
		case "ordinary": StartTick := 4294965296, NowTick := 4294971796
		case "long-gap": StartTick := 1000, NowTick := 4294969296
		default: throw ValueError("Unknown uptime arithmetic mode.", -1, Mode)
	}
	AssertTrue(StartTick is Integer && NowTick is Integer && StartTick >= 0 && NowTick >= StartTick,
		"The logical clock must retain its full-width ordered integer operands.")
	Names := ["HealthCheck_Run", "CrashReport_Build", "_CrashReport_CheapSnapshot"]
	Statements := [], Wrappers := "", Calls := "", Exports := ""
	for Index, Name in Names {
		Statement := _HCUP_Statement(Name), Statements.Push(Statement.Original)
		Wrappers .= "_HCUP_Evaluate" . Index . "(StartTick, NowTick) {`n"
			. "_HealthCheckStartMs := StartTick`n" . Statement.Projected . "`nreturn UptimeSec`n}`n"
		Calls .= "Value" . Index . " := _HCUP_Evaluate" . Index . "(" . StartTick . ", " . NowTick . ")`n"
		Exports .= "FileAppend(" . _HCUP_Quote("HCUP_SOURCE " . Name . " " . Statement.Original . "`n") . ', "*", "UTF-8")' . "`n"
			. "FileAppend(" . _HCUP_Quote("HCUP_RESULT " . Name . " ") . " . Type(Value" . Index . ') . " " . String(Value' . Index . ') . Chr(10), "*", "UTF-8")' . "`n"
	}
	Header := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
	Main := "_HCUP_Main() {`nif A_Args.Length != 1 || A_Args[1] != " . _HCUP_Quote(Mode)
		. '`nthrow Error("The exact uptime mode is required.")`n'
		. Calls . Exports . "FileAppend(" . _HCUP_Quote("HCUP_COMPLETE " . Mode . " 3`n") . ', "*", "UTF-8")' . "`n}`n"
	Entry := "try {`n_HCUP_Main()`nExitApp(0)`n} catch as Err {`n"
		. 'FileAppend("HCUP_PREREQUISITE " . Type(Err) . " " . Err.Message . " " . Err.File . ":" . Err.Line . Chr(10), "*", "UTF-8")`n'
		. "ExitApp(95)`n}`n"
	return {Text: Header . Entry . Wrappers . Main, Names: Names, Statements: Statements}
}

_HCUP_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_HCUP_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved uptime child prevents another arithmetic unit")
	Program := _HCUP_Program(Mode)
	Directory := A_Temp . "\ergopti_healthcheck_uptime64_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . Program.Text) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode], _HCUP_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real uptime arithmetic child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact uptime arithmetic child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
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
		if State.Calls == 1 {
			; The tree adapter combines its captures; this is not a separate stderr measurement.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# healthcheck-uptime64-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The arithmetic child must retire before any business verdict")
	AssertEqual(1, AtDeadline.Calls, "The child must settle exactly once before the deadline")
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, "PREREQUISITE: native source arithmetic must evaluate without error. " . AtDeadline.Output)
	AssertContains(AtDeadline.Output, "HCUP_COMPLETE " . Mode . " 3")
	Values := []
	for Index, Name in Program.Names {
		Pattern := "m)^HCUP_RESULT " . Name . " ([A-Za-z]+) (-?[0-9]+)`r?$"
		Position := RegExMatch(AtDeadline.Output, Pattern, &Result)
		AssertTrue(Position > 0 && !RegExMatch(AtDeadline.Output, Pattern, , Position + Result.Len[0]),
			"PREREQUISITE: exactly one result is required for " . Name)
		AssertEqual("Integer", Result[1], "PREREQUISITE: native uptime division must produce an Integer")
		AssertContains(AtDeadline.Output, "HCUP_SOURCE " . Name . " " . Program.Statements[Index])
		Values.Push(Integer(Result[2]))
	}
	if IsObject(ExportFailure)
		throw ExportFailure
	Expected := Mode == "ordinary" ? 6 : 4294968
	for Index, Name in Program.Names
		AssertEqual(Expected, Values[Index], "The real " . Name . " uptime assignment must preserve full native64 elapsed seconds (healthcheck-native64-uptime)")
}

Test("Healthcheck uptime: ordinary elapsed seconds at all three sites (healthcheck-native64-uptime)", _HCUP_Case.Bind("ordinary"))
Test("Healthcheck uptime: elapsed beyond DWORD span at all three sites (healthcheck-native64-uptime)", _HCUP_Case.Bind("long-gap"))
