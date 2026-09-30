; tests/unit/test_magic_key_source_menu.ahk

; ==============================================================================
; MODULE: Physical Magic Key Menu Tests (Windows)
; DESCRIPTION:
; [hotstrings] magic_key_source names the physical key that types the magic key
; on every driver, and the Layout menu offers it on every OS: a row naming the
; key in effect, whose submenu captures the next key pressed, restores the
; automatic key or lists every candidate. Windows could only take the key from
; a hand-edited scan code. These cases pin the rows, the capture's key decision
; and reverse scan-code lookup, and the editor that persists a choice.
; ==============================================================================

#Requires AutoHotkey v2.0

Test("magic key source: the Layout menu captures, restores automatic and lists every candidate (magic-key-source)",
	_MKS_RowsCase)

_MKS_RowsCase() {
	global ScriptInformation
	Saved := ScriptInformation["MagicKeySource"]
	try {
		ScriptInformation["MagicKeySource"] := "KeyJ"
		Rows := MagicKeySourceMenuRows()
		AssertEqual(1, Rows.Length, "one row names the key in effect")
		Label := Rows[1]["label"]
		AssertEqual(1, InStr(Label, t("menu.layout.magic_key_source") . " : "))
		Assert(InStr(Label, "(KeyJ)") > 0 || SubStr(Label, -4) == "KeyJ", "the row names the chosen key")
		Items := Rows[1]["items"]
		AssertEqual(t("menu.layout.magic_key_source.capture"), Items[1]["label"])
		AssertTrue(HasMethod(Items[1]["action"], "Call"), "the capture row presses a key")
		AssertTrue(Items[2]["separator"])
		AssertEqual(t("menu.layout.magic_key_source.auto"), Items[3]["label"])
		AssertFalse(Items[3]["checked"], "a chosen key is not the automatic one")
		AssertTrue(Items[4]["separator"])
		Values := ManifestFindEntryByPath("hotstrings.magic_key_source")["enum_values"]
		AssertEqual(Values.Length + 3, Items.Length, "every candidate is listed once")
		for Index, Code in Values {
			if (Index == 1)
				continue
			Item := Items[Index + 3]
			Assert(InStr(Item["label"], Code) > 0, "the row of " . Code . " names its code")
			AssertEqual(Code == "KeyJ", Item["checked"], "only the key in effect is ticked: " . Code)
			AssertTrue(HasMethod(Item["action"], "Call"))
		}
		ScriptInformation["MagicKeySource"] := "auto"
		Rows := MagicKeySourceMenuRows()
		AssertTrue(Rows[1]["items"][3]["checked"], "the automatic key is ticked when nothing is chosen")
		AssertEqual(t("menu.layout.magic_key_source") . " : " . t("menu.layout.magic_key_source.auto"),
			Rows[1]["label"])
	} finally {
		ScriptInformation["MagicKeySource"] := Saved
	}
}

Test("magic key source: the row sits under the any-layout section, after the replace switch (magic-key-source)",
	_MKS_MenuPlacementCase)

_MKS_MenuPlacementCase() {
	Tokens := []
	for Row in _MR_GetMenuDef("layout_menu") {
		Type := _MR_Get(Row, "type")
		if (Type == "section_header")
			Tokens.Push(_MR_Get(Row, "i18n"))
		else if (Type == "feature")
			Tokens.Push(_MR_Get(Row, "path"))
		else if (Type != "---")
			Tokens.Push(_MR_Get(Row, "id"))
	}
	Position := Map()
	for Index, Token in Tokens
		Position[Token] := Index
	AssertTrue(Position.Has("magic_key_source"), "the layout menu declares the physical magic key")
	AssertTrue(Position["magic_key_source"] > Position["menu.layout.header_any"],
		"the physical magic key works on any layout")
	AssertEqual(Position["hotstrings.magic_key.replace"] + 1, Position["magic_key_source"],
		"it follows the switch that turns the key into the magic key")
}

class _MKS_FakeHook {
	Stops := 0

	Stop() {
		this.Stops += 1
	}
}

Test("magic key source: the capture takes a key, ignores a lone modifier and stops on Escape (magic-key-source)",
	_MKS_CaptureKeyDownCase)

_MKS_CaptureKeyDownCase() {
	Captured := { Scan: 0 }
	Hook := _MKS_FakeHook()
	_MagicKeySourceCaptureKeyDown(Captured, Hook, GetKeyVK("LShift"), GetKeySC("LShift"))
	AssertEqual(0, Captured.Scan, "a modifier alone chooses nothing")
	AssertEqual(0, Hook.Stops, "and keeps the capture waiting")
	_MagicKeySourceCaptureKeyDown(Captured, Hook, GetKeyVK("Escape"), GetKeySC("Escape"))
	AssertEqual(0, Captured.Scan, "Escape chooses nothing")
	AssertEqual(1, Hook.Stops, "and ends the capture")
	Captured := { Scan: 0 }
	_MagicKeySourceCaptureKeyDown(Captured, Hook, 0x4A, 0x24)
	AssertEqual(0x24, Captured.Scan, "any other key is the answer, by scan code")
	AssertEqual(2, Hook.Stops)
	Body := _DriverFuncBody("MagicKeySourceCapture")
	Assert(Body != "", "MagicKeySourceCapture must exist in ui/editors.ahk")
	Assert(InStr(Body, "_MagicKeyEditorInputHook := IH") > 0,
		"the capture shares the magic-key editor's owner, stopped by Suspend and Close")
	Assert(InStr(Body, 'GuiToShow.OnEvent("Close", _MagicKeyEditorClose.Bind(IH))') > 0,
		"closing the dialog stops the suppressive hook")
	Assert(InStr(Body, '"magic_key_capture_timeout_ms"') > 0, "the capture ends on the shared timeout")
	Assert(InStr(Body, "ModifyMagicKeySource(Code)") > 0, "a captured candidate is persisted")
}

Test("magic key source: a pressed scan code names its key back (magic-key-source)", _MKS_KeyCodeCase)

_MKS_KeyCodeCase() {
	Keycodes := LayoutRegistry_Keycodes()
	AssertEqual("KeyJ", LayoutRegistry_KeyCode("SC024", Keycodes))
	AssertEqual("KeyJ", LayoutRegistry_KeyCode("sc024", Keycodes))
	AssertEqual("", LayoutRegistry_KeyCode("SC001", Keycodes), "Escape is no layout key")
	for Index, Code in ManifestFindEntryByPath("hotstrings.magic_key_source")["enum_values"] {
		if (Index == 1)
			continue
		AssertEqual(Code, LayoutRegistry_KeyCode(LayoutRegistry_KeyScan(Code, Keycodes), Keycodes))
		AssertTrue(MagicKeySourceIsCandidate(Code), Code . " is a candidate")
	}
	AssertFalse(MagicKeySourceIsCandidate("auto"), "the automatic value names no key")
	AssertFalse(MagicKeySourceIsCandidate("Space"), "the space bar is never the magic key")
	AssertFalse(MagicKeySourceIsCandidate("keyj"), "a candidate is spelled as the manifest spells it")
	AssertFalse(MagicKeySourceIsCandidate(""))
}

Test("magic key source: the editor persists a choice into the retained intent (magic-key-source)",
	_MKS_EditorCase)

_MKS_EditorCase() {
	global Features, TapHold, CategoryEnabled, ConfigurationFile, ScriptInformation
	Saved := Map("features", Features, "tap_hold", TapHold, "categories", CategoryEnabled,
		"path", ConfigurationFile, "source", ScriptInformation["MagicKeySource"],
		"chosen", ScriptInformation["MagicKeySourceChosen"])
	Owner := MasterGateState()
	SavedOwner := Owner.Clone()
	try {
		Owner["initialized"] := false
		; The master-gate fixture of test_master_gates.ahk (a1-desired), with the
		; physical magic key beside the magic key character.
		Features := Map("layout", Map("ergopti_base", true, "ergopti_alt_gr", false),
			"shortcuts", Map("gpt", Map("enabled", true, "link", "https://example.test")),
			"hotstrings", Map("repeat_key_enabled", true, "trigger_char", "*",
				"magic_key_source", "auto", "rolls", Map("hc", Map("enabled", true))))
		TapHold := Map("keys", Map("caps_lock", Map("tap_action", "enter", "hold_modifier", "ctrl")))
		CategoryEnabled := Map("Layout", false, "Shortcuts", false, "Hotstrings", false,
			"TapHolds", false, "Rolls", false)
		ConfigurationFile := A_Temp . "\ergopti_magic_key_source_" . A_TickCount . ".toml"
		MasterGateInitialize(Features, TapHold, IsCategoryGated)
		AssertTrue(ModifyMagicKeySource("KeyJ", (*) => true, (*) => 0, (*) => true))
		AssertEqual("KeyJ", MasterGateDesiredFeatures(Features)["hotstrings"]["magic_key_source"],
			"the choice publishes into the retained intent")
		AssertEqual("KeyJ", ScriptInformation["MagicKeySource"])
		AssertTrue(ScriptInformation["MagicKeySourceChosen"])
		AssertFalse(ModifyMagicKeySource("Space", (*) => true, (*) => 0, (*) => true),
			"a key that is no candidate is refused before any write")
		AssertEqual("KeyJ", ScriptInformation["MagicKeySource"])
		AssertTrue(ModifyMagicKeySource("auto", (*) => true, (*) => 0, (*) => true))
		AssertFalse(ScriptInformation["MagicKeySourceChosen"], "the automatic key is no choice")
	} finally {
		Features := Saved["features"]
		TapHold := Saved["tap_hold"]
		CategoryEnabled := Saved["categories"]
		ConfigurationFile := Saved["path"]
		ScriptInformation["MagicKeySource"] := Saved["source"]
		ScriptInformation["MagicKeySourceChosen"] := Saved["chosen"]
		Owner.Clear()
		for Key, Value in SavedOwner
			Owner[Key] := Value
	}
}
