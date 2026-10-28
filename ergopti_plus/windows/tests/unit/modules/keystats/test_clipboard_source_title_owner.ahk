; tests/unit/modules/keystats/test_clipboard_source_title_owner.ahk

; ==============================================================================
; MODULE: Clipboard Source Title Privacy Tests
; DESCRIPTION:
; Reuses the genuine clipboard child composition with a distinct private body.
; Actual MF publication and hook projection deliberately expose their normal
; refresh lag. Only focus/password OS acquisition ports are controlled.
; ==============================================================================

#Requires AutoHotkey v2.0

_KCST_ChildSource() {
	global _DriverDir
	Source := _KCPO_ChildSource()
	OldSuffix := "#Include " . _DriverDir . "\tests\fixtures\clipboard_provenance_owner_body.ahk`n"
	NewSuffix := "#Include " . _DriverDir . "\tests\fixtures\clipboard_source_title_owner_body.ahk`n"
	AssertEqual(OldSuffix, SubStr(Source, StrLen(Source) - StrLen(OldSuffix) + 1),
		"The canonical sibling builder must end in exactly its private fixture include")
	return SubStr(Source, 1, StrLen(Source) - StrLen(OldSuffix)) . NewSuffix
}

_KCST_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KCST_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_clipboard_source_title_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KCST_ChildSource()) != 0)
		_TestPrint("# clipboard-source-title-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\clipboard_source_title_owner_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KCST_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact clipboard-source-title child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# clipboard-source-title-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS clipboard-source-title-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Clipboard source title: private origin is refused after focus advances (clipboard-source-title-owner)", _KCST_Case.Bind("private-title-lag"))
Test("Clipboard source title: excluded app is refused during hook lag (clipboard-source-title-owner)", _KCST_Case.Bind("excluded-app-lag"))
Test("Clipboard source title: live private origin is refused (clipboard-source-title-owner)", _KCST_Case.Bind("private-title-live"))
Test("Clipboard source title: public origin remains safe during hook lag (clipboard-source-title-owner)", _KCST_Case.Bind("public-lag"))
