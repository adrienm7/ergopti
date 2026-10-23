; tests/unit/adapters/input/test_clipboard_native_open_owner.ahk

; ==============================================================================
; MODULE: Native Clipboard Open Ownership Characterization Tests
; DESCRIPTION:
; Two exact-owned processes measure native nested Open and original caller Close.
; No clipboard data mutation, presumed nested BOOL, fake API or user-copy restore.
; This is native API characterization, not a candidate CAS implementation test.
; ==============================================================================

#Requires AutoHotkey v2.0

_CNOT_Source() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["CryptoSha256Bytes", "FSReadBytesStrict"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The native source needs its genuine helper owner: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	return Chr(0xFEFF) . Code . "#Include " . _DriverDir . "\tests\fixtures\clipboard_native_open_owner_body.ahk`n"
}

_CNOT_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_CNOT_Case(Mode) {
	global _DriverDir, CB_NATIVE_OPEN_TIMEOUT_MS, CB_NATIVE_OPEN_RETRY_MS
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "An earlier native role must retire before another characterization")
	AssertEqual(0, CBClipboardOwner.active.Count, "The characterization refuses another in-process clipboard transaction")
	AssertEqual(0, CBClipboardOwner.paste_transaction)
	AssertFalse(CBClipboardOwner.restore_debt is Map)
	Root := A_Temp . "\ergopti_native_open_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	Roles := [], Primary := 0, ExportFailure := 0, Retired := true, PreviousCritical := Critical("Off")
	try {
		Script := Root . "\roles.ahk", Fixture := _DriverDir . "\tests\fixtures\clipboard_native_open_owner_body.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _CNOT_Source()))
		SourceHash := CryptoSha256Bytes(FSReadBytesStrict(Script)), BodyHash := CryptoSha256Bytes(FSReadBytesStrict(Fixture))
		for Name in ["observer", "subject"] {
			State := {Name: Name, Calls: 0, Code: -1, Output: "", ErrorText: "", Handle: 0, Pid: 0, Retired: false}
			Roles.Push(State)
			State.Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
				["/ErrorStdOut=UTF-8", Script, Mode, Name, Root, String(CB_NATIVE_OPEN_TIMEOUT_MS),
					String(CB_NATIVE_OPEN_RETRY_MS), SourceHash, BodyHash], _CNOT_Done.Bind(State))
			AssertTrue(State.Handle.start(), "The exact native " . Name . " role must start")
			State.Pid := State.Handle.processId()
		}
		AssertTrue(Roles[1].Pid > 0 && Roles[2].Pid > 0 && Roles[1].Pid != Roles[2].Pid,
			"The observer must be a genuinely different process")
		Started := A_TickCount
		while (Roles[1].Calls == 0 || Roles[2].Calls == 0) && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		for State in Roles
			State.AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if Roles[1].Calls == 0 || Roles[2].Calls == 0
			Primary := Error("Both exact native clipboard roles must settle within 15000 ms.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		for State in Roles {
			try {
				if IsObject(State.Handle) && State.Calls == 0
					State.Handle.requestTerminate()
				Ack := IsObject(State.Handle) ? State.Handle.terminate() : 1
				State.Retired := Ack is Integer && Ack == 1
				Retired := Retired && State.Retired
			} catch Any as Failure {
				Retired := false
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		if !Retired
			Debt := {Roles: Roles, Root: Root}
		Critical(PreviousCritical)
	}
	try {
		for State in Roles {
			_TestPrint("# native-open terminal role=" . State.Name . " calls=" . State.Calls . " code=" . State.Code
				. " pid=" . State.Pid . " retired=" . State.Retired . " capture_delivered=" . (State.Calls == 1))
			if State.Retired && State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# native-open combined_native_capture " . Line)
			} else
				_TestPrint("# native-open combined_native_capture UNKNOWN")
		}
	} catch Any as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Both exact native process trees must retire")
	AssertEqual(2, Roles.Length)
	for State in Roles {
		AssertEqual(1, State.AtDeadline.Calls, "Exactly one role completion is required: " . State.Output)
		AssertEqual("", State.AtDeadline.ErrorText, "The completion diagnostic must remain empty: " . State.Output)
		AssertEqual(0, State.AtDeadline.Code, "Native clipboard characterization failed: " . State.Output)
		AssertContains(State.AtDeadline.Output, "PASS clipboard-native-open " . Mode . " " . State.Name)
		AssertContains(State.AtDeadline.Output, "NATIVE_OPEN_ROLE mode=" . Mode . " role=" . State.Name . " pid=" . State.Pid)
	}
	if IsObject(ExportFailure)
		throw ExportFailure
	DirDelete(Root, true)
}

for _CNOT_Mode in ["null-to-own", "own-to-own", "foreign-holder"]
	Test("Native clipboard open: " . _CNOT_Mode . " preserves the original caller lease (clipboard-native-open-owner)",
		_CNOT_Case.Bind(_CNOT_Mode))
