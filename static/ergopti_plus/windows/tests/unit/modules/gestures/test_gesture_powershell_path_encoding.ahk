; tests/unit/modules/gestures/test_gesture_powershell_path_encoding.ahk

; ==============================================================================
; MODULE: Gesture PowerShell Path Encoding Tests
; DESCRIPTION:
; Actual callers write their scripts in a private Unicode TEMP environment.
; Windows PowerShell parses those artifacts without executing any worker code.
; ASCII and explicit-BOM controls distinguish encoding from apostrophe quoting.
; ==============================================================================

#Requires AutoHotkey v2.0

; Generated data is resolved from the real runner's includes, outside the
; authored-code census, with the canonical lexical/definition helpers.
_GPSE_DataOwner(Name) {
	global _DriverDir
	Runner := FSReadStrict(A_ScriptFullPath)
	Code := _DriverMaskNonCode(&Runner)
	Owners := Map()
	Owners.CaseSense := "Off"
	for Line in StrSplit(Code, "`n", "`r") {
		if !RegExMatch(Line, "i)^\s*#Include\s+(\.\.[\\/]_generated[\\/][A-Za-z0-9_.-]+\.ahk)\s*$", &Include)
			continue
		Owner := _DriverDir . "\" . SubStr(StrReplace(Include[1], "/", "\"), 4)
		Text := FSReadStrict(Owner)
		Masked := _DriverMaskNonCode(&Text)
		Count := _DriverTopLevelDefinitionCount(&Masked, Name)
		if Count {
			AssertEqual(1, Count)
			Owners[Owner] := true
		}
	}
	AssertEqual(1, Owners.Count, "one actual included data owner is required")
	for Owner in Owners
		return Owner
}

; Rewrite only one external boundary identifier in code, never strings or the
; writer/builder. Future changes on either real caller or builder remain tested.
_GPSE_Port(Body, Name, Port) {
	Code := _DriverMaskNonCode(&Body)
	Pattern := "(?<![\w.])" . Name . "(?=\s*\()"
	AssertTrue(RegExMatch(Code, Pattern, &Call) > 0)
	AssertEqual(0, RegExMatch(Code, Pattern, , Call.Pos + Call.Len), "one exact native boundary is required")
	return SubStr(Body, 1, Call.Pos - 1) . Port . SubStr(Body, Call.Pos + Call.Len)
}

_GPSE_Source() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Owner := _DriverProductionFileForSymbol("FSWrite", _DriverDir)
	AssertTrue(Owner != "")
	Source .= "#Include " . Owner . "`n#Include " . _GPSE_DataOwner("TouchpadRegistryData") . "`n"
	for Name in ["_Onboarding_StartGestureAuto", "_Onboarding_ReserveGestureAuto", "_Onboarding_AbortGestureAutoReservation",
		"_Onboarding_PollGestureAuto", "_Onboarding_ReadGestureAutoResult", "_Onboarding_BuildGesturePsScript",
		"GestureRestartTouchpadDevice", "_GestureRestartReserve", "_GestureRestartAbortReservation",
		"_GestureRestartPoll", "_GestureRestartReadResult", "_GestureRestartBuildPsScript",
		"TouchpadRegistryPowerShellKey", "TouchpadRegistryPowerShellValues"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "the child needs the entire actual function: " . Name)
		if Name == "_Onboarding_StartGestureAuto" || Name == "GestureRestartTouchpadDevice"
			Body := _GPSE_Port(Body, "Run", "_GPSE_Run")
		if Name == "_Onboarding_ReserveGestureAuto" || Name == "_GestureRestartReserve"
			Body := _GPSE_Port(Body, "SetTimer", "_GPSE_Timer")
		Source .= Body . "`n"
	}
	for Name, Symbol in Map("_OnboardingGestureJob", "_Onboarding_StartGestureAuto",
		"_GestureRestartJob", "GestureRestartTouchpadDevice") {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		Text := FSReadStrict(Owner)
		AssertTrue(RegExMatch(Text, 'm)^global ' . Name . ' := Map\([^\n]*\n[ \t]*"starting", false\)', &Declaration) > 0)
		Source .= Declaration[0] . "`n"
	}
	Owner := _DriverProductionFileForSymbol("_Onboarding_ReadGestureAutoResult", _DriverDir)
	Text := FSReadStrict(Owner)
	AssertTrue(RegExMatch(Text, "m)^global GESTURE_AUTO_SUCCESS_TOKEN :=[^\n]*$", &Declaration) > 0)
	Source .= Declaration[0] . "`n"
	return Chr(0xFEFF) . Source . "#Include " . _DriverDir . "\tests\fixtures\gesture_powershell_path_body.ahk`n"
}

_GPSE_Environment(Directory) {
	Entries := ["ComSpec=" . A_ComSpec, "SystemRoot=" . A_WinDir, "TEMP=" . Directory, "TMP=" . Directory]
	Units := 1
	for Entry in Entries
		Units += StrLen(Entry) + 1
	Block := Buffer(Units * 2, 0), Offset := 0
	for Entry in Entries {
		StrPut(Entry, Block.Ptr + Offset, StrLen(Entry) + 1, "UTF-16")
		Offset += (StrLen(Entry) + 1) * 2
	}
	return Block
}

_GPSE_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_GPSE_Wait(Task, State) {
	AssertTrue(Task.start(), "the exact private native task must start")
	Started := A_TickCount
	while State.Calls == 0 && TickElapsed(Started) < 15000 {
		_SR_TreePoll()
		Sleep(10)
	}
	AssertEqual(1, State.Calls, "the private native task must settle once")
	AssertEqual("", State.ErrorText, State.Output)
	AssertEqual(0, State.Code, State.Output)
}

_GPSE_Hex(Text) {
	Result := ""
	Loop StrLen(Text)
		Result .= Format("{:04X}", NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort"))
	return Result
}

_GPSE_ParserSource() {
	return "param([string]$SourcePath,[string]$ReceiptPath)`n"
		. "$ErrorActionPreference='Stop'`n"
		. "$tokens=$null; $errors=$null`n"
		. "$ast=[System.Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$errors)`n"
		. "$assignments=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'ResultPath'},$true))`n"
		. "if($assignments.Count -ne 1){throw 'Expected one real ResultPath assignment'}`n"
		. "$value=$assignments[0].Right.SafeGetValue()`n"
		. "if($value -isnot [string]){throw 'Expected a literal ResultPath string'}`n"
		. "$hex=-join @($value.ToCharArray()|ForEach-Object{'{0:X4}' -f [int]$_})`n"
		. "$result=[ordered]@{version=$PSVersionTable.PSVersion.ToString();major=$PSVersionTable.PSVersion.Major;minor=$PSVersionTable.PSVersion.Minor;edition=$PSEdition;codepage=[Text.Encoding]::Default.CodePage;errors=@($errors).Count;count=$assignments.Count;hex=$hex}`n"
		. "[IO.File]::WriteAllText($ReceiptPath,($result|ConvertTo-Json -Compress),([Text.UTF8Encoding]::new($false)))`n"
}

_GPSE_Parse(Tasks, PowerShell, Probe, Artifact, Output) {
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Task := ShellRunner_SpawnTreeOwned(PowerShell,
		["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Probe, Artifact, Output],
		_GPSE_Complete.Bind(State))
	Tasks.Push(Task)
	_GPSE_Wait(Task, State)
	Retirement := Task.terminate()
	AssertTrue(Retirement is Integer && Retirement == 1, "the exact parser process tree must retire")
	Result := JsonParse(FSReadStrict(Output))
	AssertEqual(5, Result["major"], "the oracle must be Windows PowerShell 5.1")
	AssertEqual(1, Result["minor"])
	AssertEqual("Desktop", Result["edition"])
	AssertEqual(0, Result["errors"], "the artifact must parse without source errors")
	AssertEqual(1, Result["count"])
	return Result
}

_GPSE_Case(Caller, Unicode) {
	static Sequence := 0, RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "unretired private native tasks forbid a successor")
	Root := A_Temp . "\ergopti_gesture_ps_" . A_ScriptHwnd . "_" . ++Sequence
	FSCreateDirectoryExclusiveStrict(Root)
	Directory := Root . (Unicode ? "\O'Brien é😀" : "\O'Brien spaced")
	Tasks := [], Primary := 0, AllRetired := true
	PreviousCritical := Critical("Off")
	try {
		FSCreateDirectoryExclusiveStrict(Directory)
		Subject := Root . "\producer.ahk"
		AssertEqual(1, FSWriteCreateDurable(Subject, _GPSE_Source()))
		State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
		Command := '"' . A_AhkPath . '" /ErrorStdOut=UTF-8 "' . Subject . '" "' . Caller . '" "' . Directory . '"'
		Task := ShellRunner_SpawnTreeOwnedCommand(A_AhkPath, Command, _GPSE_Environment(Directory), Root,
			_GPSE_Complete.Bind(State))
		Tasks.Push(Task)
		_GPSE_Wait(Task, State)
		Retirement := Task.terminate()
		AssertTrue(Retirement is Integer && Retirement == 1, "the artifact producer must physically retire")
		AssertContains(State.Output, "PASS gesture-powershell-producer " . Caller)
		Lines := StrSplit(FSReadStrict(Directory . "\producer.receipt"), "`n", "`r")
		AssertEqual(3, Lines.Length)
		AssertEqual("", Lines[3])
		Artifact := Lines[1], ResultPath := Lines[2]
		AssertTrue(InStr(Artifact, Directory . "\") == 1 && InStr(ResultPath, Directory . "\") == 1)
		Original := FSReadBytesStrict(Artifact)
		Probe := Root . "\parse-only.ps1"
		AssertEqual(1, FSWriteCreateDurable(Probe, _GPSE_ParserSource()))
		PowerShell := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
		if Unicode {
			Control := Root . "\bom-control.ps1"
			Handle := FileOpen(Control, "w", "UTF-8-RAW")
			try {
				AssertEqual(3, Handle.RawWrite(_GPSE_Bom()))
				Offset := Original.Size >= 3 && NumGet(Original, 0, "UChar") == 0xEF
					&& NumGet(Original, 1, "UChar") == 0xBB && NumGet(Original, 2, "UChar") == 0xBF ? 3 : 0
				AssertEqual(Original.Size - Offset, Handle.RawWrite(Original.Ptr + Offset, Original.Size - Offset))
			} finally Handle.Close()
			Good := _GPSE_Parse(Tasks, PowerShell, Probe, Control, Root . "\control.json")
			AssertEqual(_GPSE_Hex(ResultPath), Good["hex"], "explicit BOM must preserve the exact Unicode/apostrophe path")
		}
		Observed := _GPSE_Parse(Tasks, PowerShell, Probe, Artifact, Root . "\subject.json")
		After := FSReadBytesStrict(Artifact)
		AssertEqual(Original.Size, After.Size)
		AssertTrue(Original.Size == 0 || DllCall("RtlCompareMemory", "Ptr", Original, "Ptr", After, "UPtr", Original.Size, "UPtr") == Original.Size,
			"AST inspection must leave the real producer's artifact unchanged")
		_TestPrint("# gesture-powershell-path caller=" . Caller . " unicode=" . Unicode . " parser=" . Observed["version"]
			. " codepage=" . Observed["codepage"] . " actual_hex=" . Observed["hex"] . " expected_hex=" . _GPSE_Hex(ResultPath))
		AssertEqual(_GPSE_Hex(ResultPath), Observed["hex"],
			"the real caller's written artifact must preserve its exact result path in Windows PowerShell")
	} catch as Failure {
		Primary := Failure
	} finally {
		for Task in Tasks {
			try Receipt := Task.terminate()
			catch as Failure {
				Receipt := 0
				if !IsObject(Primary)
					Primary := Failure
			}
			if !(Receipt is Integer && Receipt == 1)
				AllRetired := false
		}
		if AllRetired && !IsObject(Primary) {
			try DirDelete(Root, true)
			catch as Failure
				Primary := Failure
		}
		if !AllRetired
			RetirementDebt := {Tasks: Tasks, Directory: Root}
		Critical(PreviousCritical)
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(AllRetired, "every exact native task must retire before PASS")
}

_GPSE_Bom() {
	Bytes := Buffer(3, 0)
	NumPut("UChar", 0xEF, "UChar", 0xBB, "UChar", 0xBF, Bytes)
	return Bytes
}

for _GPSE_Caller in ["onboarding", "restart"] {
	for _GPSE_Unicode in [false, true]
		Test("Gesture PowerShell path: " . _GPSE_Caller . " unicode=" . _GPSE_Unicode
			. " preserves the produced result identity (gesture-powershell-path-encoding)", _GPSE_Case.Bind(_GPSE_Caller, _GPSE_Unicode))
}
