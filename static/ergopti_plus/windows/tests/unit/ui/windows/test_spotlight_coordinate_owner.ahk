; tests/unit/ui/windows/test_spotlight_coordinate_owner.ahk

; ==============================================================================
; MODULE: Spotlight Native Coordinate Timer Tests
; DESCRIPTION:
; A private GUI and physical pointer exercise the real Spotlight timer under
; Screen and default Client modes. Only the callback declaration is renamed
; for observation; no pixel, mixed-DPI or monitor-selection claim is made.
; ==============================================================================

#Requires AutoHotkey v2.0

_SPCO_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["GR_CreateWindow", "MCGetPosStrict", "TickExpired"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The coordinate child needs the genuine whole owner of " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	Owner := _DriverProductionFileForSymbol("SpotlightMouseAt", _DriverDir)
	Code := FileRead(Owner, "UTF-8")
	SplitPath(Owner, , &OwnerDirectory)
	; This unique observer projection preserves the actual timer registration.
	; Its callback delegates the entire original body; it is not that body's
	; original source identity. The sole relative include is made absolute.
	Code := StrReplace(Code, "#Include ownership.ahk", "#Include " . OwnerDirectory . "\ownership.ahk", true, &Includes)
	AssertEqual(1, Includes, "The Spotlight whole-owner include must be unique")
	Code := StrReplace(Code, "`n_SpotlightTick() {", "`n_SPCC_ActualTick() {", true, &Definitions)
	AssertEqual(1, Definitions, "The real native timer callback needs one reversible observer rename")
	return Source . Code . "`n#Include " . _DriverDir . "\tests\fixtures\spotlight_coordinate_owner_body.ahk`n"
}

_SPCO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_SPCO_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_spotlight_coordinate_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SPCO_ChildSource()) != 0)
		_TestPrint("# spotlight-coordinate-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\spotlight_coordinate_owner_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _SPCO_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact spotlight-coordinate child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# spotlight-coordinate-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS spotlight-coordinate-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Spotlight coordinates: screen timer retains a stationary overlay (spotlight-coordinate-owner)", _SPCO_Case.Bind("screen-control"))
Test("Spotlight coordinates: default client timer retains a stationary overlay (spotlight-coordinate-owner)", _SPCO_Case.Bind("default-client-offset"))
