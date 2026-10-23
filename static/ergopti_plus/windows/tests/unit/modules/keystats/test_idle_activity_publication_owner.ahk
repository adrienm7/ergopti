; tests/unit/modules/keystats/test_idle_activity_publication_owner.ahk

; ==============================================================================
; MODULE: Idle Publication and New Activity Lifecycle Tests
; DESCRIPTION:
; Real activity and idle producers share the genuine central append/commit path.
; A native timer admits newer activity while an old idle row is being prepared;
; interval pairing and current state, rather than a source spelling, are checked.
; ==============================================================================

#Requires AutoHotkey v2.0

_KIO_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["MF_ShouldFilter", "WallClockTimestamp", "TickElapsed64", "KL_Watchers_IdleTick"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The actual whole owner must resolve: " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	for Definition in ["Keystats", "KLHook"] {
		Symbol := Definition == "Keystats" ? "KL_AppendLog" : "KL_Hook_NoteActivity"
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(RegExMatch(FileRead(Owner, "UTF-8"), "ms)^class " . Definition . " \{.*?^\}", &StateClass) > 0,
			"The child must use the genuine state class " . Definition)
		Source .= StateClass[0] . "`n"
	}
	for Symbol in ["KL_Hook_NoteActivity", "KL_Hook_HasPendingInput", "KL_Hook_AdvanceContextWatermarks",
		"KL_AppendLog", "KL_AssignStableEventId", "KL_AllocEventId", "KL_RecordPrivacyHit"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Every selected real dependency needs a complete body: " . Symbol)
		Source .= Body . "`n"
	}
	Clock := _DriverFuncBody("KL_NowTimestamp")
	AssertTrue(RegExMatch(Clock, "^KL_NowTimestamp\(\)\s*\{") > 0)
	Source .= "_KIO_NativeTimestamp() " . SubStr(Clock, InStr(Clock, "{")) . "`n"
	return Source . "#Include " . _DriverDir . "\tests\fixtures\idle_activity_publication_owner_body.ahk`n"
}

_KIO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KIO_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_idle_owner_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KIO_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KIO_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact idle-activity child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# idle-activity-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS idle-activity-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _KIO_Mode in ["current", "reentrant", "recent"]
	Test("Keystats idle publication: " . _KIO_Mode . " preserves accepted activity (idle-activity-publication-owner)",
		_KIO_Case.Bind(_KIO_Mode))
