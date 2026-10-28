; tests/unit/modules/shortcuts/test_shortcut_plain_clipboard_owner.ahk

; ==============================================================================
; MODULE: Shortcut plain paste Native Clipboard Ownership Tests
; DESCRIPTION:
; Actual PasteWithoutFormatting, native paste into a private Edit and the complete
; clipboard adapter run in a private subject. A second owned process makes the
; newer native copy after the actual text setter returns. No sequence is forged.
; ==============================================================================

#Requires AutoHotkey v2.0

_SPCOT_ChildSource() {
	global _DriverDir
	ClipboardOwner := _DriverProductionFileForSymbol("CB_Write", _DriverDir)
	AssertTrue(ClipboardOwner != "", "The complete genuine clipboard adapter must resolve")
	ClipboardSource := FileRead(ClipboardOwner, "UTF-8")
	ClipboardSource := StrReplace(ClipboardSource, "CB_Write(Text) {", "_PPCO_ActualWrite(Text) {", true, &Writes)
	AssertEqual(1, Writes, "Only the genuine publisher declaration may be decorated")
	; Choose the observed boundary from executable source presence, never the result.
	MaskedClipboard := _DriverMaskNonCode(&ClipboardSource)
	NativePublisher := RegExMatch(MaskedClipboard, "m)^_CB_PlainNativeMutationCAS\(Record, Text\) \{") > 0
	if NativePublisher {
		ClipboardSource := StrReplace(ClipboardSource, "_CB_PlainNativeMutationCAS(Record, Text) {",
			"_PPCO_ActualNativeMutationCAS(Record, Text) {", true, &Publishers)
		AssertEqual(1, Publishers, "The genuine native CAS declaration must be decorated exactly once")
	}
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Code .= "LoggerWarn(*) => 0`nLoggerError(*) => 0`nLoggerDebug(*) => 0`nLoggerInfo(*) => 0`n"
	Code .= "global _SendHook := 0`nglobal SEND_INSTANT_PASTE_DELAY_MS := Integer(A_Args[4])`n"
	Code .= "global _PPCO_UsesNativeMutation := " . (NativePublisher ? "true" : "false") . "`n"
	for Name in ["TickElapsed", "TickElapsed64", "_TextSenderNativeFocus", "_SendVerdictSucceeded",
			"SendFinalResult", "_PasteWithoutFormattingRestore", "PasteWithoutFormatting"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "Every genuine plain-paste dependency must have a real body: " . Name)
		Code .= Body . "`n"
	}
	Body := _DriverFuncBody("_SendFinalResultUnchecked")
	AssertTrue(Body != "", "The complete genuine public client body must resolve")
	Masked := _DriverMaskNonCode(&Body)
	Position := 1, Overlaid := "", Count := 0
	while RegExMatch(Masked, "\bSendInput(?=[ `t]*\()", &Site, Position) {
		Overlaid .= SubStr(Body, Position, Site.Pos - Position) . "_PPCO_Send"
		Position := Site.Pos + Site.Len
		Count += 1
	}
	AssertEqual(2, Count, "Only the two actual native SendFinalResult injection callsites may be observed")
	Code .= ClipboardSource . "`n" . Overlaid . SubStr(Body, Position) . "`n"
	Code .= "_PPCO_Invoke() => PasteWithoutFormatting()`n"
	return Code . "#Include " . _DriverDir . "\tests\fixtures\plain_paste_clipboard_owner_body.ahk`n"
}

_SPCOT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_SPCOT_Case(Mode) {
	global _DriverDir, SEND_INSTANT_PASTE_DELAY_MS
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved clipboard child tree cannot be replaced")
	Directory := A_Temp . "\ergopti_shortcut_plain_clipboard_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Subject := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Writer := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handles := [], Primary := 0, ExportFailure := 0, Retired := true, AtDeadline := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(SEND_INSTANT_PASTE_DELAY_MS is Integer && SEND_INSTANT_PASTE_DELAY_MS > 0
			&& SEND_INSTANT_PASTE_DELAY_MS <= 1000, "The real deferred restore delay must fit the private child deadline")
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SPCOT_ChildSource()) != 0)
		_TestPrint("# plain-paste-clipboard-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\plain_paste_clipboard_owner_body.ahk")))
		for Spec in [{Role: "writer", State: Writer}, {Role: "subject", State: Subject}] {
			Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
				["/ErrorStdOut=UTF-8", Script, Spec.Role, Directory, Mode, String(SEND_INSTANT_PASTE_DELAY_MS), "shortcut"], _SPCOT_Complete.Bind(Spec.State))
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
						_TestPrint("# plain-paste-clipboard-" . Spec.Role . "-combined " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Both exact native process trees must acknowledge retirement")
	AssertEqual(1, AtDeadline.Subject.Calls)
	AssertEqual("", AtDeadline.Subject.ErrorText, AtDeadline.Subject.Output)
	AssertEqual(0, AtDeadline.Subject.Code, AtDeadline.Subject.Output)
	AssertContains(AtDeadline.Subject.Output, "CLEANUP plain-paste-clipboard-owner ")
	AssertContains(AtDeadline.Subject.Output, "PASS plain-paste-clipboard-owner " . Mode)
	AssertEqual(1, AtDeadline.Writer.Calls)
	AssertEqual("", AtDeadline.Writer.ErrorText, AtDeadline.Writer.Output)
	AssertEqual(0, AtDeadline.Writer.Code, AtDeadline.Writer.Output)
	AssertContains(AtDeadline.Writer.Output, "PASS plain-paste-clipboard-writer " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Shortcut plain paste: current paste restores the original formats (shortcut-plain-clipboard-owner)", _SPCOT_Case.Bind("current"))
Test("Shortcut plain paste: newer independent copy survives completion (shortcut-plain-clipboard-owner)", _SPCOT_Case.Bind("different-copy"))
Test("Shortcut plain paste: same text from a foreign owner survives completion (shortcut-plain-clipboard-owner)", _SPCOT_Case.Bind("same-text-copy"))
