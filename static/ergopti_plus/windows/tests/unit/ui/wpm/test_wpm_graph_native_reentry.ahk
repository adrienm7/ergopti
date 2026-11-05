; tests/unit/ui/wpm/test_wpm_graph_native_reentry.ahk
; Isolated native WPM surface ownership; no physical keystrokes or registry writes.
#Requires AutoHotkey v2.0
#Include test_wpm_empty_source_hold_owner.ahk
#Include ../webview/test_model_browser_close_pause_owner.ahk
_WPMG_Source(Directory, Canon) {
	global _DriverDir, _SharedDir
	TimingText := FileRead(_SharedDir . "\modules\timings\constants.toml", "UTF-8")
	AssertTrue(RegExMatch(TimingText, "m)^wpm_widget_update_ms\s*=\s*(\d+)\s*$", &Timing) > 0)
	TickMs := Integer(Timing[1])
	AssertTrue(TickMs > 0, "the real WPM update interval must arm the timer")
	Source := _MBPT_ChildSource(Directory)
	Fixture := "#Include " . _DriverDir . "\tests\fixtures\model_browser_close_pause_owner_body.ahk"
	Position := InStr(Source, Fixture, true, -1)
	AssertTrue(Position > 0, "the actual boot component must expose its final fixture boundary")
	Source := SubStr(Source, 1, Position - 1)
	for Symbol in ["WPMWidget_ToggleGraphConfig", "WPMWidget_BuildGraph", "_ToggleWpmWidgetGraph", "WMHandleOwnedByThisProcess"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "every WPM configuration/window owner must exist")
		Source .= "#Include " . Owner . "`n"
	}
	for Field, Value in Canon.Values {
		Literal := Value is Number ? String(Value) : Chr(34) . Value . Chr(34)
		Source .= "WPMWidgetConst." . Field . " := " . Literal . "`n"
	}
	Source .= "WPMWidgetConst.TICK_MS := " . TickMs . "`n"
	Source .= "#Include " . _DriverDir . "\tests\fixtures\wpm_graph_native_reentry_body.ahk`n"
	return Source
}
_WPMG_Complete(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}
_WPMG_Case(Mode) {
	static Debt := 0
	AssertFalse(IsObject(Debt), "an unretired private child prevents a successor")
	Directory := A_Temp . "\ergopti_wpm_graph_owner_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "the component must own its exclusive directory")
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		_MBPT_StageAssets(Directory)
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _WPMG_Source(Directory, _WPMZ_Canon())))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Directory], _WPMG_Complete.Bind(State))
		AssertTrue(Handle.start())
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# wpm-graph-native mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS wpm-graph-native " . Mode)
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
for _WPMG_Mode in ["current", "reopen"]
	Test("WPM graph native toggle: " . _WPMG_Mode . " owns its actual successor (wpm-graph-native-reentry)", _WPMG_Case.Bind(_WPMG_Mode))
