; static/ergopti_plus/windows/tests/unit/test_shortcuts_menu_blocks.ahk

; ==============================================================================
; MODULE: Shortcuts Menu Blocks And Tap Keys
; DESCRIPTION:
; Two reported defects of the Shortcuts submenu.
;
; 1. The rows acting on typed or selected text (wrap a selection, type a framed
;    symbol) ran straight into the user's Alt / Ctrl / Ctrl+Shift / Win groups
;    with no separator: the "---" between them was declared for Linux only.
; 2. The instant-screenshot row read « Capture d'ecran instantanee » without
;    naming its key. The key left of 1 is one of three tap keys now, each row
;    named by the character the key types under the layout in use.
; ==============================================================================

_SMB_SeparatorBeforeModifierGroups() {
	Def := _MR_GetMenuDef("shortcuts_menu")
	Index := 0
	for Position, Item in Def {
		if (_MR_Get(Item, "id") == "keyboard_slots") {
			Index := Position
		}
	}
	Assert(Index > 1, "shortcuts_menu must declare the keyboard_slots list")
	Before := Def[Index - 1]
	Assert(_MR_Get(Before, "type") == "---",
		"a '---' must separate the text rows from the modifier shortcut groups")
	Assert(!Before.Has("platforms"),
		"that separator must apply on every platform, not on Linux only")
}
Test("shortcuts menu: a separator splits text rows from modifier groups (shortcuts-menu-blocks)",
	_SMB_SeparatorBeforeModifierGroups)

; The key left of 1 used to be one fixed row, "instant screenshot", labelled by
; a legend written for two layouts. It is one of three tap keys now: the
; manifest lists them, and the provider names each by what it types (see
; unit/test_tap_keys.ahk for the labels themselves).
_SMB_TapKeysReplaceTheScreenshotRow() {
	Assert(!(ManifestFindEntryByPath("shortcuts.screen_instant") is Map),
		"the fixed instant-screenshot feature must be gone: the key is a tap key")
	for _, Id in ["number_row_left", "number_row_right_1", "number_row_right_2"] {
		Entry := ManifestFindEntryByPath("shortcuts.tap_keys." . Id)
		Assert(Entry is Map, "shortcuts.tap_keys." . Id . " must be declared in the features manifest")
		Assert(Entry["type"] == "action", "a tap key holds an action")
	}
	Def := _MR_GetMenuDef("shortcuts_menu")
	Found := false
	for _, Row in Def {
		if (_MR_Get(Row, "type") == "list" && _MR_Get(Row, "id") == "tap_keys")
			Found := true
	}
	Assert(Found, "the shortcuts menu must list the tap keys through a provider")
}
Test("shortcuts menu: the tap keys replace the fixed screenshot row (shortcuts-menu-blocks)",
	_SMB_TapKeysReplaceTheScreenshotRow)


/** Exercises the real extension allocator, physical scan and native fallback submenu. */
_SMB_ExtensionBoundary() {
	global _ExtensionsDir, _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\shortcut_extension_boundary.json", "UTF-8"))
	Root := A_Temp . "\ergopti-shortcut-boundary-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount
	Saved := _ExtensionsDir
	Definition := _MM_GetManifestRoot()
	Frame := _MR_GetMenuDef(Corpus["section"])
	Heading := Frame[2]
	Native := 0, Submenus := [], Released := Map()
	ReadRows() {
		Rows := _SC_ExtensionRows()
		for Row in Rows {
			if Row.Has("submenu")
				Submenus.Push(Row["submenu"])
		}
		return Rows
	}
	try {
		_ExtensionsDir := Root
		DirCreate(Root)
		AssertEqual(0, ReadRows().Length, "an empty real source has no presentation boundary")
		DirCreate(Root . "\boundary-missing-builder\shortcuts")
		FileAppend("; This physical source intentionally has no compiled extension builder.`n",
			Root . "\boundary-missing-builder\shortcuts\menu.ahk", "UTF-8")
		FileAppend('name = "Boundary fixture"`n', Root . "\boundary-missing-builder\manifest.toml", "UTF-8")
		Rows := ReadRows()
		AssertEqual(3, Rows.Length)
		AssertTrue(Rows[1]["separator"])
		AssertEqual(MenuSectionTitle(t(Corpus["caption_key"])), Rows[2]["label"])
		AssertTrue(Rows[2]["disabled"])
		AssertFalse(Rows[2].Has("action"))
		AssertEqual("Boundary fixture", Rows[3]["label"])
		AssertEqual(1, DllCall("GetMenuItemCount", "ptr", Rows[3]["submenu"].Handle, "int"))
		AssertEqual(t("menu.extensions.empty"), _CTC_LabelAt(Rows[3]["submenu"], 0))
		Native := Menu()
		MenuRenderer_AppendRows(Native, "shortcuts_menu", "extensions_shortcuts", Rows)
		AssertEqual(3, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x800) != 0, "the native boundary starts with a separator")
		Frame[2] := Map("type", "section_header", "id", Corpus["heading_id"], "i18n", Corpus["published_marker_key"],
			"platforms", Heading["platforms"], "unavailable", "hide")
		Rows := ReadRows()
		AssertEqual(MenuSectionTitle(t(Corpus["published_marker_key"])), Rows[2]["label"],
			"the actual native provider consumes its current declared heading")
		AssertTrue(Rows[2]["disabled"])
		AssertEqual("Boundary fixture", Rows[3]["label"])
		Definition.Delete(Corpus["section"])
		AssertEqual(0, ReadRows().Length, "a withdrawn boundary has no native fallback")
		Definition[Corpus["section"]] := [Map("type", "command", "id", "unowned_extension_boundary", "i18n", Corpus["caption_key"])]
		AssertEqual(0, ReadRows().Length, "an unbound command cannot become a heading")
		Definition[Corpus["section"]] := Frame
		Frame[2] := Heading
		Rows := ReadRows()
		AssertEqual(3, Rows.Length, "repair retains the same real source allocator")
		AssertEqual(MenuSectionTitle(t(Corpus["caption_key"])), Rows[2]["label"])
		AssertEqual("Boundary fixture", Rows[3]["label"])
		Assert(FileExist(Root . "\boundary-missing-builder\shortcuts\menu.ahk"), "presentation preserves the source")
	} finally {
		Definition[Corpus["section"]] := Frame
		Frame[2] := Heading
		_ExtensionsDir := Saved
		if Native is Menu
			_CTC_ReleaseMenu(Native, Released)
		for Submenu in Submenus
			_CTC_ReleaseMenu(Submenu, Released)
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("shortcut extension boundary: authentic allocator and native submenu (extension-boundary)", _SMB_ExtensionBoundary)


/** Exercises the real personal registry and native submenu through its shared frame. */
_SMB_PersonalShortcutFrame() {
	global _PersonalShortcutsRegistry, Features, CategoryEnabled, _SharedDir
	global _MenuPopulationBuilding, _MenuPopulationPublished, _MenuDispatchCallbacks
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\personal_shortcuts_frame.json", "UTF-8"))
	SavedRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	SavedFeatures := Features, SavedCategories := CategoryEnabled
	State := MasterGateState(), SavedState := State.Clone()
	SavedBuilding := _MenuPopulationBuilding, SavedPublished := _MenuPopulationPublished
	Definition := _MM_GetManifestRoot(), Frame := _MR_GetMenuDef(Corpus["section"])
	Heading := Frame[2]
	Native := Menu()
	try {
		_MenuPopulationBuilding := false, _MenuPopulationPublished := false
		State["initialized"] := false
		Features := Map("shortcuts", Map("personal", Map()))
		CategoryEnabled := Map("Shortcuts", true)
		_PersonalShortcutsRegistry := Map()
		_AppendPersonalShortcutsSubmenuIfAny(Native)
		AssertEqual(Corpus["absent_registry_count"], _MenuItemCount(Native))
		_PersonalShortcutsRegistry := Map("__Order", [])
		_AppendPersonalShortcutsSubmenuIfAny(Native)
		AssertEqual(Corpus["empty_registry_count"], _MenuItemCount(Native))
		RegisterPersonalFeature(Corpus["registered_names"][1], true, Corpus["registered_labels"][1])
		RegisterPersonalFeature(Corpus["registered_names"][2], true)
		AssertEqual(false, Features["shortcuts"]["personal"][Corpus["registered_names"][1]])
		AssertEqual(false, Features["shortcuts"]["personal"][Corpus["registered_names"][2]])
		_AppendPersonalShortcutsSubmenuIfAny(Native)
		AssertEqual(Corpus["populated_frame_count"], _MenuItemCount(Native))
		AssertTrue(TrayMenuIsSeparatorAt(Native, 0))
		AssertEqual(t(Heading["i18n"]), _MP_ReadLabel(Native, 1))
		ChildHandle := DllCall("GetSubMenu", "ptr", Native.Handle, "int", 1, "ptr")
		Assert(ChildHandle != 0, "the registered rows remain an actual submenu")
		AssertEqual(2, DllCall("GetMenuItemCount", "ptr", ChildHandle, "int"))
		for Index, ExpectedLabel in Corpus["registered_labels"] {
			Text := Buffer(512, 0)
			DllCall("GetMenuStringW", "ptr", ChildHandle, "uint", Index - 1, "ptr", Text,
				"int", 256, "uint", 0x400)
			AssertEqual(ExpectedLabel, StrGet(Text, "UTF-16"))
			CommandId := DllCall("GetMenuItemID", "ptr", ChildHandle, "int", Index - 1, "uint")
			Assert(_MenuDispatchCallbacks.Has(CommandId), "every real switch retains a dispatch callback")
		}
		_CTC_ReleaseMenu(Native)
		Native := Menu()
		Frame[2] := Map("type", "group", "id", Heading["id"], "i18n", Corpus["marker_key"],
			"platforms", Heading["platforms"], "unavailable", "hide")
		_AppendPersonalShortcutsSubmenuIfAny(Native)
		AssertEqual(t(Corpus["marker_key"]), _MP_ReadLabel(Native, 1),
			"the actual provider consumes the current shared caption")
		_CTC_ReleaseMenu(Native)
		Native := Menu()
		Definition.Delete(Corpus["section"])
		_AppendPersonalShortcutsSubmenuIfAny(Native)
		AssertEqual(0, _MenuItemCount(Native), "a missing frame cannot synthesize native fixed rows")
		Definition[Corpus["section"]] := [Map("type", "command", "id", Heading["id"], "i18n", Heading["i18n"])]
		_AppendPersonalShortcutsSubmenuIfAny(Native)
		AssertEqual(0, _MenuItemCount(Native), "an unbound command cannot become a child group")
		Definition[Corpus["section"]] := Frame
		Frame[2] := Heading
		_AppendPersonalShortcutsSubmenuIfAny(Native)
		AssertEqual(Corpus["populated_frame_count"], _MenuItemCount(Native), "repair keeps the real registry")
		AssertEqual(t(Heading["i18n"]), _MP_ReadLabel(Native, 1))
		AssertEqual(2, _PersonalShortcutsRegistry["__Order"].Length)
	} finally {
		Definition[Corpus["section"]] := Frame
		Frame[2] := Heading
		_CTC_ReleaseMenu(Native)
		_PersonalShortcutsRegistry := IsSet(SavedRegistry) ? SavedRegistry : unset
		Features := SavedFeatures, CategoryEnabled := SavedCategories
		State.Clear()
		for Key, Value in SavedState
			State[Key] := Value
		_MenuPopulationBuilding := SavedBuilding, _MenuPopulationPublished := SavedPublished
	}
}
Test("personal shortcut frame: real registration, shared caption and refusal repair", _SMB_PersonalShortcutFrame)

/** Keeps actual child callbacks and a valid empty group when projecting the fixed frame. */
_SMB_PersonalShortcutFrameChildren() {
	Children := [], Callback := (*) => true
	Rows := MenuRenderer_TemplateRows("personal_shortcuts_frame", Map(), Map(),
		Map("personal_shortcuts_registered", Children))
	AssertEqual(2, Rows.Length)
	Assert(ObjPtr(Children) == ObjPtr(Rows[2]["items"]), "empty data is the existing actual child array")
	Children.Push(Map("label", "Child callback", "action", Callback, "checked", true))
	Rows := MenuRenderer_TemplateRows("personal_shortcuts_frame", Map(), Map(),
		Map("personal_shortcuts_registered", Children))
	Assert(ObjPtr(Callback) == ObjPtr(Rows[2]["items"][1]["action"]))
	AssertTrue(Rows[2]["items"][1]["checked"])
	AssertFalse(MenuRenderer_TemplateRows("personal_shortcuts_frame", Map(), Map(), Map()))
}
Test("personal shortcut frame: original child identity, callbacks and empty array", _SMB_PersonalShortcutFrameChildren)
