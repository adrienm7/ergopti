; tests/unit/ui/windows/test_native_file_filter_diagnostics.ahk

; ==============================================================================
; MODULE: Native File Filter Diagnostics
; DESCRIPTION:
; File-filter failure evidence classifies owned action, focus and outcome,
; refuses malformed receipts, and the generated view census keeps exact
; filename visibility.
; ==============================================================================

#Requires AutoHotkey v2.0





/** Records only closed action/focus facts from the exact owned picker. */
_NDT_FileFilterActionSource() {
	return 'PickerFocus := DllCall("GetFocus", "Ptr")' . "`n"
		. 'PickerFocusOwner := !PickerFocus ? "none" : DllCall("IsChild", "Ptr", Hwnd, "Ptr", PickerFocus) ? "owned" : "foreign"' . "`n"
		. 'PickerFocusKind := "none"' . "`n"
		. 'if PickerFocusOwner == "owned" {' . "`n"
		. 'PickerFocusClass := WinGetClass("ahk_id " . PickerFocus)' . "`n"
		. 'PickerFocusKind := PickerFocusClass == "Edit" ? "edit" : PickerFocusClass == "ComboBox" ? "combo" : PickerFocusClass == "Button" ? "button" : "other"' . "`n"
		. '}' . "`n"
		. 'PickerForegroundOwned := DllCall("GetForegroundWindow", "Ptr") == Hwnd ? 1 : 0' . "`n"
		. 'PickerAction := _NFPMode == "selected" ? "open" : "cancel"' . "`n"
		. 'FileAppend(PickerAction . "|foreground=" . PickerForegroundOwned . "|focus=" . PickerFocusOwner . "|kind=" . PickerFocusKind . "|filter=" . ControlGetIndex(PickerTypeCombo), _NFPRoot . "\" . _NFPMode . ".action", "UTF-8-RAW")' . "`n"
}

/** Projects retained owned receipts without exposing a path, caption or item name. */
_NDT_FileFilterFailureFacts(Index, SelectedAction, CancelledAction, Selected, Expected, Cancelled) {
	if !(Index is Integer) || Index < 1 || Index > 5
		throw Error("The owned policy index is invalid")
	Facts := "policy_index=" . Index
	for Mode, Action in Map("selected", SelectedAction, "cancelled", CancelledAction) {
		Pattern := "^" . (Mode == "selected" ? "open" : "cancel")
			. "\|foreground=([01])\|focus=(none|owned|foreign)\|kind=(none|edit|combo|button|other)\|filter=([12])\z"
		if !(Action is String) || StrLen(Action) > 128 || !RegExMatch(Action, Pattern, &Fields)
			throw Error("The owned action receipt is outside its closed schema")
		if Fields[2] != "owned" && Fields[3] != "none"
			throw Error("Foreign focus cannot publish a control kind")
		Facts .= " " . Mode . "_action=" . (Mode == "selected" ? "open" : "cancel")
			. " " . Mode . "_foreground_owned=" . Fields[1] . " " . Mode . "_focus=" . Fields[2]
			. " " . Mode . "_focus_kind=" . Fields[3] . " " . Mode . "_filter_index=" . Fields[4]
	}
	Outcome := Selected == "" ? "empty" : Selected == Expected ? "owned" : "other"
	return Facts . " selected_outcome=" . Outcome
		. " cancelled_outcome=" . (Cancelled == "Array|0" ? "empty_array" : "other")
}

/** Exercises the real closed formatter without a native desktop or process. */
_NDT_FilterFailureFactsProjection() {
	Open := "open|foreground=1|focus=owned|kind=edit|filter=1"
	Cancel := "cancel|foreground=0|focus=foreign|kind=none|filter=1"
	for Result in ["", "C:\owned\selected.txt", "PRIVATE-PATH-CANARY"] {
		Text := _NDT_FileFilterFailureFacts(4, Open, Cancel, Result, "C:\owned\selected.txt", "Array|0")
		AssertContains(Text, "selected_outcome=" . (Result == "" ? "empty" : Result == "C:\owned\selected.txt" ? "owned" : "other"))
		AssertContains(Text, "selected_foreground_owned=1 selected_focus=owned selected_focus_kind=edit selected_filter_index=1")
		AssertContains(Text, "cancelled_foreground_owned=0 cancelled_focus=foreign cancelled_focus_kind=none cancelled_filter_index=1")
		AssertContains(Text, "cancelled_outcome=empty_array")
		AssertFalse(InStr(Text, "PRIVATE") || InStr(Text, "C:\"), "paths and unexpected results are classified, never exported")
	}
}
Test("native file filter: failure evidence classifies owned action focus and outcome", _NDT_FilterFailureFactsProjection)

/** Invalid receipt values refuse rather than enter the technical notice. */
_NDT_FilterFailureFactsRefusal() {
	Cancel := "cancel|foreground=0|focus=none|kind=none|filter=1"
	for Bad in ["open|foreground=1|focus=owned|kind=PRIVATE-TEXT|filter=1",
		"open|foreground=1|focus=foreign|kind=edit|filter=1", "cancel|foreground=1|focus=none|kind=none|filter=1",
		"open|foreground=1|focus=owned|kind=edit|filter=3", "open|foreground=1|focus=owned|kind=edit|filter=1`nPRIVATE", "open|foreground=1|focus=owned|kind=edit|filter=1`n"] {
		Refused := false
		try _NDT_FileFilterFailureFacts(4, Bad, Cancel, "", "owned", "Array|0")
		catch
			Refused := true
		AssertTrue(Refused, "a malformed receipt cannot publish a diagnostic")
	}
}
Test("native file filter: malformed action evidence remains a refusal", _NDT_FilterFailureFactsRefusal)

/** The generated action writer observes only its exact existing owned controls. */
_NDT_FilterFailureFactsSource() {
	Source := _NDT_FileFilterActionSource()
	AssertContains(Source, 'DllCall("IsChild", "Ptr", Hwnd, "Ptr", PickerFocus)')
	AssertContains(Source, 'DllCall("GetForegroundWindow", "Ptr") == Hwnd')
	AssertContains(Source, 'ControlGetIndex(PickerTypeCombo)')
	AssertContains(Source, '_NFPRoot . "\" . _NFPMode . ".action"')
	AssertFalse(InStr(Source, "WinGetTitle") || InStr(Source, "ControlGetText"), "the action receipt reads no user text")
	AssertFalse(InStr(Source, "SetActiveWindow") || InStr(Source, "WinActivate"), "the diagnostic never changes focus")
}
Test("native file filter: action diagnostics retain observation-only owned source", _NDT_FilterFailureFactsSource)

/**
 * Executes the actual generated filename predicate on projected UIA item fields.
 * Native picker cases separately prove the provider's type selection and HWND
 * fences; these controls preserve exact names, duplicate refusal and process IDs.
 * @param {string} PredicateCase - Matching or fence control selection.
 */
_NDT_FileFilterViewPredicate(PredicateCase) {
	Root := A_Temp . "\ergopti_filter_view_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the view predicate fixture has one private root")
	DirCreate(Root)
	Ownership := {CanRetire: true}
	try {
		ObserverSource := _NDT_FileFilterObserverSource("unused-observer-library.ahk")
		Start := InStr(ObserverSource, "`n_NFO_Visible(")
		Finish := InStr(ObserverSource, "`n_NFO_WaitVisible(", , Start)
		AssertTrue(Start > 0 && Finish > Start, "the actual generated item predicate must exist")
		PredicateSource := SubStr(ObserverSource, Start + 1, Finish - Start)
		Program := [
			'#Requires AutoHotkey v2.0',
			'#SingleInstance Off',
			'#NoTrayIcon',
			'#Warn All, StdOut',
			'try {',
			'if A_Args[1] == "matching" {',
			'Check(!_NFO_Visible([], ["owned.txt"], 41), "an empty census is not visible")',
			'Check(_NFO_Visible([{Name: "owned.txt", ProcessId: 41, IsOffscreen: 0}], ["owned.txt"], 41), "the exact owned item is visible")',
			'Check(_NFO_Visible([{Name: "owned.txt", ProcessId: 41, IsOffscreen: 0}], ["owned", "owned.txt"], 41), "authoritative shell spelling alternatives remain exact")',
			'Check(!_NFO_Visible([{Name: "OWNED.TXT", ProcessId: 41, IsOffscreen: 0}], ["owned.txt"], 41), "different case cannot acquire a name")',
			'Check(!_NFO_Visible([{Name: "owned.txt.more", ProcessId: 41, IsOffscreen: 0}], ["owned.txt"], 41), "a prefix cannot acquire a name")',
			'Check(!_NFO_Visible([{Name: "owned.txt", ProcessId: 41, IsOffscreen: 1}], ["owned.txt"], 41), "an offscreen match is not visible")',
			'Items := [{Name: "owned.txt", ProcessId: 41, IsOffscreen: 0}, {Name: "owned.bin", ProcessId: 41, IsOffscreen: 0}]',
			'Check(_NFO_Visible(Items, ["owned.txt"], 41) && _NFO_Visible(Items, ["owned.bin"], 41), "the same unfiltered census exposes both files")',
			'Items[2].IsOffscreen := 1',
			'Check(_NFO_Visible(Items, ["owned.txt"], 41) && !_NFO_Visible(Items, ["owned.bin"], 41), "the same census preserves both visibility results")',
			'} else if A_Args[1] == "fences" {',
			'Duplicate := "An exact owned filename must identify at most one native file item"',
			'Foreign := "A native file item cannot cross the owned process fence"',
			'Refuse([{Name: "owned.txt", ProcessId: 41, IsOffscreen: 0}, {Name: "owned.txt", ProcessId: 41, IsOffscreen: 0}], Duplicate)',
			'Refuse([{Name: "owned.txt", ProcessId: 41, IsOffscreen: 0}, {Name: "owned.txt", ProcessId: 41, IsOffscreen: 1}], Duplicate)',
			'Refuse([{Name: "owned.txt", ProcessId: 42, IsOffscreen: 0}], Foreign)',
			'Refuse([{Name: "owned.txt", ProcessId: 42, IsOffscreen: 1}], Foreign)',
			'} else throw ValueError("Unknown predicate control")',
			'FileAppend("view-predicate-observed", "*", "UTF-8-RAW")',
			'ExitApp(0)',
			'} catch as PredicateFailure {',
			'FileAppend(Type(PredicateFailure) . ": " . PredicateFailure.Message, "**", "UTF-8-RAW")',
			'ExitApp(2)',
			'}',
			'Check(Value, Message) {',
			'if !Value',
			'throw Error(Message)',
			'}',
			'Refuse(RejectedItems, ExpectedMessage) {',
			'try _NFO_Visible(RejectedItems, ["owned.txt"], 41)',
			'catch as RefusalFailure {',
			'if RefusalFailure.Message != ExpectedMessage',
			'throw Error("The wrong refusal was observed: " . RefusalFailure.Message)',
			'return',
			'}',
			'throw Error("An invalid matching census was accepted")',
			'}'
		]
		ProbeSource := ""
		for Statement in Program
			ProbeSource .= Statement . "`n"
		Harness := Root . "\view_predicate.ahk"
		FileAppend(ProbeSource . PredicateSource, Harness, "UTF-8")
		AssertEqual("view-predicate-observed",
			_NDT_RunChild(A_AhkPath, ["/ErrorStdOut", Harness, PredicateCase], Ownership),
			"the actual generated predicate preserves its exact matching and refusal contract")
	} finally {
		if Ownership.CanRetire
			DirDelete(Root, true)
	}
}
Test("native file filter: a view census preserves exact filename visibility (file-filter-view-census)",
	_NDT_FileFilterViewPredicate.Bind("matching"))
Test("native file filter: a view census refuses duplicates and foreign owners (file-filter-view-census)",
	_NDT_FileFilterViewPredicate.Bind("fences"))
