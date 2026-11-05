; tests/unit/adapters/crash_report/test_screenshot_layered_native.ahk
; Isolated screenshot of private native surfaces; no clipboard or physical input.
#Requires AutoHotkey v2.0
#Include ../../ui/webview/test_model_browser_close_pause_owner.ahk
_SCLP_Source(Directory) {
	global _DriverDir
	Source := _MBPT_ChildSource(Directory)
	Fixture := "#Include " . _DriverDir . "\tests\fixtures\model_browser_close_pause_owner_body.ahk"
	Position := InStr(Source, Fixture, true, -1)
	AssertTrue(Position > 0)
	Source := SubStr(Source, 1, Position - 1)
	Owner := _DriverProductionFileForSymbol("GestureCaptureRegion", _DriverDir)
	AssertTrue(Owner != "")
	return Source . "#Include " . Owner . "`n#Include " . _DriverDir . "\tests\fixtures\screenshot_layered_native_body.ahk`n"
}
_SCLP_Complete(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}
_SCLP_Case(Mode) {
	static Debt := 0
	AssertFalse(IsObject(Debt), "an unretired private child prevents a successor")
	Directory := A_Temp . "\ergopti_screenshot_layered_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "the component must own its exclusive directory")
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		_MBPT_StageAssets(Directory)
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SCLP_Source(Directory)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Directory], _SCLP_Complete.Bind(State))
		AssertTrue(Handle.start())
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# screenshot-layered-native mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS screenshot-layered-native " . Mode)
	} catch Any as Failure
		Primary := Failure
	try Retired := !IsObject(Handle) || ((Receipt := Handle.terminate()) is Integer && Receipt == 1)
	catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if !Retired
			Debt := {Directory: Directory, Handle: Handle}
		else
			DirDelete(Directory, true)
	} catch Any as Failure {
		Debt := {Directory: Directory, Handle: 0}
		if !IsObject(Primary)
			Primary := Failure
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
}
for _SCLP_Mode in ["ordinary", "layered"]
	Test("Screenshot layered native: " . _SCLP_Mode . " captures the visible owned surface (screenshot-layered-native)", _SCLP_Case.Bind(_SCLP_Mode))
