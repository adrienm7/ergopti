; tests/unit/modules/shortcuts/test_uia_selection_native64_owner.ahk

; ==============================================================================
; MODULE: UIA Selection Native Monotonic Age Probes
; DESCRIPTION: Genuine publication/consumption with one observed age clock port.
; ==============================================================================

_US64_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n"
	Owner := FSReadStrict(_DriverProductionFileForSymbol("GetUIASelection"))
	AssertTrue(RegExMatch(Owner, "m)^global UIA_SELECTION_MAX_AGE_MS := ([0-9]+)[ `t]*$", &Age))
	AssertTrue(Integer(Age[1]) >= 100, "The current control age must be within the genuine configured limit.")
	Code .= "global UIA_SELECTION_MAX_AGE_MS := " . Integer(Age[1]) . "`n"
	for Name in ["_UIA_OnSelectionWorkerTerminal", "_UIA_CurrentSelectionContext", "_UIA_CurrentInputEpoch",
		"KS_GetPhysicalInputEpoch", "GetUIASelection", "UIASW_ContextMatches",
		"UIASW_ConsumeSelectionSnapshot", "WIGetForegroundHwnd", "WIGetFocusedControlToken", "TickElapsed64"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "The native age subject must include its actual production owner: " . Name)
		if Name == "TickElapsed64" {
			Count := 0
			Definition := StrReplace(Definition, "NowTick := A_TickCount", "NowTick := _US64_Clock()", true, &Count)
			AssertEqual(1, Count, "Only the genuine default elapsed-clock read may be rebound.")
		}
		Code .= Definition . "`n"
	}
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\uia_selection_native64_body.ahk")
}

_US64_Completed(State, Code, Output, ErrorText, *) {
	State.Calls += 1
	State.Code := Code
	State.Output := Output
	State.ErrorText := ErrorText
}

_US64_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "A retained native child prevents another owned receiver.")
	Root := A_Temp . "\ergopti_uia_native64_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Primary := 0, Retired := false
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The script directory must be exclusively acquired before writing.")
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _US64_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-owned-uia-native64", Mode], _US64_Completed.Bind(State))
		AssertTrue(Handle.start(), "The owned native selection subject must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# uia-selection-native64 " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, "The native selection age subject must satisfy its business oracle.")
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS uia-selection-native64 " . Mode)
	} catch as Err {
		Primary := Err
	}
	try Retired := !IsObject(Handle) || ((Receipt := Handle.terminate()) is Integer && Receipt == 1)
	catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	try {
		if !Retired && Created
			RetirementDebt := {Handle: Handle, Root: Root}
		else if Retired && Created
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before cleanup.")
}

for _US64_Mode in ["current", "one-era", "two-eras"]
	Test("UIA native selection age: " . _US64_Mode . " (uia-selection-native64)", _US64_Case.Bind(_US64_Mode))
