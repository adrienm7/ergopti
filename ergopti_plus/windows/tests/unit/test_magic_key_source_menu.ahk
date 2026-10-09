; tests/unit/test_magic_key_source_menu.ahk

; ==============================================================================
; MODULE: Physical Magic Key Menu Tests (Windows)
; DESCRIPTION:
; [hotstrings] magic_key_source names the physical key that types the magic key
; on every driver, and the Layout menu offers it on every OS: a row naming the
; key in effect, whose submenu captures the next key pressed, restores the
; automatic key or lists every candidate. Windows could only take the key from
; a hand-edited scan code. These cases pin the rows, the capture's key decision
; (read from the physical key state: the InputHook only sees what a remap hotkey
; sends, so the scan code it reported named the wrong key under the emulation),
; reverse scan-code lookup, and the editor that persists a choice.
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

Test("magic key source: the row sits under the any-layout section, between switching and shortcut policy (magic-key-source)",
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
	AssertTrue(Position.Has("layout_switching") && Position.Has("layout.ctrl_magic_save"),
		"the independent surrounding rows must exist")
	AssertEqual(Position["layout_switching"] + 1, Position["magic_key_source"],
		"the physical source follows the declared layout-switching provider")
	AssertEqual(Position["magic_key_source"] + 1, Position["layout.ctrl_magic_save"],
		"the physical source precedes the declared shortcut policy")
	AssertFalse(Position.Has("hotstrings.magic_key.replace"),
		"the removed replacement toggle must not reappear in Layout")
}

class _MKS_FakeHook {
	Stops := 0
	InProgress := true

	Stop() {
		this.Stops += 1
		this.InProgress := false
	}
}

Test("magic key source: the capture ignores a lone modifier and stops on Escape (magic-key-source)",
	_MKS_CaptureModifierEscapeCase)

_MKS_CaptureModifierEscapeCase() {
	Down := Map()
	State := _MagicKeySourceCaptureState((Key) => Down.Has(Key))
	Hook := _MKS_FakeHook()
	Down["SC02A"] := true
	_MagicKeySourceCaptureKeyDown(State, Hook, GetKeyVK("LShift"), GetKeySC("LShift"))
	AssertEqual("", State.Scan, "a modifier alone chooses nothing")
	AssertEqual(0, Hook.Stops, "and keeps the capture waiting")
	_MagicKeySourceCaptureKeyDown(State, Hook, GetKeyVK("Escape"), GetKeySC("Escape"))
	AssertEqual("", State.Scan, "Escape chooses nothing")
	AssertFalse(State.Refused, "and refuses nothing")
	AssertEqual(1, Hook.Stops, "it ends the capture")
}

; With the Ergopti emulation on, every candidate key is a remap hotkey: the
; InputHook never sees the key pressed, only what its hotkey sends.
Test("magic key source: the capture answers with the key physically down, not what the hook saw (magic-key-source)",
	_MKS_CapturePhysicalKeyCase)

_MKS_CapturePhysicalKeyCase() {
	Down := Map()
	State := _MagicKeySourceCaptureState((Key) => Down.Has(Key))
	Hook := _MKS_FakeHook()
	Down["SC027"] := true
	; The Semicolon key of the emulation sends "j", reported with the scan code
	; of j on the OS layout.
	_MagicKeySourceCaptureKeyDown(State, Hook, 0x4A, 0x24)
	AssertEqual("SC027", State.Scan, "the key pressed, never the scan code of its output")
	AssertEqual(1, Hook.Stops)

	Down := Map()
	State := _MagicKeySourceCaptureState((Key) => Down.Has(Key))
	Hook := _MKS_FakeHook()
	Down["SC02E"] := true
	; The current magic key sends {Text}★: a VK_PACKET with no scan code.
	_MagicKeySourceCaptureKeyDown(State, Hook, 0xE7, 0)
	AssertEqual("SC02E", State.Scan, "the magic key's own key is answered too")
	AssertEqual("KeyC", LayoutRegistry_KeyCode(State.Scan, LayoutRegistry_Keycodes()))
}

Test("magic key source: the capture refuses a key that is no candidate (magic-key-source)",
	_MKS_CaptureRefusalCase)

_MKS_CaptureRefusalCase() {
	State := _MagicKeySourceCaptureState((Key) => false)
	Hook := _MKS_FakeHook()
	_MagicKeySourceCaptureKeyDown(State, Hook, GetKeyVK("Space"), GetKeySC("Space"))
	AssertTrue(State.Refused, "the space bar, down with no candidate, is refused aloud")
	AssertEqual("", State.Scan)
	AssertEqual(1, Hook.Stops)
}

Test("magic key source: a key held when the capture opened answers only once released (magic-key-source)",
	_MKS_CaptureHeldKeyCase)

_MKS_CaptureHeldKeyCase() {
	Down := Map("SC024", true)
	State := _MagicKeySourceCaptureState((Key) => Down.Has(Key))
	Hook := _MKS_FakeHook()
	_MagicKeySourceCaptureKeyDown(State, Hook, 0x4A, 0x24)
	AssertEqual(0, Hook.Stops, "its auto-repeat is no answer, nor a refusal")
	AssertFalse(State.Refused)
	Down.Delete("SC024")
	Down["SC010"] := true
	_MagicKeySourceCaptureKeyDown(State, Hook, 0x51, 0x10)
	AssertEqual("SC010", State.Scan, "another key answers")
	State := _MagicKeySourceCaptureState((Key) => Down.Has(Key))
	Down.Delete("SC010")
	_MagicKeySourcePressedScan(State)
	Down["SC010"] := true
	AssertEqual("SC010", _MagicKeySourcePressedScan(State), "the held key, pressed again, answers")
}

Test("magic key source: the capture's poll answers a key whose hotkey sends nothing (magic-key-source)",
	_MKS_CapturePollCase)

_MKS_CapturePollCase() {
	Down := Map()
	State := _MagicKeySourceCaptureState((Key) => Down.Has(Key))
	Hook := _MKS_FakeHook()
	_MagicKeySourceCapturePoll(State, Hook)
	AssertEqual(0, Hook.Stops, "nothing down, nothing answered")
	Down["SC01A"] := true
	_MagicKeySourceCapturePoll(State, Hook)
	AssertEqual("SC01A", State.Scan, "a dead key of the emulation answers from its physical state")
	AssertEqual(1, Hook.Stops)
	Down["SC010"] := true
	_MagicKeySourceCapturePoll(State, Hook)
	AssertEqual("SC01A", State.Scan, "a stopped capture takes no second answer")

	Down := Map("Escape", true)
	State := _MagicKeySourceCaptureState((Key) => Down.Has(Key))
	Hook := _MKS_FakeHook()
	_MagicKeySourceCapturePoll(State, Hook)
	AssertEqual(1, Hook.Stops, "Escape held ends the capture")
	AssertEqual("", State.Scan)

	Body := _DriverFuncBody("MagicKeySourceCapture")
	Assert(Body != "", "MagicKeySourceCapture must exist in ui/editors.ahk")
	Assert(InStr(Body, "_MagicKeyEditorInputHook := IH") > 0,
		"the capture shares the magic-key editor's owner, stopped by Suspend and Close")
	Assert(InStr(Body, 'GuiToShow.OnEvent("Close", _MagicKeyEditorClose.Bind(IH))') > 0,
		"closing the dialog stops the suppressive hook")
	Assert(InStr(Body, '"magic_key_capture_timeout_ms"') > 0, "the capture ends on the shared timeout")
	Assert(InStr(Body, 'SetTimer(MagicKeyCapturePoll, TimingsGet("ui", "magic_key_capture_poll_ms"))') > 0,
		"the poll runs on the shared interval while the capture waits")
	Assert(InStr(Body, "SetTimer(MagicKeyCapturePoll, 0)") > 0, "and stops with it")
	Assert(InStr(Body, "ModifyMagicKeySource(LayoutRegistry_KeyCode(State.Scan,") > 0,
		"a captured candidate is persisted")
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

Test("magic key source: configured tap claims refuse choices across the shared corpus (magic-key-source)",
	_MKS_TapClaimCorpusCase)

_MKS_TapClaimCorpusCase() {
	global _SharedDir, TapKeyAssignments, CategoryEnabled, ScriptInformation
	SavedAssignments := TapKeyAssignments
	SavedCategories := CategoryEnabled
	SavedSource := ScriptInformation["MagicKeySource"]
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\keymap\magic_source_tap_claims.json", "UTF-8"))
	try {
		CategoryEnabled := Map("Shortcuts", false)
		for Vector in Corpus["cases"] {
			TapKeyAssignments := Vector["assignments"]
			Source := Vector["source"]
			Expected := Vector["expected"]["ahk"]
			Scan := Source == "auto" ? 0 : Integer("0x" . SubStr(LayoutRegistry_KeyScan(Source, LayoutRegistry_Keycodes()), 3))
			AssertEqual(Expected, TapKeyAssignedToScan(Scan), Vector["name"])
			AssertEqual(Expected == "" ? "" : Corpus["reason_key"], MagicKeySourceChoiceReason(Source), Vector["name"])
			if Expected == ""
				continue
			ScriptInformation["MagicKeySource"] := "KeyJ"
			Calls := { writes: 0, notices: [], reloads: 0 }
			InheritedCritical := A_IsCritical
			try {
				Critical("On")
				AssertFalse(ModifyMagicKeySource(Source, (*) => (Calls.writes += 1),
					(Reason) => Calls.notices.Push(Map("reason", Reason, "critical", A_IsCritical)),
					(*) => (Calls.reloads += 1)))
				Assert(A_IsCritical > 0, "the caller's Critical state is restored after refusal")
			} finally {
				Critical(InheritedCritical)
			}
			AssertEqual(0, Calls.writes, "refusal precedes persistence")
			AssertEqual(0, Calls.reloads, "refusal does not reacquire native input")
			AssertEqual(Corpus["reason_key"], Calls.notices[1]["reason"])
			AssertEqual(0, Calls.notices[1]["critical"], "notification runs outside the native input Critical span")
			AssertEqual("KeyJ", ScriptInformation["MagicKeySource"])
			AssertEqual("send_text", TapKeyAssignments[Expected], "the stored tap action is retained")
			Rows := MagicKeySourceMenuRows()
			Seen := 0
			for Row in Rows[1]["items"] {
				if Row.Has("label") && (InStr(Row["label"], "(" . Source . ")") || InStr(Row["label"], Source . " — ") == 1) {
					Seen += 1
					AssertTrue(Row["disabled"])
					Assert(InStr(Row["label"], t(Corpus["reason_key"])) > 0, "the row explains its refusal")
				}
			}
			AssertEqual(1, Seen, "the refused candidate is still visible exactly once")
		}
	} finally {
		TapKeyAssignments := SavedAssignments
		CategoryEnabled := SavedCategories
		ScriptInformation["MagicKeySource"] := SavedSource
	}
}

Test("magic key source: the complete declared family follows the independent hand corpus (magic-key-source)",
	_MKS_SharedFamilyCorpusCase)

_MKS_SharedFamilyCorpusCase() {
	global _SharedDir, ScriptInformation
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\magic_key_source_family.json", "UTF-8"))
	Root := _MR_GetManifestRoot()
	Assert(Root is Map, "the actual canonical menu loader must supply its current root")
	_MKS_AssertDeclaredData(Corpus["parent"], Root["magic_key_source_menu"])
	_MKS_AssertDeclaredData(Corpus["children"], Root["magic_key_source_children"])
	Values := ManifestFindEntryByPath("hotstrings.magic_key_source")["enum_values"]
	AssertEqual(Corpus["candidates"].Length + 1, Values.Length)
	for Index, Code in Corpus["candidates"]
		AssertEqual(Code, Values[Index + 1], "the original physical candidate order: " . Code)
	SavedSource := ScriptInformation["MagicKeySource"]
	SavedChild := Root["magic_key_source_children"]
	SavedParent := Root["magic_key_source_menu"]
	try {
		ScriptInformation["MagicKeySource"] := "KeyJ"
		Rows := MagicKeySourceMenuRows()
		AssertEqual(Corpus["candidates"].Length + 4, Rows[1]["items"].Length)
		Root.Delete("magic_key_source_children")
		AssertEqual(0, MagicKeySourceMenuRows().Length, "withdrawal cannot reconstruct native fixed children")
		Root["magic_key_source_children"] := SavedChild
		Root.Delete("magic_key_source_menu")
		AssertEqual(0, MagicKeySourceMenuRows().Length, "withdrawal cannot reconstruct the native fixed parent")
		Root["magic_key_source_menu"] := SavedParent
		AssertEqual(Corpus["candidates"].Length + 4, MagicKeySourceMenuRows()[1]["items"].Length,
			"a repaired genuine declaration restores the family")
	} finally {
		Root["magic_key_source_children"] := SavedChild
		Root["magic_key_source_menu"] := SavedParent
		ScriptInformation["MagicKeySource"] := SavedSource
	}
}

Test("magic key source: declared capture readiness and live withdrawal guard native callback delivery (magic-key-source)",
	_MKS_DeclaredCallbackRefusalCase)

_MKS_DeclaredCallbackRefusalCase() {
	Root := _MR_GetManifestRoot()
	Saved := Root["magic_key_source_children"]
	Calls := { capture: 0, automatic: 0 }
	Ready := { capture: false }
	Commands := Map("magic_key_source_capture", (*) => (Calls.capture += 1),
		"magic_key_source_automatic", (*) => (Calls.automatic += 1))
	Getters := Map("magic_key_source_capture_ready", (*) => Ready.capture,
		"magic_key_source_is_automatic", (*) => true)
	Rows := MenuRenderer_TemplateRows("magic_key_source_children", Commands, Getters,
		Map("magic_key_source_candidates", (*) => []))
	AssertEqual(4, Rows.Length, "the genuine empty candidate data leaves the fixed template intact")
	AssertTrue(Rows[1]["disabled"])
	AssertTrue(Rows[3]["checked"])
	Rows[1]["action"].Call()
	AssertEqual(0, Calls.capture, "declared readiness precedes native capture delivery")
	try {
		Root.Delete("magic_key_source_children")
		Rows[1]["action"].Call()
		Rows[3]["action"].Call()
		AssertEqual(0, Calls.capture)
		AssertEqual(0, Calls.automatic, "actual declaration withdrawal precedes both callbacks")
	} finally {
		Root["magic_key_source_children"] := Saved
	}
	Ready.capture := true
	Rows[1]["action"].Call()
	Rows[3]["action"].Call()
	AssertEqual(1, Calls.capture, "repaired declaration and readiness restore the same retained callback")
	AssertEqual(1, Calls.automatic)
}

_MKS_AssertDeclaredData(Expected, Actual) {
	if Expected is Array {
		Assert(Actual is Array, "the current declared child data must be an Array")
		AssertEqual(Expected.Length, Actual.Length)
		for Index, Value in Expected
			_MKS_AssertDeclaredData(Value, Actual[Index])
	} else if Expected is Map {
		Assert(Actual is Map, "the current declared row must be a Map")
		AssertEqual(Expected.Count, Actual.Count)
		for Key, Value in Expected {
			Assert(Actual.Has(Key), "the current declaration must retain " . Key)
			_MKS_AssertDeclaredData(Value, Actual[Key])
		}
	} else {
		AssertEqual(Expected, Actual)
	}
}
