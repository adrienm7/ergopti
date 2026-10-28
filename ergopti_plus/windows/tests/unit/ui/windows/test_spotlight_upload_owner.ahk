; tests/unit/ui/windows/test_spotlight_upload_owner.ahk

; ==============================================================================
; MODULE: Spotlight Native Upload Publication Tests
; DESCRIPTION:
; A tree-owned child composes actual HWND creation, GDI+ paint and the bitmap
; adapter. Only the upload outcome is controlled in two refusal modes; the
; positive mode commits a real native frame without claiming pixel correctness.
; ==============================================================================

#Requires AutoHotkey v2.0

_SPBO_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["GR_CreateWindow", "_SpotlightCreateOverlayWindow"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The native upload child needs the unique whole owner of " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\spotlight_upload_owner_body.ahk`n"
}

_SPBO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_SPBO_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_spotlight_upload_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SPBO_ChildSource()) != 0)
		_TestPrint("# spotlight-upload-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\spotlight_upload_owner_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _SPBO_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact spotlight-upload child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# spotlight-upload-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS spotlight-upload-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Spotlight bitmap: current native upload transfers its HWND (spotlight-upload-owner)", _SPBO_Case.Bind("current"))
Test("Spotlight bitmap: refused native upload cannot transfer its HWND (spotlight-upload-owner)", _SPBO_Case.Bind("refused"))
Test("Spotlight bitmap: exceptional native upload retires its HWND (spotlight-upload-owner)", _SPBO_Case.Bind("exception"))
