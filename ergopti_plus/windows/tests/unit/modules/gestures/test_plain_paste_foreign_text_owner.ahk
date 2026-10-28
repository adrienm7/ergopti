; tests/unit/modules/gestures/test_plain_paste_foreign_text_owner.ahk

; ==============================================================================
; MODULE: Plain Paste Foreign Text Snapshot Tests
; DESCRIPTION:
; Both real clients receive an actual A snapshot before an independent process
; publishes Unicode B and a private format. Existing fixture declarations are
; reused with an explicit text scenario; no production read or write is faked.
; ==============================================================================

#Requires AutoHotkey v2.0

_PPSFT_Replace(Source, Old, New) {
	Result := StrReplace(Source, Old, New, true, &Count)
	AssertEqual(1, Count, "Only the declared test scenario fragment may change: " . Old)
	return Result
}

_PPSFT_ChildSource(Client) {
	global _DriverDir
	Code := _PPSNT_ChildSource(Client)
	Suffix := "#Include " . _DriverDir . "\tests\fixtures\plain_paste_snapshot_owner_body.ahk`n"
	SuffixStart := StrLen(Code) - StrLen(Suffix) + 1
	AssertTrue(SuffixStart > 0, "The canonical builder must contain its complete fixture suffix")
	AssertEqual(Suffix, SubStr(Code, SuffixStart), "The canonical builder must end at its exact fixture boundary")
	Code := SubStr(Code, 1, StrLen(Code) - StrLen(Suffix))
	Code := _PPSFT_Replace(Code, "CB_RestoreAll(Saved) {", "_PPSFT_ActualRestoreAll(Saved) {")
	Library := FileRead(_DriverDir . "\tests\fixtures\plain_paste_snapshot_owner_body.ahk", "UTF-8")
	Entry := "`ntry {`n`t_PPSN_Require(A_Args.Length == 4"
	Position := InStr(Library, Entry, true)
	AssertTrue(Position > 0 && !InStr(Library, Entry, true, Position + 1), "Only the original fixture's final autoexecute entry may be removed")
	Library := SubStr(Library, 1, Position)
	for Name in ["_PPSN_RequestCopy", "_PPSN_Writer"] {
		Body := _DriverExtractFunctionBody(&Library, Name)
		AssertTrue(Body != "", "The replaced test-only scenario helper must have a real body: " . Name)
		Library := _PPSFT_Replace(Library, Body, "")
	}
	Library := _PPSFT_Replace(Library, "CB_SaveAll() {", "_PPSFT_FirstSaveAll() {")
	; These are scenario declarations and business expectations in the existing
	; TEST library. The canonical production projection above remains untouched.
	Library := _PPSFT_Replace(Library, "independent custom-only B é😀 ", "independent text B é😀 ")
	Library := _PPSFT_Replace(Library, ' . " no_unicode=1``n"', ' . " unicode_b=1``n"')
	Library := _PPSFT_Replace(Library, 'B := _PPSN_Sample(_PPSN_Marker(_PPSN.Root))', 'B := _PPSFT_SampleB(_PPSN.Root)')
	Library := _PPSFT_Replace(Library, 'B.RawMatches && !B.Unicode && B.Formats == 1', 'B.RawMatches && B.TextMatches && B.Unicode && B.Formats >= 2')
	Library := _PPSFT_Replace(Library, '"The real public client must cross the authenticated A snapshot and independent custom-only B before its business oracle."',
		'"The real public client must cross the authenticated A snapshot and independent Unicode plus private B before its business oracle."')
	Library := _PPSFT_Replace(Library, '_PPSN_Require(_PPSN.FirstReadEmpty,', '_PPSN_Require(!_PPSN.FirstReadEmpty,')
	Library := _PPSFT_Replace(Library, '"When the client actually reads after the snapshot, its real first read must observe the authenticated non-text B as empty."',
		'"When the client reads after the snapshot, the real first read must observe the authenticated nonempty Unicode B."')
	Library := _PPSFT_Replace(Library, 'Final := _PPSN_Sample(_PPSN_Marker(Root))', 'Final := _PPSFT_SampleB(Root)')
	Library := _PPSFT_Replace(Library, 'Final.RawMatches && Final.Present && !Final.Unicode && Final.Formats == 1',
		'Final.RawMatches && Final.Present && Final.TextMatches && Final.Unicode && Final.Formats >= 2')
	Library := _PPSFT_Replace(Library, '"A newer independent non-text copy must survive the real plain-paste client and its restore with its exact native image, owner and sequence."',
		'"A newer independent Unicode and private-format copy must survive the real client and restore with its exact image, owner and sequence."')
	Library := _PPSFT_Replace(Library, '_PPSN.Completed && _PPSN.WritesAfterSnapshot == 0', '_PPSN.Completed')
	Library := _PPSFT_Replace(Library, '"An empty second read must not request a destructive text setter after a real newer non-text copy."',
		'"The public client must return; emission or refusal is not an acknowledgement by the destination application."')
	Library := _PPSFT_Replace(Library, '&& B.Sequence == _PPSN.WriterSequence`n		&& B.Owner == _PPSN.Writer.Hwnd', '&& _PPSFT_PreservedB(B)')
	Library := _PPSFT_Replace(Library, '&& Final.Owner == _PPSN.Writer.Hwnd && Final.Sequence == _PPSN.WriterSequence', '&& _PPSFT_PreservedB(Final)')
	Library := _PPSFT_Replace(Library, '. " final_unicode="', '. " final_text_match=" . (Final.TextMatches ? 1 : 0) . " final_unicode="')
	Library := StrReplace(Library, "plain-paste-snapshot", "plain-paste-foreign-text", true)
	return Code . Library . "`n#Include " . _DriverDir . "\tests\fixtures\plain_paste_foreign_text_owner_body.ahk`n"
}

_PPSFT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_PPSFT_Case(Client) {
	global _DriverDir, SEND_INSTANT_PASTE_DELAY_MS
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved clipboard child tree cannot be replaced")
	Directory := A_Temp . "\ergopti_plain_foreign_text_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Subject := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Writer := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handles := [], Primary := 0, ExportFailure := 0, Retired := true, AtDeadline := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(SEND_INSTANT_PASTE_DELAY_MS is Integer && SEND_INSTANT_PASTE_DELAY_MS > 0
			&& SEND_INSTANT_PASTE_DELAY_MS <= 1000, "The real deferred restore delay must fit the private child deadline")
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _PPSFT_ChildSource(Client)) != 0)
		_TestPrint("# plain-paste-foreign-text-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\plain_paste_foreign_text_owner_body.ahk")))
		for Spec in [{Role: "writer", State: Writer}, {Role: "subject", State: Subject}] {
			Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
				["/ErrorStdOut=UTF-8", Script, Spec.Role, Directory, Client, String(SEND_INSTANT_PASTE_DELAY_MS)], _PPSFT_Complete.Bind(Spec.State))
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
						_TestPrint("# plain-paste-foreign-text-" . Spec.Role . "-combined " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Both exact native process trees must acknowledge retirement")
	AssertEqual(1, AtDeadline.Subject.Calls)
	AssertEqual("", AtDeadline.Subject.ErrorText, AtDeadline.Subject.Output)
	AssertEqual(0, AtDeadline.Subject.Code, AtDeadline.Subject.Output)
	AssertContains(AtDeadline.Subject.Output, "CLEANUP plain-paste-foreign-text-owner ")
	AssertContains(AtDeadline.Subject.Output, "PASS plain-paste-foreign-text-owner " . Client)
	AssertEqual(1, AtDeadline.Writer.Calls)
	AssertEqual("", AtDeadline.Writer.ErrorText, AtDeadline.Writer.Output)
	AssertEqual(0, AtDeadline.Writer.Code, AtDeadline.Writer.Output)
	AssertContains(AtDeadline.Writer.Output, "PASS plain-paste-foreign-text-writer " . Client)
	if IsObject(ExportFailure)
		throw ExportFailure
}


Test("Plain paste foreign text: gesture preserves a newer Unicode and private-format copy (plain-paste-foreign-text-owner)", _PPSFT_Case.Bind("gesture"))
Test("Plain paste foreign text: shortcut preserves a newer Unicode and private-format copy (plain-paste-foreign-text-owner)", _PPSFT_Case.Bind("shortcut"))
