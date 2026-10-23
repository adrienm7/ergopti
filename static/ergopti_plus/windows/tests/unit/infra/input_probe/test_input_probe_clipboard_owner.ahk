; tests/unit/infra/input_probe/test_input_probe_clipboard_owner.ahk

; ==============================================================================
; MODULE: Input Probe Clipboard Ownership Tests
; DESCRIPTION:
; Actual input-probe hold/release helpers and the complete clipboard adapter
; run in a private subject. An independent owned process performs the newer
; native copy. Only the subject's late sequence observation is delegated.
; ==============================================================================

#Requires AutoHotkey v2.0

_IPCOT_ChildSource() {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("CB_Write", _DriverDir)
	AssertTrue(Owner != "", "The complete genuine clipboard owner must resolve")
	Hold := _DriverFuncBody("_IP_HoldClipboard")
	Release := _DriverFuncBody("_IP_ReleaseClipboard")
	Clock := _DriverFuncBody("TickElapsed")
	AssertTrue(Hold != "" && Release != "" && Clock != "", "All actual helper bodies must be nonempty")
	Masked := _DriverMaskNonCode(&Hold)
	Pattern := "i)(?<![A-Za-z0-9_.])CB_GetSequenceNumber\s*\(\s*\)"
	Present := RegExMatch(Masked, Pattern, &Callsite) > 0
	if Present {
		AssertEqual(0, RegExMatch(Masked, Pattern, , Callsite.Pos + Callsite.Len),
			"The exact late getter observation may not be ambiguous")
		Hold := SubStr(Hold, 1, Callsite.Pos - 1) . "_IPCO_HoldSequence()" . SubStr(Hold, Callsite.Pos + Callsite.Len)
	}
	; Diagnostics are passive; the actual OS clipboard and coordinator are not.
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Code .= "LoggerWarn(*) => 0`nLoggerError(*) => 0`nLoggerDebug(*) => 0`n"
	Code .= "global _IPCO_LATE_GETTER_PRESENT := " . (Present ? 1 : 0) . "`n"
	Code .= "#Include " . Owner . "`n" . Clock . "`n" . Hold . "`n" . Release . "`n"
	return Code . "#Include " . _DriverDir . "\tests\fixtures\input_probe_clipboard_owner_body.ahk`n"
}

_IPCOT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_IPCOT_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved clipboard child tree cannot be replaced")
	Directory := A_Temp . "\ergopti_input_probe_clipboard_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Subject := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Writer := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handles := [], Primary := 0, ExportFailure := 0, Retired := true, AtDeadline := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _IPCOT_ChildSource()) != 0)
		_TestPrint("# input-probe-clipboard-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\input_probe_clipboard_owner_body.ahk")))
		for Spec in [{Role: "writer", State: Writer}, {Role: "subject", State: Subject}] {
			Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
				["/ErrorStdOut=UTF-8", Script, Spec.Role, Directory, Mode], _IPCOT_Complete.Bind(Spec.State))
			Handles.Push(Handle)
			AssertTrue(Handle.start(), "Each exact owned native process must start")
		}
		Started := A_TickCount
		while (Subject.Calls == 0 || Writer.Calls == 0) && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Subject: {Calls: Subject.Calls, Code: Subject.Code, Output: Subject.Output, ErrorText: Subject.ErrorText},
			Writer: {Calls: Writer.Calls, Code: Writer.Code, Output: Writer.Output, ErrorText: Writer.ErrorText}}
		if Subject.Calls == 0 || Writer.Calls == 0
			Primary := Error("The exact clipboard subject and writer did not settle within their 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		if !IsObject(AtDeadline) || AtDeadline.Subject.Calls == 0 || AtDeadline.Writer.Calls == 0 {
			for Handle in Handles {
				try Handle.requestTerminate()
				catch Any as Failure {
					if !IsObject(Primary)
						Primary := Failure
				}
			}
		}
		for Handle in Handles {
			try {
				Receipt := Handle.terminate()
				if !(Receipt is Integer && Receipt == 1)
					Retired := false
			} catch Any as Failure {
				Retired := false
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		try {
			; Failed/unknown cleanup preserves the private protocol evidence.
			if Retired && IsObject(AtDeadline) && AtDeadline.Subject.Calls == 1 && AtDeadline.Subject.Code == 0
				&& AtDeadline.Writer.Calls == 1 && AtDeadline.Writer.Code == 0
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if !Retired
				RetirementDebt := {Handles: Handles, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		for Spec in [{Role: "subject", State: Subject}, {Role: "writer", State: Writer}]
			if Spec.State.Calls == 1
				for Line in StrSplit(Spec.State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# input-probe-clipboard-" . Spec.Role . "-combined " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Both exact native process trees must acknowledge retirement")
	AssertEqual(1, AtDeadline.Subject.Calls)
	AssertEqual("", AtDeadline.Subject.ErrorText, AtDeadline.Subject.Output)
	AssertEqual(0, AtDeadline.Subject.Code, AtDeadline.Subject.Output)
	AssertContains(AtDeadline.Subject.Output, "CLEANUP input-probe-clipboard-owner ")
	AssertContains(AtDeadline.Subject.Output, "PASS input-probe-clipboard-owner " . Mode)
	AssertEqual(1, AtDeadline.Writer.Calls)
	AssertEqual("", AtDeadline.Writer.ErrorText, AtDeadline.Writer.Output)
	AssertEqual(0, AtDeadline.Writer.Code, AtDeadline.Writer.Output)
	AssertContains(AtDeadline.Writer.Output, "PASS input-probe-clipboard-writer " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Input probe clipboard: current payload restores the original (input-probe-clipboard-owner)", _IPCOT_Case.Bind("current"))
Test("Input probe clipboard: newer independent copy survives release (input-probe-clipboard-owner)", _IPCOT_Case.Bind("new-copy-wins"))
