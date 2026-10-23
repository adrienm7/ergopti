; tests/unit/modules/keystats/test_switch_destination_privacy_owner.ahk

; ==============================================================================
; MODULE: Captured Switch Destination Privacy Tests
; DESCRIPTION:
; Genuine focus refresh and context projection retain the captured destination
; while a native timer admits another public focus. Full central appends, rather
; than recording stubs, decide which switch payloads reach the shared queue.
; ==============================================================================

#Requires AutoHotkey v2.0

_KSD_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["MF_ShouldFilter", "HotPath_Now", "WICaptureBoundedFocusSnapshot", "WallClockTimestamp", "TickElapsed64"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "Every actual whole owner must resolve: " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	for Definition in ["Keystats", "KLHook", "KLHookConst"] {
		Symbol := Definition == "Keystats" ? "KL_AppendLog" : "KL_Hook_RefreshContext"
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(RegExMatch(FileRead(Owner, "UTF-8"), "ms)^class " . Definition . " \{.*?^\}", &StateClass) > 0,
			"The child must use the actual state class " . Definition)
		Source .= StateClass[0] . "`n"
	}
	for Symbol in ["KL_Hook_RefreshContext", "KL_Hook_AdvanceContextWatermarks", "KL_LogAppSwitch",
		"KL_LogWindowSwitch", "KL_AppendLog", "KL_AssignStableEventId", "KL_AllocEventId",
		"KL_RecordPrivacyHit", "KL_NowTimestamp"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Every reached production function needs its real body: " . Symbol)
		if Symbol == "KL_LogAppSwitch" || Symbol == "KL_LogWindowSwitch"
			Body := RegExReplace(Body, "^" . Symbol, "_KSD_Native" . SubStr(Symbol, 4))
		Source .= Body . "`n"
	}
	Flush := _DriverFuncBody("KL_FlushBuffer")
	AssertTrue(RegExMatch(Flush, "^KL_FlushBuffer\(") > 0)
	Source .= RegExReplace(Flush, "^KL_FlushBuffer", "_KSD_NativeFlush") . "`n"
	return Source . "#Include " . _DriverDir . "\tests\fixtures\switch_destination_privacy_owner_body.ahk`n"
}

_KSD_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KSD_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_switch_destination_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KSD_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact switch-destination child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# switch-destination-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS switch-destination-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _KSD_Mode in ["app-third", "title-third", "app-live", "title-live", "outgoing-private", "public"]
	Test("Keystats switch destinations: " . _KSD_Mode . " respects captured privacy (switch-destination-privacy-owner)",
		_KSD_Case.Bind(_KSD_Mode))
