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
