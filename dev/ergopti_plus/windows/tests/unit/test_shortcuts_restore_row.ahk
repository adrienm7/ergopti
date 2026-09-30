; tests/unit/test_shortcuts_restore_row.ahk

; shortcuts-restore-row. The Windows Shortcuts submenu had no « Restaurer les
; valeurs conseillées » row: the driver registered the scope command, but the
; shared menu declaration drew no row for it. The declaration has one now, for
; Windows and Linux (macOS keeps its key combinations in the Karabiner settings,
; which only the Configuration restore composes so far). The Layout submenu had
; the same gap and gets the same row, for Windows and macOS. Both gained the
; « Tout effacer » row beside it on 2026-09-30 (menu-first-group).

; The text of the row at a zero-based position of a native menu.
_SRR_LabelAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
	Assert(Length >= 0, "GetMenuStringW must read row " . Position)
	Text := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Text, "int", Length + 1, "uint", MF_BYPOSITION, "int")
	return StrGet(Text, "UTF-16")
}

; The submenu builder draws its declaration with the commands of the factory,
; and the declaration holds a Windows scope row labelled by the shared key
; that dispatches the factory's scope command.
; @param {String} Builder The function that builds the real submenu.
; @param {String} MenuKey The manifest menu.
; @param {String} Factory The command factory the builder uses.
; @param {String} Id The scope row: scope_restore or scope_clear.
_SRR_DeclaredRestoreRow(Builder, MenuKey, Factory, Id := "scope_restore") {
	global _MenuDispatchCallbacks
	Body := _StripFullLineComments(_DriverFuncBody(Builder))
	Assert(Body != "", Builder . " must be present in the driver source")
	AssertContains(Body, 'MenuRenderer_Build("' . MenuKey . '"')
	AssertContains(Body, Factory . "()")
	Commands := %Factory%()
	Rendered := Menu()
	try {
		AssertEqual(1, MenuRenderer_AppendCommand(Rendered, MenuKey, Id, Commands),
			MenuKey . " must declare the " . Id . " row for Windows")
		AssertEqual(t(Id == "scope_clear" ? "common.clear_to_system" : "common.restore_recommended"),
			_SRR_LabelAt(Rendered, 0))
		ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", 0, "uint")
		Assert(_MenuDispatchCallbacks.Has(ItemId), "the " . Id . " row must be dispatched")
		Assert(ObjPtr(_MenuDispatchCallbacks[ItemId]) == ObjPtr(Commands[Id]),
			"the " . Id . " row must run the scope command the submenu registers")
	} finally Rendered.Delete()
}

Test("shortcuts-restore-row: the Shortcuts submenu declares the restore row",
	_SRR_DeclaredRestoreRow.Bind("_BuildShortcutsSubmenu", "shortcuts_menu", "_SC_ScopeCommands"))
Test("shortcuts-restore-row: the drawn Shortcuts row restores the recommended scope",
	_ScopeShortcutsCase.Bind("recommended", true))
Test("shortcuts-restore-row: the Layout submenu declares the restore row",
	_SRR_DeclaredRestoreRow.Bind("_MI_StageLayout", "layout_menu", "_LAY_ScopeCommands"))
Test("menu-first-group: the Shortcuts submenu declares the clear row",
	_SRR_DeclaredRestoreRow.Bind("_BuildShortcutsSubmenu", "shortcuts_menu", "_SC_ScopeCommands", "scope_clear"))
Test("menu-first-group: the drawn Shortcuts clear row clears the scope",
	_ScopeShortcutsCase.Bind("clear", true))
Test("menu-first-group: the Layout submenu declares the clear row",
	_SRR_DeclaredRestoreRow.Bind("_MI_StageLayout", "layout_menu", "_LAY_ScopeCommands", "scope_clear"))

; The maintainer's request of 2026-09-30: « Taper un symbole encadre la
; sélection » (no AltGr: the symbols need not be there) and « Symboles
; encadrants » form one group. The manifest declares the pair with nothing
; between them, and the symbols provider returns their one row, no separator.
_SRR_WrapPairIsOneGroup() {
	Def := _MR_GetMenuDef("shortcuts_menu")
	At := 0
	for Index, Item in Def {
		if (_MR_Get(Item, "type") == "feature" && _MR_Get(Item, "path") == "shortcuts.wrap_text_if_selected")
			At := Index
	}
	Assert(At > 0 && At < Def.Length, "shortcuts_menu must declare the wrap toggle")
	AssertEqual("wrap_symbols_menu", _MR_Get(Def[At + 1], "id"), "the wrapping symbols follow the toggle directly")
	Rows := _SC_WrapSymbolRows()
	AssertEqual(1, Rows.Length, "the symbols provider returns one row")
	Assert(!Rows[1].Has("separator"), "no separator between the toggle and its symbols")
	AssertEqual(t("menu.shortcuts.wrap_symbols_title"), Rows[1]["label"])
	Assert(!InStr(t("shortcuts.label_wrap_text"), "AltGr"), "the toggle's label names no AltGr")
}
Test("menu-first-group: the wrap toggle and its symbols form one group", _SRR_WrapPairIsOneGroup)
