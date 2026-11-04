; tests/unit/modules/gestures/test_sticky_and_navigation_actions.ahk

; ==============================================================================
; MODULE: Sticky and Navigation Actions
; DESCRIPTION:
; The catalogue rows Windows gained: Home, End, Page Up and Down, Alt+Escape and
; the fourteen sticky combinations. Catalogue checks stay pure; native capture
; probes confine synthetic keyboard delivery to a child-owned verified Edit.
; ==============================================================================

#Requires AutoHotkey v2.0

_SNA_Names(ActionId) {
	Joined := ""
	for Name in StickyModifierNames(ActionId)
		Joined .= (Joined == "" ? "" : "+") . Name
	return Joined
}

_SNA_Sticky() {
	global GESTURE_ACTIONS, GESTURE_ACTION_CATALOGUE
	Expected := Map("sticky_ctrl", "Ctrl", "sticky_cmd", "Win", "sticky_option", "Alt",
		"sticky_cmd_shift", "Win+Shift", "sticky_cmd_option", "Win+Alt", "sticky_cmd_ctrl", "Win+Ctrl",
		"sticky_option_shift", "Alt+Shift", "sticky_option_ctrl", "Alt+Ctrl", "sticky_ctrl_shift", "Ctrl+Shift",
		"sticky_cmd_option_shift", "Win+Alt+Shift", "sticky_cmd_option_ctrl", "Win+Alt+Ctrl",
		"sticky_cmd_shift_ctrl", "Win+Shift+Ctrl", "sticky_option_shift_ctrl", "Alt+Shift+Ctrl",
		"sticky_hyper", "Ctrl+Alt+Shift+Win")
	AssertEqual(14, Expected.Count)
	for Id, Names in Expected {
		AssertEqual(Names, _SNA_Names(Id), Id . " holds its modifiers")
		AssertTrue(GESTURE_ACTIONS.Has(Id), Id . " has a handler")
		AssertTrue(GESTURE_ACTION_CATALOGUE.Actions.Has(Id), Id . " is offered on Windows")
		Label := _GestureActionLabel(Id)
		AssertFalse(InStr(Label, "Cmd", true) || InStr(Label, "Option", true), Id . " names Windows's keys: " . Label)
		; The label is a template its modifiers fill from the key name table: it
		; used to spell macOS's English names and swap two of them (2026-11-03).
		AssertFalse(InStr(Label, "{1}"), Id . " fills its template: " . Label)
		if (Id != "sticky_hyper") {
			Named := ""
			for Name in StrSplit(Names, "+")
				Named .= (Named == "" ? "" : " + ") . KeyNameLabel(Name)
			AssertTrue(InStr(Label, Named, true) > 0, Id . " names " . Named . ": " . Label)
		}
	}
	Refused := false
	try StickyModifierNames("sticky_fn")
	catch ValueError
		Refused := true
	AssertTrue(Refused, "an unknown modifier is refused, never dropped")
}
Test("sticky actions: the fourteen combinations hold their modifiers (sticky-actions)", _SNA_Sticky)

_SNA_Navigation() {
	global GESTURE_ACTIONS, GESTURE_ACTION_CATALOGUE
	for Id in ["home", "end", "page_up", "page_down", "app_window_previous"] {
		AssertTrue(GESTURE_ACTIONS.Has(Id), Id . " has a handler")
		AssertTrue(GESTURE_ACTION_CATALOGUE.Actions.Has(Id), Id . " is offered on Windows")
	}
}
Test("navigation actions: the emitted rows are offered on Windows (sticky-actions)", _SNA_Navigation)

_SNA_NativeChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Owner := _DriverProductionFileForSymbol("SIHO_StartOwned")
	AssertTrue(Owner != "", "The actual SIHO registry must have a canonical owner.")
	Code .= "#Include " . Owner . "`n"
	for Name in ["StickyModifierNames", "StickyModifier"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "The complete actual sticky owner must exist: " . Name)
		Code .= Body . "`n"
	}
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\sticky_nontext_probe_body.ahk")
}
_SNA_NativeCase(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired native probe prevents another keyboard sender.")
	Root := A_Temp . "\ergopti_sticky_native_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Script := Root . "\subject.ahk"
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SNA_NativeChildSource()))
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}, Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-edit-sendevent", Mode], _SICS_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine sticky child must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "The owned sticky child must settle once.")
		_TestPrint("# sticky-native " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(0, State.Code, "Native sticky capture failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "Native diagnostics may not be hidden.")
		AssertContains(State.Output, "PASS sticky-nontext " . Mode)
	} catch as Err {
		Primary := Err
	}
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Accepted := Handle.terminate()
				Retired := Accepted is Integer && Accepted == 1
				if Retired || TickElapsed(Started) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	try {
		if !Retired
			RetirementDebt := Handle
		else if !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The sender and actual InputHook must physically retire.")
}
for _SNA_NativeMode in ["letter", "enter", "backspace"]
	Test("Sticky native capture: " . _SNA_NativeMode . " suppresses the original before replay (sticky-native-nontext)",
		_SNA_NativeCase.Bind(_SNA_NativeMode))
