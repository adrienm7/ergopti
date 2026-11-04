; tests/unit/modules/gestures/test_sticky_and_navigation_actions.ahk

; ==============================================================================
; MODULE: Sticky and Navigation Actions
; DESCRIPTION:
; The catalogue rows Windows gained: Home, End, Page Up and Down, Alt+Escape and
; the fourteen sticky combinations. The physical capture of a sticky key needs a
; real key press and is not exercised here.
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
