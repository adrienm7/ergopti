; tests/unit/adapters/input/test_clipboard_clear_receipt_owner.ahk

; ==============================================================================
; MODULE: Capture Clear Receipt Native Ownership Tests
; DESCRIPTION:
; Whole real producers and the unchanged clipboard adapter run in isolated roles.
; Actual independent B copies challenge clear admission and ordinary cancellation.
; Copy/snipping send ports are passive; no physical selection or screen capture.
; ==============================================================================

#Requires AutoHotkey v2.0

_CRCT_ChildSource() {
	global _DriverDir, GET_SELECTION_TIMEOUT_SEC
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Code .= "global GET_SELECTION_TIMEOUT_SEC := " . GET_SELECTION_TIMEOUT_SEC . "`n"
	Seen := Map()
	for Symbol in ["CB_Write", "GetSelectionAsync", "GestureScreenshotRegion", "KS_GetPhysicalInputGeneration", "TickElapsed64"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "Every real capture dependency requires its canonical whole owner: " . Symbol)
		if !Seen.Has(Owner) {
			Code .= "#Include " . Owner . "`n"
			Seen[Owner] := true
		}
	}
	; Reuse canonical fixture-native readers and custody helpers as whole bodies.
	; Its top-level Main, CB_Write decorator and physical send code are excluded.
	Fixture := FSReadStrict(_DriverDir . "\tests\fixtures\sendinstant_clipboard_owner_body.ahk")
	for Name in ["_SICO_Require", "_SICO_Publish", "_SICO_Wait", "_SICO_Identity", "_SICO_Sample",
			"_SICO_AddOriginalFormat", "_SICO_MarkerMatches", "_SICO_Settle", "_SICO_RestoreIncoming"] {
		Body := _DriverExtractFunctionBody(&Fixture, Name)
		AssertTrue(Body != "", "Every reused actual native helper must have a nonempty body: " . Name)
		Code .= Body . "`n"
	}
	return Code . "#Include " . _DriverDir . "\tests\fixtures\clipboard_clear_receipt_owner_body.ahk`n"
}

_CRCT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_CRCT_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved clipboard child tree cannot be replaced")
	AssertEqual(0, CBClipboardOwner.active.Count, "The parent must not lend a live clipboard transaction to independent roles")
	AssertEqual(0, CBClipboardOwner.paste_transaction)
	AssertFalse(CBClipboardOwner.restore_debt is Map, "The parent must settle its own restore debt before native actors start")
	Directory := A_Temp . "\ergopti_clear_receipt_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Subject := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Writer := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handles := [], Primary := 0, ExportFailure := 0, Retired := true, AtDeadline := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _CRCT_ChildSource()) != 0)
		_TestPrint("# clear-receipt-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\clipboard_clear_receipt_owner_body.ahk")))
		for Spec in [{Role: "writer", State: Writer}, {Role: "subject", State: Subject}] {
			Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
				["/ErrorStdOut=UTF-8", Script, Spec.Role, Directory, Mode], _CRCT_Complete.Bind(Spec.State))
			Handles.Push(Handle)
			AssertTrue(Handle.start(), "Each exact owned native process must start")
		}
		Started := A_TickCount
		while (Subject.Calls == 0 || Writer.Calls == 0) && TickElapsed64(Started) < 15000 {
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
						_TestPrint("# clear-receipt-" . Spec.Role . "-combined " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Both exact native process trees must acknowledge retirement")
	AssertEqual(1, AtDeadline.Subject.Calls)
	AssertEqual("", AtDeadline.Subject.ErrorText, AtDeadline.Subject.Output)
	AssertEqual(0, AtDeadline.Subject.Code, AtDeadline.Subject.Output)
	AssertContains(AtDeadline.Subject.Output, "CLEANUP clear-receipt-owner ")
	AssertContains(AtDeadline.Subject.Output, "PASS clear-receipt-owner " . Mode)
	AssertEqual(1, AtDeadline.Writer.Calls)
	AssertEqual("", AtDeadline.Writer.ErrorText, AtDeadline.Writer.Output)
	AssertEqual(0, AtDeadline.Writer.Code, AtDeadline.Writer.Output)
	AssertContains(AtDeadline.Writer.Output, "PASS clear-receipt-writer " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _CRCT_Family in ["selection", "region"]
	for _CRCT_Position in ["before-receipt", "after-receipt", "ordinary"]
		Test("Capture clear receipt: " . _CRCT_Family . " " . _CRCT_Position . " preserves native clipboard ownership (clipboard-clear-receipt-owner)",
			_CRCT_Case.Bind(_CRCT_Family . ":" . _CRCT_Position))
