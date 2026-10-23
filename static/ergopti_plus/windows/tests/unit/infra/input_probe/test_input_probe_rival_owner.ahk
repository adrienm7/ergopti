; tests/unit/infra/input_probe/test_input_probe_rival_owner.ahk

; ==============================================================================
; MODULE: Native Input Probe Rival Lifecycle Tests
; DESCRIPTION:
; Actual repetition/scenario producer and native sends run in an owned Edit.
; A delegated QPC port admits a real pause timer at an eligible pre-send line.
; No public comparison, clipboard mutation or installed keyboard hook is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_IPR_ChildSource() {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("InputProbe_RunSendComparison", _DriverDir)
	AssertTrue(Owner != "", "The genuine complete input probe owner must resolve")
	Body := FileRead(Owner, "UTF-8")
	; Only native emission call tokens are redirected to transparent observers;
	; every observer delegates identical arguments to the unchanged built-in.
	Body := RegExReplace(Body, "\bSendInput\(", "_IPR_SendInput(", &InputCalls)
	Body := RegExReplace(Body, "\bSendEvent\(", "_IPR_SendEvent(", &EventCalls)
	AssertEqual(3, InputCalls, "All current native SendInput call sites must be explicit")
	AssertEqual(4, EventCalls, "All current native SendEvent call sites must be explicit")
	Clock := _DriverFuncBody("HotPath_Now")
	AssertTrue(RegExMatch(Clock, "^HotPath_Now\(") > 0, "The real QPC reader must resolve")
	Clock := RegExReplace(Clock, "^HotPath_Now", "_IPR_NativeClock", &ClockNames)
	AssertEqual(1, ClockNames)
	TickOwner := _DriverProductionFileForSymbol("TickElapsed64", _DriverDir)
	AssertTrue(TickOwner != "")
	return "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. "#Include " . TickOwner . "`n" . Body . "`n" . Clock . "`n"
		. "#Include " . _DriverDir . "\tests\fixtures\input_probe_rival_owner_body.ahk`n"
}

_IPR_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_IPR_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_input_probe_rival_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _IPR_ChildSource()) != 0)
		_TestPrint("# input-probe-rival-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\input_probe_rival_owner_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _IPR_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact input-probe-rival child did not settle within its 15000 ms deadline.")
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
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# input-probe-rival-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS input-probe-rival-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}



Test("Input probe rival: current owned repetition emits its actual native rival (input-probe-rival-owner)", _IPR_Case.Bind("current"))
Test("Input probe rival: native pause after target admission refuses rival emission (input-probe-rival-owner)", _IPR_Case.Bind("pause"))
