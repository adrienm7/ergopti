; tests/unit/modules/keymap/test_layout_poll_pause_owner.ahk

; ==============================================================================
; MODULE: Layout Poll Native Pause Tests
; DESCRIPTION:
; Real timer callbacks drive the layout poll and pause inside its real logger.
; The declared lifecycle port records refused requests, never restarts a driver.
; ==============================================================================

#Requires AutoHotkey v2.0

_LPPT_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["LoggerInfo", "WallClockTimestamp", "TickElapsed", "LayoutPollTick"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "Every reached poll/logger/tick owner must resolve: " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\layout_poll_pause_owner_body.ahk`n"
}

_LPPT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_LPPT_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_layout_poll_pause_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _LPPT_ChildSource()) != 0)
		_TestPrint("# layout-poll-pause-owner-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\layout_poll_pause_owner_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _LPPT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact layout-poll-pause-owner child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# layout-poll-pause-owner-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS layout-poll-pause-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Layout poll pause: current confirmed switch requests once (layout-poll-pause-owner)", _LPPT_Case.Bind("current"))
Test("Layout poll pause: late native pause retires the old request (layout-poll-pause-owner)", _LPPT_Case.Bind("late-pause"))
Test("Layout poll pause: paused entry resumes only fresh work (layout-poll-pause-owner)", _LPPT_Case.Bind("paused-entry"))
