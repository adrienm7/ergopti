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


/** A nested native BOOL is not a second lease that its caller may close. */
_CNOT_BoundedOpenRefusesBorrowedLease() {
	Saved := CB_SaveAll()
	AssertFalse(Saved is String && Saved == "__CB_SAVE_ERROR__", "the fixture needs the genuine clipboard snapshot")
	Opened := false
	try {
		AssertTrue(CB_OpenClipboardWithin(A_ScriptHwnd), "the original caller must acquire its real lease")
		Opened := true
		Refused := Map("calls", 0)
		AssertFalse(CB_OpenClipboardWithin(A_ScriptHwnd, (*) => Refused["calls"] += 1),
			"the bounded helper cannot grant another caller a Close right over the same HWND lease")
		AssertEqual(1, Refused["calls"], "borrowed refusal still reaches the declared diagnostic callback exactly once")
		AssertEqual(A_ScriptHwnd, DllCall("User32\GetOpenClipboardWindow", "Ptr"),
			"the refused nested acquisition leaves the original caller's native lock intact")
		AssertTrue(DllCall("User32\CloseClipboard", "Int"), "the exact original caller must close its own lease")
		Opened := false
		AssertTrue(CB_OpenClipboardWithin(A_ScriptHwnd), "a fresh acquisition after original release remains available")
		Opened := true
	} finally {
		if Opened
			DllCall("User32\CloseClipboard", "Int")
		AssertTrue(CB_RestoreAll(Saved), "the genuine fixture snapshot must be restored")
	}
}
Test("Native clipboard open: bounded acquisition refuses the original caller's lease (clipboard-borrowed-acquisition)",
	_CNOT_BoundedOpenRefusesBorrowedLease)

/** Bitmap publication must not consume a native lease another stack owns. */
_CNOT_BitmapPreservesBorrowedLease() {
	Saved := CB_SaveAll()
	AssertFalse(Saved is String && Saved == "__CB_SAVE_ERROR__", "the fixture needs the genuine clipboard snapshot")
	Bitmap := DllCall("Gdi32\CreateBitmap", "Int", 1, "Int", 1, "UInt", 1, "UInt", 32, "Ptr", 0, "Ptr")
	AssertTrue(Bitmap != 0, "the fixture must own an actual native bitmap")
	Opened := false, Receipt := 0, Failure := 0
	try {
		AssertTrue(CB_OpenClipboardWithin(A_ScriptHwnd), "the original caller must acquire its real lease")
		Opened := true
		try _CB_PublishLoadedBitmap(&Bitmap, &Receipt, 0)
		catch as Err
			Failure := Err
		AssertEqual(A_ScriptHwnd, DllCall("User32\GetOpenClipboardWindow", "Ptr"),
			"the actual bitmap publisher may not close its caller's borrowed clipboard lease")
		AssertTrue(IsObject(Failure), "a bitmap publication without a new native lease must refuse")
		AssertEqual(0, Receipt, "a borrowed native lease supplies no independent publication receipt")
		AssertTrue(Bitmap != 0, "refusal keeps the original untransferred bitmap reachable")
	} finally {
		if Opened && DllCall("User32\GetOpenClipboardWindow", "Ptr") == A_ScriptHwnd
			DllCall("User32\CloseClipboard", "Int")
		if Bitmap
			DllCall("Gdi32\DeleteObject", "Ptr", Bitmap, "Int")
		AssertTrue(CB_RestoreAll(Saved), "the genuine fixture snapshot must be restored")
	}
}
Test("Native clipboard open: bitmap publication keeps the original caller's lease (clipboard-borrowed-acquisition)",
	_CNOT_BitmapPreservesBorrowedLease)


/** A contention query must leave an earlier caller's native lock untouched. */
_CNOT_BusyProbePreservesBorrowedLease(NullOwner) {
	global CB_NATIVE_OPEN_TIMEOUT_MS, CB_NATIVE_OPEN_RETRY_MS
	Saved := CB_SaveAll()
	AssertFalse(Saved is String && Saved == "__CB_SAVE_ERROR__", "the fixture needs the genuine clipboard snapshot")
	Opened := false
	try {
		; A prior fixture restore wakes Windows clipboard readers. Wait for those
		; foreign readers before acquiring the original lease we are testing.
		Started := A_TickCount
		loop {
			Opened := DllCall("User32\OpenClipboard", "Ptr", NullOwner ? 0 : A_ScriptHwnd, "Int") != 0
			if Opened || TickExpired(Started, CB_NATIVE_OPEN_TIMEOUT_MS)
				break
			Sleep(CB_NATIVE_OPEN_RETRY_MS)
		}
		AssertTrue(Opened, "the original caller must acquire its actual native lease")
		AssertTrue(CB_IsBusy(), "the real contention probe must refuse to borrow the caller's native lease")
		AssertTrue(DllCall("User32\CloseClipboard", "Int"),
			"the original caller must still receive its own native Close acknowledgement")
		Opened := false
		Started := A_TickCount
		loop {
			Idle := !CB_IsBusy()
			if Idle || TickExpired(Started, CB_NATIVE_OPEN_TIMEOUT_MS)
				break
			Sleep(CB_NATIVE_OPEN_RETRY_MS)
		}
		AssertTrue(Idle, "the native contention probe still admits an idle clipboard")
	} finally {
		if Opened
			DllCall("User32\CloseClipboard", "Int")
		AssertTrue(CB_RestoreAll(Saved), "the genuine fixture snapshot must be restored")
	}
}
Test("Native clipboard open: the contention probe preserves a NULL caller lease (clipboard-borrowed-acquisition)",
	_CNOT_BusyProbePreservesBorrowedLease.Bind(true))
Test("Native clipboard open: the contention probe preserves an HWND caller lease (clipboard-borrowed-acquisition)",
	_CNOT_BusyProbePreservesBorrowedLease.Bind(false))
