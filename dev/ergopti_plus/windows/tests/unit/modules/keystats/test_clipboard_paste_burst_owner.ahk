; tests/unit/modules/keystats/test_clipboard_paste_burst_owner.ahk

; Actual clipboard producer/central composition is shared with the protected
; provenance suite. Only its final fixture include is replaced; no copied SUT.
#Requires AutoHotkey v2.0

_KCPB_ChildSource() {
	global _DriverDir
	Source := _KCPO_ChildSource()
	Original := "#Include " . _DriverDir . "\tests\fixtures\clipboard_provenance_owner_body.ahk`n"
	Parts := StrSplit(Source, Original)
	AssertEqual(2, Parts.Length, "The original child must contain exactly one fixture include")
	return Parts[1] . "#Include " . _DriverDir . "\tests\fixtures\clipboard_paste_burst_owner_body.ahk`n" . Parts[2]
}

_KCPB_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KCPB_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_clipboard_burst_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KCPB_ChildSource()) != 0)
		_TestPrint("# clipboard-paste-burst-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\clipboard_paste_burst_owner_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KCPB_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact clipboard-paste-burst child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# clipboard-paste-burst-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS clipboard-paste-burst-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}


Test("Clipboard paste burst: five admitted public pastes reach threshold (clipboard-paste-burst-owner)", _KCPB_Case.Bind("current"))
Test("Clipboard paste burst: a rejected private paste cannot advance a public burst (clipboard-paste-burst-owner)", _KCPB_Case.Bind("private-lag"))
Test("Clipboard paste burst: a paste refused during native pause cannot advance a public burst (clipboard-paste-burst-owner)", _KCPB_Case.Bind("pause-probe"))
