; static/ergopti_plus/windows/tests/unit/test_shortcuts_menu_blocks.ahk

; ==============================================================================
; MODULE: Shortcuts Menu Blocks And Screenshot Label
; DESCRIPTION:
; Two reported defects of the Shortcuts submenu.
;
; 1. The rows acting on typed or selected text (wrap a selection, type a framed
;    symbol) ran straight into the user's Alt / Ctrl / Ctrl+Shift / Win groups
;    with no separator: the "---" between them was declared for Linux only.
; 2. The instant-screenshot row read « Capture d'ecran instantanee » without
;    naming its key. Its legend differs per layout, so the label names it by
;    position, and it no longer shares the macOS at_hash hotkey label.
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

_SMB_ScreenshotLabelNamesItsKey() {
	Entry := ManifestFindEntryByPath("shortcuts.screen_instant")
	Assert(Entry is Map, "shortcuts.screen_instant must be declared in the features manifest")
	Assert(Entry["description_key"] == "menu.shortcuts.screen_instant",
		"the screenshot row needs its own label naming the key, not the shared at_hash label")
}
Test("shortcuts menu: the instant screenshot row names its key (shortcuts-menu-blocks)",
	_SMB_ScreenshotLabelNamesItsKey)
