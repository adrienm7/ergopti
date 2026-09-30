; tests/unit/test_shortcuts_restore_row.ahk

; shortcuts-restore-row. The Windows Shortcuts submenu had no « Restaurer les
; valeurs conseillées » row: the driver registered the scope command, but the
; shared menu declaration drew no row for it. The declaration has one now, for
; Windows and Linux (macOS keeps its key combinations in the Karabiner settings,
; which only the Configuration restore composes so far). The Layout submenu had
; the same gap and gets the same row, for Windows and macOS.

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
; and the declaration holds a Windows restore row labelled by the shared key
; that dispatches the factory's scope command.
; @param {String} Builder The function that builds the real submenu.
; @param {String} MenuKey The manifest menu.
; @param {String} Factory The command factory the builder uses.
_SRR_DeclaredRestoreRow(Builder, MenuKey, Factory) {
	global _MenuDispatchCallbacks
	Body := _StripFullLineComments(_DriverFuncBody(Builder))
	Assert(Body != "", Builder . " must be present in the driver source")
	AssertContains(Body, 'MenuRenderer_Build("' . MenuKey . '"')
	AssertContains(Body, Factory . "()")
	Commands := %Factory%()
	Rendered := Menu()
	try {
		AssertEqual(1, MenuRenderer_AppendCommand(Rendered, MenuKey, "scope_restore", Commands),
			MenuKey . " must declare the restore row for Windows")
		AssertEqual(t("common.restore_recommended"), _SRR_LabelAt(Rendered, 0))
		ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", 0, "uint")
		Assert(_MenuDispatchCallbacks.Has(ItemId), "the restore row must be dispatched")
		Assert(ObjPtr(_MenuDispatchCallbacks[ItemId]) == ObjPtr(Commands["scope_restore"]),
			"the restore row must run the scope command the submenu registers")
	} finally Rendered.Delete()
}

Test("shortcuts-restore-row: the Shortcuts submenu declares the restore row",
	_SRR_DeclaredRestoreRow.Bind("_BuildShortcutsSubmenu", "shortcuts_menu", "_SC_ScopeCommands"))
Test("shortcuts-restore-row: the drawn Shortcuts row restores the recommended scope",
	_ScopeShortcutsCase.Bind("recommended", true))
Test("shortcuts-restore-row: the Layout submenu declares the restore row",
	_SRR_DeclaredRestoreRow.Bind("_MI_StageLayout", "layout_menu", "_LAY_ScopeCommands"))
