; tests/unit/test_llm_trigger_shortcut_retired.ahk

; ==============================================================================
; MODULE: Retired LLM Trigger Shortcut Tests
; DESCRIPTION:
; A prediction on demand is the llm_generate_prediction action, bound in a
; keyboard slot (Win+Space recommended, swallowed so the language switcher
; never sees it). The AI menu's own trigger shortcut ([llm] trigger_shortcut,
; bound to Ctrl+Space by default) was a second path to the same request, with
; its own global hotkey, recovery journal and lifecycle gates: it is retired.
; These tests fail while any part of that second path remains.
; ==============================================================================

#Requires AutoHotkey v2.0

; The trigger submenu opens on its debounce row: no row prompts for a chord.
_LTSR_TriggerMenuHasNoShortcutRow() {
	global _LLM_Menu
	Rows := _LLM_Menu_TriggerRows()
	Assert(Rows is Array && Rows.Length > 0, "the trigger submenu must still draw its rows")
	AssertEqual(StrReplace(t("menu.llm.debounce_label"), "%s", _LLM_Menu["debounce_ms"] . " ms"),
		Rows[1]["label"], "the debounce row now opens the trigger submenu")
	for Row in Rows {
		Label := Row.Get("label", "")
		Assert(!InStr(Label, "menu.llm.trigger_shortcut_label"),
			"no row may carry the retired trigger-shortcut label")
	}
}
Test("[llm-trigger-retired] the trigger submenu draws no dedicated shortcut row",
	_LTSR_TriggerMenuHasNoShortcutRow)

; A persisted value from an older build is neither restored nor re-persisted.
_LTSR_BootRestoreIgnoresTheRetiredKey() {
	global _LLM_Menu, _LLM_Menu_Loaded
	SavedLoaded := _LLM_Menu_Loaded
	try {
		_LLM_Menu_Loaded := false
		AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(Map("trigger_shortcut", "Ctrl+L")))
		AssertFalse(_LLM_Menu.Has("trigger_shortcut"),
			"boot restore must not bring the retired trigger shortcut back")
		; Even a menu state still holding the key must not write it back.
		MenuState := _LLM_Menu.Clone()
		MenuState["user_profiles"] := []
		MenuState["trigger_shortcut"] := "Ctrl+L"
		Updates := []
		AssertTrue(_LLM_Menu_AppendPersistedUpdates(Updates, MenuState))
		AssertTrue(Updates.Length > 0,
			"the full save must still write the LLM menu's own keys")
		for Update in Updates
			Assert(Update.Key != "trigger_shortcut",
				"the full save must not write the retired trigger shortcut")
	} finally _LLM_Menu_Loaded := SavedLoaded
}
Test("[llm-trigger-retired] boot restore and full save ignore [llm] trigger_shortcut",
	_LTSR_BootRestoreIgnoresTheRetiredKey)

; No owner of the second path survives anywhere in the driver: the hotkey
; owner, its recovery journal, its lifecycle quiescence and its boot replay.
_LTSR_NoSecondTriggerPathRemains() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable for the retirement scan")
	Assert(RegExMatch(Src, "m)^LLM_Menu_TriggerPrediction\(") > 0,
		"the scan must see the llm_generate_prediction owner it keeps")
	for Name in ["LLM_Menu_ApplyTriggerShortcut", "LLM_Menu_CommitTriggerShortcut",
			"LLM_Menu_PromptTriggerShortcut", "LLM_Menu_QuiesceTriggerForLifecycle",
			"LLM_TriggerJournalRecoverAtBoot", "LLM_TriggerJournalPrepareDestructive",
			"LLM_Menu_ServiceTriggerRecovery"] {
		AssertEqual(0, RegExMatch(Src, "m)^" . Name . "\("),
			Name . " must not be defined: the dedicated trigger shortcut is retired")
		AssertEqual(0, InStr(Src, Name . "("),
			Name . " must have no caller left")
	}
	AssertEqual(0, InStr(Src, '"trigger_shortcut"'),
		"no production code may read or write [llm] trigger_shortcut")
}
Test("[llm-trigger-retired] no dedicated trigger owner, journal or gate remains",
	_LTSR_NoSecondTriggerPathRemains)


/** Independent boundary records are consumed by the original native provider partitions. */
_LTSR_ControlBoundary(Kind) {
	global _LLM_Menu, _SharedDir
	Expected := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\llm_control_boundaries.json"))
	Contract := Expected["boundaries"][Kind]
	Previous := _LLM_Menu
	_LLM_Menu := Previous.Clone()
	_LLM_Menu["debounce_ms"] := Expected["trigger_delay"]
	_LLM_Menu["disabled_apps"] := []
	_LLM_Menu["inline_autotype"] := false
	_LLM_Menu["pred_indent"] := 0
	Root := _MM_GetManifestRoot(), Frame := _MR_GetMenuDef(Contract["section"]), Original := Frame[1]
	Native := 0
	OwnedRows() => Kind == "trigger" ? _LLM_Menu_TriggerRows("leading") : _LLM_Menu_DisplayRows("remaining")
	try {
		Rows := OwnedRows()
		AssertEqual(2, Rows.Length)
		AssertEqual(Kind == "trigger" ? StrReplace(t("menu.llm.debounce_label"), "%s", Expected["trigger_delay"] . " ms") : t(Expected["display_inline_key"]), Rows[1]["label"])
		AssertTrue(HasMethod(Rows[1]["action"], "Call"))
		AssertTrue(Rows[2]["separator"])
		if Kind == "display"
			AssertFalse(Rows[1]["checked"])
		if Kind == "trigger" {
			Remaining := _LLM_Menu_TriggerRows("remaining")
			AssertEqual(1, Remaining.Length)
			AssertEqual(t("menu.llm.exclude_from_ai"), Remaining[1]["label"])
			AssertTrue(HasMethod(Remaining[1]["action"], "Call"))
		}
		Native := Menu()
		MenuRenderer_AppendRows(Native, "llm_menu", Kind == "trigger" ? "llm_trigger" : "llm_display", Rows)
		AssertEqual(2, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		State := DllCall("GetMenuState", "ptr", Native.Handle, "uint", 1, "uint", 0x400, "uint")
		Assert(State != 0xFFFFFFFF && (State & 0x800) != 0)
		Frame[1] := Map("type", "label", "id", "hand_control_boundary", "i18n", Expected["marker_key"],
			"platforms", Original["platforms"], "unavailable", "hide")
		Rows := OwnedRows()
		AssertEqual(t(Expected["marker_key"]), Rows[2]["label"])
		AssertTrue(Rows[2]["disabled"])
		AssertFalse(Rows[2].Has("action"))
		AssertTrue(HasMethod(Rows[1]["action"], "Call"))
		Root.Delete(Contract["section"])
		AssertEqual(0, OwnedRows().Length, "actual native provider cannot rebuild a withdrawn boundary")
		Root[Contract["section"]] := [Map("type", "command", "id", "hand_unbound_control_boundary", "i18n", Expected["marker_key"])]
		AssertEqual(0, OwnedRows().Length)
	} finally {
		Root[Contract["section"]] := Frame, Frame[1] := Original
		_LLM_Menu := Previous
		if Native is Menu
			_CTC_ReleaseMenu(Native)
	}
	Assert(_LLM_Menu == Previous)
	AssertTrue(Kind == "trigger" ? _LLM_Menu_TriggerRows("leading")[-1]["separator"] : _LLM_Menu_DisplayRows("remaining")[-1]["separator"])
}
for Kind in ["trigger", "display"]
	Test("LLM control boundaries: actual native provider " . Kind, _LTSR_ControlBoundary.Bind(Kind))
