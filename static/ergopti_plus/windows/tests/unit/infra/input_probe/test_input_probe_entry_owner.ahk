; tests/unit/infra/input_probe/test_input_probe_entry_owner.ahk

; ==============================================================================
; MODULE: Input Probe Native Entry Ownership Tests
; DESCRIPTION:
; A genuine public probe runs in a private native child. Exact send primitives
; are observed and delegated only while a private native Edit owns the focus.
; Real Suspend or WM_CLOSE interrupts the SUT's own existing sleep boundary.
; ==============================================================================

#Requires AutoHotkey v2.0

_IPET_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_IPET_Overlay(Source, &Count) {
	Masked := _DriverMaskNonCode(&Source)
	Offsets := [], Position := 1
	while RegExMatch(Masked, "i)(?<![A-Za-z0-9_.])(SendInput|SendEvent)(?=\s*\()", &Token, Position) {
		Offsets.Push({Position: Token.Pos, Width: Token.Len, Name: Token[1]})
		Position := Token.Pos + Token.Len
	}
	AssertTrue(Offsets.Length > 0, "The complete real probe must have a nonempty native send census")
	Result := "", Position := 1, Count := 0
	for Token in Offsets {
		Result .= SubStr(Source, Position, Token.Position - Position) . "_IPES_" . Token.Name
		Position := Token.Position + Token.Width
		Count += 1
	}
	AssertEqual(Offsets.Length, Count, "Only every actual builtin send identifier may be observed")
	return Result . SubStr(Source, Position)
}

_IPET_ChildSource() {
	global _DriverDir
	Code := '#Requires AutoHotkey v2.0' . "`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Seen := Map()
	for Symbol in ["LoggerSetTestSink", "WallClockTimestamp", "TickElapsed"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The real probe requires its genuine whole support owner: " . Symbol)
		AssertFalse(Seen.Has(Owner), "The native support owners must be distinct")
		Seen[Owner] := true
		Code .= "#Include " . Owner . "`n"
	}
	AssertEqual(3, Seen.Count, "The real logger and native clocks must be present")
	Owner := _DriverProductionFileForSymbol("InputProbe_RunHookOrder")
	Source := FSReadStrict(Owner)
	for Symbol in ["InputProbe_RunHookOrder", "_IP_Admission", "_IP_OpenTarget", "_IP_HookInject", "_IP_HookProc"]
		AssertTrue(IsObject(_DriverFindFunctionDefinition(&Source, Symbol)), "The complete native probe route must exist: " . Symbol)
	Observed := _IPET_Overlay(Source, &Count)
	return Code . Observed . "`nglobal _IPES_ObservedSites := " . Count
		. "`n#Include " . _DriverDir . "\tests\fixtures\input_probe_entry_owner_body.ahk`n"
}

_IPET_Case(Mode) {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier input probe child must retire first")
	Directory := A_Temp . "\ergopti_input_probe_entry_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _IPET_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory, _SharedDir], _IPET_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public input probe child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact input probe child did not settle within 15000 ms; calls at deadline: 0.")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := { Handle: Handle, Directory: Directory }
			Critical(PreviousCritical)
		}
	}
	; The native adapter merges its child's stdout/stderr into Output. ErrorText
	; is a completion diagnostic, not an independently measured stderr stream.
	try {
		if Retired {
			_TestPrint("# input-probe-entry terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# input-probe-entry combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# input-probe-entry completion_error " . Line)
			} else
				_TestPrint("# input-probe-entry combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact input probe child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real input probe violated native input ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS input-probe-entry " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _IPET_Mode in ["current", "pause", "close"]
	Test("Input probe entry: " . _IPET_Mode . " keeps native sends owned (input-probe-entry-owner)",
		_IPET_Case.Bind(_IPET_Mode))
