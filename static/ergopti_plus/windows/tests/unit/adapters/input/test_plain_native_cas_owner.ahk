; tests/unit/adapters/input/test_plain_native_cas_owner.ahk

; ==============================================================================
; MODULE: Plain Native CAS Ownership And Failure Controls
; DESCRIPTION:
; Genuine native publication, lock contention and retained snapshot ownership.
; Exact source-bound failure wrappers are protocol controls, not Win32 failures.
; ==============================================================================

#Requires AutoHotkey v2.0

_PNCOT_ChildSource() {
	global _DriverDir
	Path := _DriverProductionFileForSymbol("CB_WritePlainSnapshot", _DriverDir)
	AssertTrue(Path != "", "The complete native publisher owner must resolve")
	Source := FileRead(Path, "UTF-8")
	Begin := InStr(Source, "_CB_PlainNativeMutationCAS(Record, Text) {")
	End := InStr(Source, "_CB_PlainAuthenticate(Record) {")
	AssertTrue(Begin > 0 && End > Begin, "Both genuine native functions must be present")
	Part := SubStr(Source, Begin, End - Begin)
	Part := StrReplace(Part, "_CB_PlainNativeMutationCAS(Record, Text) {", "_PNCO_ActualMutation(Record, Text) {", true, &Renamed)
	AssertEqual(1, Renamed)
	Part := StrReplace(Part, 'DllCall("User32\SetClipboardData", "UInt", 13,', '_PNCO_SetData("UInt", 13,', true, &Setters)
	AssertEqual(1, Setters, "Only the real prepared native setter may be decorated")
	Part := StrReplace(Part, 'DllCall("User32\CloseClipboard", "Int")', '_PNCO_Close()', true, &Closers)
	AssertEqual(1, Closers, "Only the publisher closing boundary may lose an ACK")
	Source := SubStr(Source, 1, Begin - 1) . Part . SubStr(Source, End)
	Begin := InStr(Source, "_CB_PlainRetryDebt(Record) {")
	End := InStr(Source, "CB_RestorePlainSnapshotEventually(Saved, ExpectedSequence, OwnerToken, Source) {")
	AssertTrue(Begin > 0 && End > Begin, "The genuine typed retry function must resolve before its handoff")
	Part := SubStr(Source, Begin, End - Begin)
	Part := StrReplace(Part, "try SetTimer(CB_RetryRestoreDebt, -CB_RESTORE_RETRY_MS)", "try _PNCO_ArmRetry()", true, &Arms)
	AssertEqual(1, Arms, "Only the typed pending-auth retry arm may be refused")
	Source := SubStr(Source, 1, Begin - 1) . Part . SubStr(Source, End)
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Code .= "LoggerWarn(*) => 0`nLoggerError(*) => 0`nLoggerDebug(*) => 0`nLoggerInfo(*) => 0`n"
	for Name in ["TickElapsed", "TickElapsed64"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "The real native wait dependency must resolve")
		Code .= Body . "`n"
	}
	return Code . Source . "`n#Include " . _DriverDir . "\tests\fixtures\plain_native_cas_owner_body.ahk`n"
}

_PNCOT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_PNCOT_Case(Mode) {
	global _DriverDir, SEND_INSTANT_PASTE_DELAY_MS
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved clipboard child tree cannot be replaced")
	Directory := A_Temp . "\ergopti_plain_native_cas_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Subject := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Writer := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handles := [], Primary := 0, ExportFailure := 0, Retired := true, AtDeadline := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(SEND_INSTANT_PASTE_DELAY_MS is Integer && SEND_INSTANT_PASTE_DELAY_MS > 0
			&& SEND_INSTANT_PASTE_DELAY_MS <= 1000, "The real deferred restore delay must fit the private child deadline")
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _PNCOT_ChildSource()) != 0)
		_TestPrint("# plain-native-cas-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\plain_native_cas_owner_body.ahk")))
		for Spec in [{Role: "writer", State: Writer}, {Role: "subject", State: Subject}] {
			Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
				["/ErrorStdOut=UTF-8", Script, Spec.Role, Directory, Mode, String(SEND_INSTANT_PASTE_DELAY_MS), "gesture"], _PNCOT_Complete.Bind(Spec.State))
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
						_TestPrint("# plain-native-cas-" . Spec.Role . "-combined " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Both exact native process trees must acknowledge retirement")
	AssertEqual(1, AtDeadline.Subject.Calls)
	AssertEqual("", AtDeadline.Subject.ErrorText, AtDeadline.Subject.Output)
	AssertEqual(0, AtDeadline.Subject.Code, AtDeadline.Subject.Output)
	AssertContains(AtDeadline.Subject.Output, "CLEANUP plain-native-cas-owner ")
	AssertContains(AtDeadline.Subject.Output, "PASS plain-native-cas-owner " . Mode)
	AssertEqual(1, AtDeadline.Writer.Calls)
	AssertEqual("", AtDeadline.Writer.ErrorText, AtDeadline.Writer.Output)
	AssertEqual(0, AtDeadline.Writer.Code, AtDeadline.Writer.Output)
	AssertContains(AtDeadline.Writer.Output, "PASS plain-native-cas-writer " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Plain native CAS: zero text preserves its genuine opaque original (plain-native-cas-owner)", _PNCOT_Case.Bind("zero"))
Test("Plain native CAS: a NULL borrower keeps its own native lease (plain-native-cas-owner)", _PNCOT_Case.Bind("borrow-null"))
Test("Plain native CAS: an own HWND borrower keeps its own native lease (plain-native-cas-owner)", _PNCOT_Case.Bind("borrow-own"))
Test("Plain native CAS: a foreign read lock retains the exact pending owner (plain-native-cas-owner)", _PNCOT_Case.Bind("auth-busy"))
Test("Plain native CAS: a newer native copy retires only the old restore right (plain-native-cas-owner)", _PNCOT_Case.Bind("foreign-wins"))
Test("Plain native CAS: a real refused setter retains the missing Close acknowledgement (plain-native-cas-owner)", _PNCOT_Case.Bind("set-null"))
Test("Plain native CAS: a lost Close ACK cannot close a later NULL borrower (plain-native-cas-owner)", _PNCOT_Case.Bind("close-lost"))
Test("Plain native CAS: a refused retry arm retains the same snapshot and token (plain-native-cas-owner)", _PNCOT_Case.Bind("arm-refused"))
