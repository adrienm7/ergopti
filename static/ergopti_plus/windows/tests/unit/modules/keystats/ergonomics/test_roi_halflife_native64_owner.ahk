; tests/unit/modules/keystats/ergonomics/test_roi_halflife_native64_owner.ahk

; ==============================================================================
; MODULE: ROI Half-Life Native64 Clock Tests
; DESCRIPTION: Genuine ROI producers and central queue publication run in a private
; child. Only their two actual A_TickCount code tokens are controlled; no native
; desktop uptime of 31/46/80 days or clock reversal is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_RHL_ReplaceClock(Body, Name) {
	Code := _DriverMaskNonCode(&Body)
	Position := RegExMatch(Code, "\bA_TickCount\b", &Token)
	AssertTrue(Position > 0 && !RegExMatch(Code, "\bA_TickCount\b", , Position + Token.Len[0]),
		"Exactly one actual clock read must belong to " . Name)
	return SubStr(Body, 1, Position - 1) . "_RHL_Now(" . Chr(34) . Name . Chr(34) . ")"
		. SubStr(Body, Position + Token.Len[0])
}

_RHL_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["MF_ShouldFilter", "WallClockTimestamp", "TickElapsed64"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The child must include the actual owner of " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	StateOwner := _DriverProductionFileForSymbol("KL_AppendLog", _DriverDir)
	StateSource := FileRead(StateOwner, "UTF-8")
	AssertTrue(RegExMatch(StateSource, "ms)^class Keystats \{.*?^\}", &StateClass) > 0)
	Source .= StateClass[0] . "`n"
	RoiOwner := _DriverProductionFileForSymbol("KL_Roi_OnHotstring", _DriverDir)
	RoiSource := FileRead(RoiOwner, "UTF-8")
	for Name in ["KL_Roi_OnHotstring", "KL_Roi_HalflifeTick"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "")
		Changed := 0
		RoiSource := StrReplace(RoiSource, Body, _RHL_ReplaceClock(Body, Name), true, &Changed)
		AssertEqual(1, Changed, "Only the exact genuine producer body may receive its clock port")
	}
	Source .= RoiSource . "`n"
	for Symbol in ["KL_AppendLog", "KL_AssignStableEventId", "KL_AllocEventId", "KL_RecordPrivacyHit",
		"KL_NowTimestamp", "KL_TimerGroupStart", "KL_TimerGroupStop"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "A real selected dependency must resolve: " . Symbol)
		Source .= Body . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\roi_halflife_native64_body.ahk`n"
}

_RHL_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_RHL_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_roi_halflife64_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _RHL_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _RHL_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact roi-halflife64 child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# roi-halflife64-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS roi-halflife64-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _RHL_Mode in ["days31", "days46", "era31", "future"]
	Test("ROI half-life: " . _RHL_Mode . " uses the retained monotonic age (roi-halflife-native64-owner)",
		_RHL_Case.Bind(_RHL_Mode))
