; tests/unit/adapters/input/test_plain_paste_snapshot_owner.ahk

; ==============================================================================
; MODULE: Plain Paste Snapshot Replacement Tests
; DESCRIPTION:
; Both genuine plain-paste clients acquire a real ClipboardAll snapshot. A
; second native process publishes a non-text clipboard after that acquisition,
; before the real second read. Missing final formats are observable failures.
; ==============================================================================

#Requires AutoHotkey v2.0

_PPSNT_ChildSource(Client) {
	global _DriverDir
	AssertTrue(Client == "gesture" || Client == "shortcut", "Only the two actual client bodies may be selected")
	ClipboardOwner := _DriverProductionFileForSymbol("CB_Write", _DriverDir)
	AssertTrue(ClipboardOwner != "", "The complete genuine clipboard adapter must resolve")
	ClipboardSource := FileRead(ClipboardOwner, "UTF-8")
	for Name in ["Write", "Read", "SaveAll"] {
		Declaration := "CB_" . Name . "(" . (Name == "Write" ? "Text" : "") . ") {"
		Alias := "_PPSN_Actual" . Name . "(" . (Name == "Write" ? "Text" : "") . ") {"
		ClipboardSource := StrReplace(ClipboardSource, Declaration, Alias, true, &Changed)
		AssertEqual(1, Changed, "Only the genuine complete adapter declaration may be observed: " . Name)
	}
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Code .= "LoggerWarn(*) => 0`nLoggerError(*) => 0`nLoggerDebug(*) => 0`nLoggerInfo(*) => 0`n"
	Code .= "global _SendHook := 0`nglobal SEND_INSTANT_PASTE_DELAY_MS := Integer(A_Args[4])`n"
	Names := ["TickElapsed", "TickElapsed64", "_TextSenderNativeFocus", "_SendVerdictSucceeded", "SendFinalResult"]
	Names.Push(Client == "gesture" ? "_GesturePastePlainRestore" : "_PasteWithoutFormattingRestore")
	Names.Push(Client == "gesture" ? "GesturePastePlain" : "PasteWithoutFormatting")
	for Name in Names {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "Every genuine plain-paste dependency must have a real body: " . Name)
		Code .= Body . "`n"
	}
	Body := _DriverFuncBody("_SendFinalResultUnchecked")
	AssertTrue(Body != "", "The complete genuine public client body must resolve")
	Masked := _DriverMaskNonCode(&Body)
	Position := 1, Overlaid := "", Count := 0
	while RegExMatch(Masked, "\bSendInput(?=[ `t]*\()", &Site, Position) {
		Overlaid .= SubStr(Body, Position, Site.Pos - Position) . "_PPSN_Send"
		Position := Site.Pos + Site.Len
		Count += 1
	}
	AssertEqual(2, Count, "Only the two actual native SendFinalResult injection callsites may be observed")
	Code .= ClipboardSource . "`n" . Overlaid . SubStr(Body, Position) . "`n"
	Code .= "_PPSN_Invoke() => " . (Client == "gesture" ? "GesturePastePlain" : "PasteWithoutFormatting") . "()`n"
	return Code . "#Include " . _DriverDir . "\tests\fixtures\plain_paste_snapshot_owner_body.ahk`n"
}

_PPSNT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_PPSNT_Case(Client) {
	global _DriverDir, SEND_INSTANT_PASTE_DELAY_MS
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved clipboard child tree cannot be replaced")
	Directory := A_Temp . "\ergopti_plain_snapshot_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Subject := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Writer := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handles := [], Primary := 0, ExportFailure := 0, Retired := true, AtDeadline := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(SEND_INSTANT_PASTE_DELAY_MS is Integer && SEND_INSTANT_PASTE_DELAY_MS > 0
			&& SEND_INSTANT_PASTE_DELAY_MS <= 1000, "The real deferred restore delay must fit the private child deadline")
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _PPSNT_ChildSource(Client)) != 0)
		_TestPrint("# plain-paste-snapshot-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\plain_paste_snapshot_owner_body.ahk")))
		for Spec in [{Role: "writer", State: Writer}, {Role: "subject", State: Subject}] {
			Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
				["/ErrorStdOut=UTF-8", Script, Spec.Role, Directory, Client, String(SEND_INSTANT_PASTE_DELAY_MS)], _PPSNT_Complete.Bind(Spec.State))
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
						_TestPrint("# plain-paste-snapshot-" . Spec.Role . "-combined " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Both exact native process trees must acknowledge retirement")
	AssertEqual(1, AtDeadline.Subject.Calls)
	AssertEqual("", AtDeadline.Subject.ErrorText, AtDeadline.Subject.Output)
	AssertEqual(0, AtDeadline.Subject.Code, AtDeadline.Subject.Output)
	AssertContains(AtDeadline.Subject.Output, "CLEANUP plain-paste-snapshot-owner ")
	AssertContains(AtDeadline.Subject.Output, "PASS plain-paste-snapshot-owner " . Client)
	AssertEqual(1, AtDeadline.Writer.Calls)
	AssertEqual("", AtDeadline.Writer.ErrorText, AtDeadline.Writer.Output)
	AssertEqual(0, AtDeadline.Writer.Code, AtDeadline.Writer.Output)
	AssertContains(AtDeadline.Writer.Output, "PASS plain-paste-snapshot-writer " . Client)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Plain paste snapshot: gesture preserves a new non-text copy (plain-paste-snapshot-owner)", _PPSNT_Case.Bind("gesture"))
Test("Plain paste snapshot: shortcut preserves a new non-text copy (plain-paste-snapshot-owner)", _PPSNT_Case.Bind("shortcut"))
