; tests/unit/tray/test_menu_font.ahk

; ==============================================================================
; MODULE: Tray Menu Reading Font Tests
; DESCRIPTION:
; Drives tray/adapters/menu_font.ahk against real Win32 menus and real GDI: with
; a reading font every text row becomes owner-drawn (MFT_OWNERDRAW) and keeps
; its string, separators stay Windows', the default font gives every row back,
; a face from menu_faces.json loads privately, a row measures and paints in it
; (checked, selected, disabled), a mnemonic key finds its row, and a menu
; outside the tray tree is never touched. The boot and every rebuild install
; the popup handler after the menu population's.
;
; ROOT CAUSE ENCODED: the tray menu was drawn by Windows in the system menu
; font, whatever reading font the reader chose for the windows.
; ==============================================================================

#Requires AutoHotkey v2.0

; MENUITEMINFOW fType bits read back by the tests.
global _TMF_MFT_OWNERDRAW := 0x100
global _TMF_MFT_SEPARATOR := 0x800

; Runs Body with a fresh module state and the given reading font, then
; restores both and withdraws the handlers the fresh state registered.
_TMF_With(Font, Body) {
	global _TrayMenuFont, _ReadingPrefsValues
	SavedState := _TrayMenuFont
	SavedPrefs := _ReadingPrefsValues
	_TrayMenuFont := 0
	_ReadingPrefsValues := Map(ConfigLeaf.READING_FONT, Font,
		ConfigLeaf.READING_SPACING, ReadingPrefs_Default(ConfigLeaf.READING_SPACING))
	try {
		AssertTrue(TrayMenuFont_Init(), "the tray menu font initialises once")
		AssertFalse(TrayMenuFont_Init(), "a second initialisation is refused")
		Body()
	} finally {
		OnMessage(TRAY_MENU_FONT_WM_MEASUREITEM, TrayMenuFont_OnMeasureItem, 0)
		OnMessage(TRAY_MENU_FONT_WM_DRAWITEM, TrayMenuFont_OnDrawItem, 0)
		OnMessage(TRAY_MENU_FONT_WM_MENUCHAR, TrayMenuFont_OnMenuChar, 0)
		OnMessage(TRAY_MENU_FONT_WM_INITMENUPOPUP, TrayMenuFont_OnInitPopup, 0)
		_TrayMenuFont := SavedState
		_ReadingPrefsValues := SavedPrefs
	}
}

; A native menu: two text rows around a separator, the second checked.
_TMF_Menu() {
	M := Menu()
	M.Add("&Quit", (*) => 0)
	M.Add()
	M.Add("Re&load`tCtrl+R", (*) => 0)
	M.Check("Re&load`tCtrl+R")
	return M
}

; The fType of a row.
_TMF_Type(Handle, Position) {
	Item := _TrayMenuFont_ReadItem(Handle, Position)
	AssertTrue(IsObject(Item), "row " . Position . " reads back")
	return Item.Type
}

_TMF_OwnerDrawsAndGivesBack() {
	_TMF_With("dyslexic", () => _TMF_OwnerDrawsAndGivesBackBody())
}
_TMF_OwnerDrawsAndGivesBackBody() {
	M := _TMF_Menu()
	Face := _TrayMenuFont_Face("dyslexic")
	AssertTrue(IsObject(Face), "the dyslexic face is named and loaded")
	AssertEqual(2, TrayMenuFont_ConvertPopup(M.Handle, Face), "both text rows are owner-drawn")
	AssertTrue(_TMF_Type(M.Handle, 0) & _TMF_MFT_OWNERDRAW, "a text row is owner-drawn")
	AssertTrue(_TMF_Type(M.Handle, 1) & _TMF_MFT_SEPARATOR, "the separator stays a separator")
	AssertFalse(_TMF_Type(M.Handle, 1) & _TMF_MFT_OWNERDRAW, "the separator stays Windows'")
	AssertEqual("Re&load`tCtrl+R", _TrayMenuFont_ReadItem(M.Handle, 2).Text, "the row keeps its string")
	AssertEqual(2, TrayMenuFont_ConvertPopup(M.Handle, Face), "a second opening converts nothing twice")
	AssertEqual(0, TrayMenuFont_ConvertPopup(M.Handle, 0), "the default font owner-draws nothing")
	AssertFalse(_TMF_Type(M.Handle, 0) & _TMF_MFT_OWNERDRAW, "the default font gives the row back")
	AssertFalse(_TMF_Type(M.Handle, 2) & _TMF_MFT_OWNERDRAW, "every row is given back")
	AssertEqual(0, _TrayMenuFont_ReadItem(M.Handle, 0).Data, "the item data is cleared")
}
Test("tray menu font: a reading font owner-draws the text rows, the default gives them back (reading-font-menus)",
	_TMF_OwnerDrawsAndGivesBack)

_TMF_FacesLoad() {
	_TMF_With("hyperlegible", () => (
		AssertEqual(0, _TrayMenuFont_Face("default"), "the default font has no face"),
		_TMF_FacesLoadBody()))
}
_TMF_FacesLoadBody() {
	for Font, Family in Map("hyperlegible", "Atkinson Hyperlegible", "dyslexic", "OpenDyslexic") {
		Face := _TrayMenuFont_Face(Font)
		AssertTrue(IsObject(Face), Font . " has a face")
		AssertEqual(Family, Face.Family, Font . " is selected by its family")
		AssertTrue(RegExMatch(Face.Path, "i)\.(ttf|otf)$"), Font . ": an sfnt file, never the WOFF2")
		AssertTrue(_TrayMenuFont_Handle(Face.Family) != 0, Font . ": GDI creates the menu font")
	}
}
Test("tray menu font: each reading font's face loads privately from menu_faces.json (reading-font-menus)",
	_TMF_FacesLoad)

_TMF_MeasuresAndPaints() {
	_TMF_With("dyslexic", () => _TMF_MeasuresAndPaintsBody())
}
_TMF_MeasuresAndPaintsBody() {
	global _TrayMenuFont
	M := _TMF_Menu()
	Face := _TrayMenuFont_Face("dyslexic")
	_TrayMenuFont_Handle(Face.Family)
	TrayMenuFont_ConvertPopup(M.Handle, Face)
	Token := _TrayMenuFont_ReadItem(M.Handle, 2).Data
	AssertTrue(_TrayMenuFont.Items.Has(Token), "the row's item data names it")
	P := A_PtrSize
	Measure := Buffer(P == 8 ? 32 : 24, 0)
	NumPut("uint", 1, Measure, 0)
	NumPut("uptr", Token, Measure, P == 8 ? 24 : 20)
	AssertTrue(TrayMenuFont_OnMeasureItem(0, Measure.Ptr, TRAY_MENU_FONT_WM_MEASUREITEM, A_ScriptHwnd) == true,
		"the row is measured here")
	Width := NumGet(Measure, 12, "uint"), Height := NumGet(Measure, 16, "uint")
	AssertTrue(Width > 0 && Height > 0, "the row has a size")
	NumPut("uptr", 0, Measure, P == 8 ? 24 : 20)
	AssertEqual("", TrayMenuFont_OnMeasureItem(0, Measure.Ptr, TRAY_MENU_FONT_WM_MEASUREITEM, A_ScriptHwnd),
		"a row this module did not convert is left to its owner")
	Screen := DllCall("GetDC", "ptr", 0, "ptr")
	Dc := DllCall("gdi32\CreateCompatibleDC", "ptr", Screen, "ptr")
	Bitmap := DllCall("gdi32\CreateCompatibleBitmap", "ptr", Screen, "int", Width, "int", Height, "ptr")
	DllCall("ReleaseDC", "ptr", 0, "ptr", Screen)
	Previous := DllCall("gdi32\SelectObject", "ptr", Dc, "ptr", Bitmap, "ptr")
	try {
		; ODS_SELECTED | ODS_CHECKED, then ODS_GRAYED | ODS_NOACCEL.
		for State in [0x1 | 0x8, 0x2 | 0x100] {
			Draw := Buffer(P == 8 ? 64 : 48, 0)
			NumPut("uint", 1, Draw, 0)
			NumPut("uint", State, Draw, 16)
			NumPut("ptr", Dc, Draw, P == 8 ? 32 : 24)
			NumPut("int", 0, "int", 0, "int", Width, "int", Height, Draw, P == 8 ? 40 : 28)
			NumPut("uptr", Token, Draw, P == 8 ? 56 : 44)
			AssertTrue(TrayMenuFont_OnDrawItem(0, Draw.Ptr, TRAY_MENU_FONT_WM_DRAWITEM, A_ScriptHwnd) == true,
				"the row is painted here in state " . State)
		}
	} finally {
		DllCall("gdi32\SelectObject", "ptr", Dc, "ptr", Previous)
		DllCall("gdi32\DeleteObject", "ptr", Bitmap)
		DllCall("gdi32\DeleteDC", "ptr", Dc)
	}
}
Test("tray menu font: an owner-drawn row measures and paints in its face (reading-font-menus)",
	_TMF_MeasuresAndPaints)

_TMF_Mnemonics() {
	_TMF_With("dyslexic", () => _TMF_MnemonicsBody())
}
_TMF_MnemonicsBody() {
	M := _TMF_Menu()
	TrayMenuFont_ConvertPopup(M.Handle, _TrayMenuFont_Face("dyslexic"))
	AssertEqual(0, TrayMenuFont_MnemonicPosition(M.Handle, "q"), "Q runs &Quit")
	AssertEqual(2, TrayMenuFont_MnemonicPosition(M.Handle, "L"), "L runs Re&load, whatever its case")
	AssertEqual(-1, TrayMenuFont_MnemonicPosition(M.Handle, "c"), "the accelerator column names no mnemonic")
	AssertEqual((2 << 16) | 2, TrayMenuFont_OnMenuChar(Ord("l"), M.Handle, TRAY_MENU_FONT_WM_MENUCHAR, A_ScriptHwnd),
		"WM_MENUCHAR executes the row (MNC_EXECUTE)")
}
Test("tray menu font: a mnemonic key runs its owner-drawn row (reading-font-menus)", _TMF_Mnemonics)

_TMF_OnlyTheTray() {
	_TMF_With("dyslexic", () => _TMF_OnlyTheTrayBody())
}
_TMF_OnlyTheTrayBody() {
	M := _TMF_Menu()
	TrayMenuFont_OnInitPopup(M.Handle, 0, TRAY_MENU_FONT_WM_INITMENUPOPUP, A_ScriptHwnd)
	AssertFalse(_TMF_Type(M.Handle, 0) & _TMF_MFT_OWNERDRAW, "a menu outside the tray tree is never touched")
}
Test("tray menu font: only menus of the tray tree are owner-drawn (reading-font-menus)", _TMF_OnlyTheTray)

_TMF_HandlerOrder() {
	Install := _DriverFuncBody("TrayMenuFont_Install")
	Assert(Install != "", "TrayMenuFont_Install is found")
	RemoveAt := InStr(Install, "TrayMenuFont_OnInitPopup, 0)")
	AppendAt := InStr(Install, "TrayMenuFont_OnInitPopup, 1)")
	AssertTrue(RemoveAt > 0 && AppendAt > RemoveAt, "the popup handler is withdrawn, then appended last")
	Rebuild := _DriverFuncBody("RebuildTrayMenu")
	Assert(Rebuild != "", "RebuildTrayMenu is found")
	AssertTrue(InStr(Rebuild, "TrayMenuFont_Install()") > InStr(Rebuild, "_TrayRootDrain()"),
		"every published rebuild re-appends the handler after the population's")
	Boot := FileRead(A_LineFile . "\..\..\..\..\ErgoptiPlus.ahk", "UTF-8")
	AssertTrue(InStr(Boot, "`nTrayMenuFont_Init()") > InStr(Boot, "`nReadingPrefs_Init(_IniCache)"),
		"the boot prepares the tray font once the reading choices are read")
}
Test("tray menu font: the boot and each rebuild put its popup handler last (reading-font-menus)", _TMF_HandlerOrder)
