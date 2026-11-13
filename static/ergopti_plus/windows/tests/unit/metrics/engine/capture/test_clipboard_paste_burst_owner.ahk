; tests/unit/metrics/engine/capture/test_clipboard_paste_burst_owner.ahk

; Actual clipboard producer/central composition is shared with the protected
; provenance suite. Only its final fixture include is replaced; no copied SUT.
#Requires AutoHotkey v2.0

; Bind only the unique genuine paste producer clock observation. Native MF,
; append, privacy and provenance owners stay unchanged; no 49-day uptime claimed.
_KCPB_BindPasteClock(Source) {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("KL_Clip_OnPaste", _DriverDir)
	Subject := FileRead(Owner, "UTF-8")
	Mask := _DriverMaskNonCode(&Subject)
	Definition := _DriverFindFunctionDefinition(&Mask, "KL_Clip_OnPaste", 1, true)
	AssertTrue(IsObject(Definition))
	Position := Definition.OpenPos, Depth := 0, EndPosition := 0
	while Position <= StrLen(Mask) {
		Character := SubStr(Mask, Position, 1)
		if Character == "{"
			Depth += 1
		else if Character == "}" {
			Depth -= 1
			if Depth == 0 {
				EndPosition := Position
				break
			}
		}
		Position += 1
	}
	AssertTrue(EndPosition > Definition.OpenPos)
	Code := SubStr(Mask, Definition.OpenPos, EndPosition - Definition.OpenPos + 1)
	Pattern := "i)(?<![A-Za-z0-9_.])A_TickCount(?![A-Za-z0-9_])"
	AssertTrue(RegExMatch(Code, Pattern, &Clock) > 0)
	AssertEqual(0, RegExMatch(Code, Pattern, , Clock.Pos + Clock.Len), "the genuine paste owner has exactly one native clock")
	At := Definition.OpenPos + Clock.Pos - 1
	Subject := SubStr(Subject, 1, At - 1) . "_KCPB_PasteNow()" . SubStr(Subject, At + Clock.Len)
	Include := "#Include " . Owner . "`n"
	Source := StrReplace(Source, Include, Subject . "`n", true, &Changed)
	AssertEqual(1, Changed, "only the actual clipboard owner's include may receive the clock-bound source")
	return Source
}

_KCPB_ChildSource(Clocked := false) {
	global _DriverDir
	Source := _KCPO_ChildSource()
	Original := "#Include " . _DriverDir . "\tests\fixtures\clipboard\provenance_owner_body.ahk`n"
	Parts := StrSplit(Source, Original)
	AssertEqual(2, Parts.Length, "The original child must contain exactly one fixture include")
	Source := Parts[1] . "#Include " . _DriverDir . "\tests\fixtures\clipboard\paste_burst_owner_body.ahk`n" . Parts[2]
	return Clocked ? _KCPB_BindPasteClock(Source) : Source
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
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KCPB_ChildSource(InStr(Mode, "clock-") == 1)) != 0)
		_TestPrint("# clipboard-paste-burst-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\clipboard\paste_burst_owner_body.ahk")))
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

for _KCPB_ClockMode in ["clock-ordinary", "clock-one-era", "clock-two-era"]
	Test("Clipboard paste timing: " . _KCPB_ClockMode . " keeps native64 ages (clipboard-paste-native64)",
		_KCPB_Case.Bind(_KCPB_ClockMode))
