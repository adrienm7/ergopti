; tests/unit/test_tray_menu_separator_popup.ahk

; ==============================================================================
; MODULE: A row that opens a submenu is never read as a separator
; DESCRIPTION:
; GetMenuState answers, for a row that opens a submenu, the row's flags in its
; low byte and the NUMBER OF ROWS of that submenu in its high byte. The
; separator flag is 0x800, the fourth bit of that high byte: a submenu of 8 to
; 15 rows (or 24 to 31, and so on) read as a separator. The separator
; normaliser then deleted it wherever it ended a menu or followed a separator:
; the French « Touche ★ et expansion de texte » category, whose submenu has
; eight rows, was missing from Hotstrings › Français, so the category could not
; be switched back on from the tray (submenu-read-as-separator-2026-10-01).
; ==============================================================================

#Requires AutoHotkey v2.0

; A submenu of RowCount inert rows.
_TMSP_SubMenu(RowCount) {
	Sub := Menu()
	Loop RowCount
		Sub.Add("row " . A_Index, (*) => "")
	return Sub
}

_TMSP_PopupIsNeverASeparator() {
	Misread := ""
	Loop 40 {
		Parent := Menu()
		try {
			Parent.Add("first", (*) => "")
			Parent.Add()
			Parent.Add("opens " . A_Index, _TMSP_SubMenu(A_Index))
			AssertFalse(TrayMenuIsSeparatorAt(Parent, 0), "a plain row is no separator")
			AssertTrue(TrayMenuIsSeparatorAt(Parent, 1), "a separator is one")
			if TrayMenuIsSeparatorAt(Parent, 2)
				Misread .= (Misread = "" ? "" : ", ") . A_Index
		} finally Parent.Delete()
	}
	AssertEqual("", Misread,
		"a row that opens a submenu of this many rows was read as a separator: its row count sits in the high byte of GetMenuState")
}
Test("tray menu: a row that opens a submenu is never a separator, whatever its row count (submenu-read-as-separator-2026-10-01)",
	_TMSP_PopupIsNeverASeparator)

; The user-visible failure: the normaliser deleted the last row of a menu, or a
; row after a separator, when that row opened a submenu of eight rows.
_TMSP_NormaliserKeepsSubmenuRows() {
	for _, RowCount in [8, 9, 15, 24] {
		Parent := Menu()
		try {
			Parent.Add("switch", (*) => "")
			Parent.Add()
			Parent.Add("opens " . RowCount, _TMSP_SubMenu(RowCount))
			Parent.Add("second", _TMSP_SubMenu(2))
			Parent.Add("last opens " . RowCount, _TMSP_SubMenu(RowCount))
			_MR_NormalizeSeparators(Parent)
			AssertEqual(5, TrayMenuItemCount(Parent),
				"no row may be deleted: both rows opening a submenu of " . RowCount . " rows must stay")
		} finally Parent.Delete()
	}
	Parent := Menu()
	try {
		Parent.Add()
		Parent.Add("only", (*) => "")
		Parent.Add()
		Parent.Add()
		Parent.Add("opens", _TMSP_SubMenu(8))
		Parent.Add()
		_MR_NormalizeSeparators(Parent)
		AssertEqual(3, TrayMenuItemCount(Parent), "leading, doubled and trailing separators still go")
		AssertTrue(TrayMenuIsSeparatorAt(Parent, 1), "the one separator between two rows stays")
	} finally Parent.Delete()
}
Test("tray menu: the separator normaliser keeps a row that opens a submenu of eight rows (submenu-read-as-separator-2026-10-01)",
	_TMSP_NormaliserKeepsSubmenuRows)
