; tests/unit/adapters/input/test_text_sender_clipboard_owner.ahk

; ==============================================================================
; MODULE: TextSender Clipboard Ownership Tests
; DESCRIPTION:
; Actual public TextSend, native paste into a private Edit and the complete
; clipboard adapter run in a private subject. A second owned process makes the
; newer native copy after the actual text setter returns. No sequence is forged.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSCOT_ChildSource() {
	global _DriverDir
	ClipboardOwner := _DriverProductionFileForSymbol("CB_Write", _DriverDir)
	SenderOwner := _DriverProductionFileForSymbol("TextSend", _DriverDir)
	EditorOwner := _DriverProductionFileForSymbol("_TextSenderQueueNative", _DriverDir)
	AssertTrue(ClipboardOwner != "" && SenderOwner != "" && EditorOwner != "",
		"All three complete genuine adapter owners must resolve")
	ClipboardSource := FileRead(ClipboardOwner, "UTF-8")
	ClipboardSource := StrReplace(ClipboardSource, "CB_Write(Text) {", "_TSCO_ActualWrite(Text) {", true, &Writes)
	AssertEqual(1, Writes, "Only the genuine text publisher declaration may be decorated")
	SenderSource := FileRead(SenderOwner, "UTF-8")
	Masked := _DriverMaskNonCode(&SenderSource)
	Pattern := "im)^[ `t]*#Include[^`r`n]*"
	AssertTrue(RegExMatch(Masked, Pattern, &Companion) > 0,
		"The complete sender must declare its genuine companion owner")
	AssertEqual(0, RegExMatch(Masked, Pattern, , Companion.Pos + Companion.Len),
		"An additional companion include requires an explicit dependency review")
	AssertEqual(EditorOwner, _DriverProductionFileForSymbol("_TextSenderNativeFocus", _DriverDir),
		"The real native target witness must belong to the genuine companion owner")
	SenderSource := SubStr(SenderSource, 1, Companion.Pos - 1) . "#Include " . EditorOwner
		. SubStr(SenderSource, Companion.Pos + Companion.Len)
	Clock := _DriverFuncBody("TickElapsed")
	AssertTrue(Clock != "", "The actual monotonic clock body must be nonempty")
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Code .= "LoggerWarn(*) => 0`nLoggerError(*) => 0`nLoggerDebug(*) => 0`nLoggerInfo(*) => 0`n"
	Code .= Clock . "`n" . ClipboardSource . "`n" . SenderSource . "`n"
	return Code . "#Include " . _DriverDir . "\tests\fixtures\textsend_clipboard_owner_body.ahk`n"
}

_TSCOT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_TSCOT_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved clipboard child tree cannot be replaced")
	Directory := A_Temp . "\ergopti_textsend_clipboard_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Subject := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Writer := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handles := [], Primary := 0, ExportFailure := 0, Retired := true, AtDeadline := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _TSCOT_ChildSource()) != 0)
		_TestPrint("# textsend-clipboard-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\textsend_clipboard_owner_body.ahk")))
		for Spec in [{Role: "writer", State: Writer}, {Role: "subject", State: Subject}] {
			Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
				["/ErrorStdOut=UTF-8", Script, Spec.Role, Directory, Mode], _TSCOT_Complete.Bind(Spec.State))
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
						_TestPrint("# textsend-clipboard-" . Spec.Role . "-combined " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Both exact native process trees must acknowledge retirement")
	AssertEqual(1, AtDeadline.Subject.Calls)
	AssertEqual("", AtDeadline.Subject.ErrorText, AtDeadline.Subject.Output)
	AssertEqual(0, AtDeadline.Subject.Code, AtDeadline.Subject.Output)
	AssertContains(AtDeadline.Subject.Output, "CLEANUP textsend-clipboard-owner ")
	AssertContains(AtDeadline.Subject.Output, "PASS textsend-clipboard-owner " . Mode)
	AssertEqual(1, AtDeadline.Writer.Calls)
	AssertEqual("", AtDeadline.Writer.ErrorText, AtDeadline.Writer.Output)
	AssertEqual(0, AtDeadline.Writer.Code, AtDeadline.Writer.Output)
	AssertContains(AtDeadline.Writer.Output, "PASS textsend-clipboard-writer " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("TextSend clipboard: current output pastes and restores the original (textsend-clipboard-owner)", _TSCOT_Case.Bind("current"))
Test("TextSend clipboard: newer independent copy survives completion (textsend-clipboard-owner)", _TSCOT_Case.Bind("different-copy"))
Test("TextSend clipboard: same text from a foreign owner survives completion (textsend-clipboard-owner)", _TSCOT_Case.Bind("same-text-copy"))
