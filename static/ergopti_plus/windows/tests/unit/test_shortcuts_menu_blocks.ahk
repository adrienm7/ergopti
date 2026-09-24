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
