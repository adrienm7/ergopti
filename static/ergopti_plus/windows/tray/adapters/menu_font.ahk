; tray/adapters/menu_font.ahk

; ==============================================================================
; MODULE: Tray Menu Reading Font (AutoHotkey)
; DESCRIPTION:
; Draws the tray menu in the reading font chosen in Configuration >
; Accessibility (script.reading_font), as the app's windows are (maintainer
; decision 2026-11-24). A Win32 menu draws its text in the system menu font
; only, so with a reading font set every text row of the tray tree becomes an
; owner-drawn item (MFT_OWNERDRAW): Windows asks its size (WM_MEASUREITEM) and
; has it painted (WM_DRAWITEM) here, in the face _shared/ui/fonts/
; menu_faces.json names, loaded for this process alone (AddFontResourceEx,
; FR_PRIVATE). With the default font nothing is owner-drawn: Windows draws the
; menu itself, exactly as before.
;
; FEATURES & RATIONALE:
; 1. Converted when shown: each tray popup is converted on WM_INITMENUPOPUP,
;    after the menu population has appended its deferred rows (its handler is
;    registered first; TrayMenuFont_Install re-appends this one after every
;    rebuild), so rows built late, renamed or rebuilt are drawn alike and a
;    change of font applies at the next opening. Only menus of the tray tree
;    are touched, never another menu of the script.
; 2. Native parts kept: the item keeps its string, command, state and
;    submenu. Windows still draws the submenu arrow after an owner-drawn item
;    and still handles the selection and the clicks; this module paints the
;    background, the check mark, the item's bitmap and the text. Mnemonics:
;    the item keeps its string, and WM_MENUCHAR maps a key to the row whose
;    `&` names it; the underline follows ODS_NOACCEL.
; 3. Native look: with visual styles, the MENU theme class draws the row's
;    background, hot and disabled states and check mark, and gives the text
;    colour; without them (classic, high contrast) the system colours do, and
;    the check is Marlett's. The driver does not opt its menus into dark mode,
;    so there is no dark menu to keep; a themed dark menu would come through
;    the same MENU class.
; 4. Explicit failure: a face that cannot be named, read or loaded is logged
;    once per font and the menu keeps the system font; an item whose item data
;    is already in use is left to Windows.
; ==============================================================================

#Requires AutoHotkey v2.0
; ReadingPrefs_Get names the chosen font.
#Include %A_LineFile%\..\..\..\core\ui\engine\webview\reading_preferences.ahk
; JsonParse reads menu_faces.json.
#Include %A_LineFile%\..\..\..\core\text\engine\json.ahk
; FSReadStrict reads it from disk.
#Include %A_LineFile%\..\..\..\core\fs\adapters\file_system.ahk

; Window messages this module answers.
global TRAY_MENU_FONT_WM_DRAWITEM := 0x002B
global TRAY_MENU_FONT_WM_MEASUREITEM := 0x002C
global TRAY_MENU_FONT_WM_INITMENUPOPUP := 0x0117
global TRAY_MENU_FONT_WM_MENUCHAR := 0x0120

; The module's state: 0 until TrayMenuFont_Init.
global _TrayMenuFont := 0





; =================================
; =================================
; ======= 1/ Initialisation =======
; =================================
; =================================

; Registers the menu messages once. Called at boot, after ReadingPrefs_Init.
; @returns {Boolean} False when called twice.
TrayMenuFont_Init() {
	global _TrayMenuFont
	if IsObject(_TrayMenuFont) {
		LoggerError("TrayMenuFont", "The tray menu font was initialised twice; the second call is refused.")
		return false
	}
	LoggerStart("TrayMenuFont", "Preparing the tray menu's reading font…")
	_TrayMenuFont := {
		Items: Map(),        ; item data token -> { Menu, Position, Text, Bitmap }
		MenuTokens: Map(),   ; HMENU -> [tokens] of its converted rows
		MenuFaces: Map(),    ; HMENU -> family its rows were last measured in
		Faces: 0,            ; menu_faces.json "faces", read once
		NextToken: 1,
		TrayHandles: Map(),  ; HMENU of the tray tree, refreshed on a miss
		Loaded: Map(),       ; face file -> true once AddFontResourceEx took it
		Refused: Map(),      ; font -> reason, logged once
		FontKey: "",
		Font: 0,
		CheckFont: 0,
		Theme: 0,
		ThemeOpened: false
	}
	OnMessage(TRAY_MENU_FONT_WM_MEASUREITEM, TrayMenuFont_OnMeasureItem)
	OnMessage(TRAY_MENU_FONT_WM_DRAWITEM, TrayMenuFont_OnDrawItem)
	OnMessage(TRAY_MENU_FONT_WM_MENUCHAR, TrayMenuFont_OnMenuChar)
	TrayMenuFont_Install()
	LoggerSuccess("TrayMenuFont", "Tray menu font ready ({1}).", ReadingPrefs_Get(ConfigLeaf.READING_FONT))
	return true
}

; Puts the popup handler after every other WM_INITMENUPOPUP handler, so the
; deferred rows are appended before they are converted. Called by the boot and
; after each tray rebuild, which may have registered the population's handler.
; Also forgets the tray tree, the theme and the font, which a rebuild or a
; settings change may have replaced.
TrayMenuFont_Install() {
	global _TrayMenuFont
	if !IsObject(_TrayMenuFont)
		return false
	OnMessage(TRAY_MENU_FONT_WM_INITMENUPOPUP, TrayMenuFont_OnInitPopup, 0)
	OnMessage(TRAY_MENU_FONT_WM_INITMENUPOPUP, TrayMenuFont_OnInitPopup, 1)
	_TrayMenuFont.TrayHandles := Map()
	_TrayMenuFont.FontKey := ""
	_TrayMenuFont_ReleaseTheme()
	; A rebuild destroys the menus it replaced: forget their rows.
	for Handle, Tokens in _TrayMenuFont.MenuTokens.Clone() {
		if DllCall("IsMenu", "ptr", Handle, "int")
			continue
		for Token in Tokens
			if _TrayMenuFont.Items.Has(Token)
				_TrayMenuFont.Items.Delete(Token)
		_TrayMenuFont.MenuTokens.Delete(Handle)
		if _TrayMenuFont.MenuFaces.Has(Handle)
			_TrayMenuFont.MenuFaces.Delete(Handle)
	}
	return true
}





; ================================
; ================================
; ======= 2/ Font and Face =======
; ================================
; ================================

; The face of the chosen reading font, loaded for this process.
; @returns {Object|Integer} { Family, Path }, 0 for the default font or a refused face.
_TrayMenuFont_Face(Font) {
	global _TrayMenuFont, _SharedDir
	static FR_PRIVATE := 0x10
	if (Font == ReadingPrefs_Default(ConfigLeaf.READING_FONT))
		return 0
	if _TrayMenuFont.Refused.Has(Font)
		return 0
	try {
		Fonts := _SharedDir . "\ui\fonts"
		if !(_TrayMenuFont.Faces is Map)
			_TrayMenuFont.Faces := JsonParse(FSReadStrict(Fonts . "\menu_faces.json"))["faces"]
		Faces := _TrayMenuFont.Faces
		if !(Faces is Map) || !Faces.Has(Font)
			throw ValueError("menu_faces.json declares no face for " . Font)
		Face := Faces[Font]
		Path := Fonts . "\" . StrReplace(Face["file"], "/", "\")
		if !FileExist(Path)
			throw OSError(2, -1, "the face " . Path . " is missing")
		if !_TrayMenuFont.Loaded.Has(Path) {
			if DllCall("gdi32\AddFontResourceExW", "wstr", Path, "uint", FR_PRIVATE, "ptr", 0, "int") <= 0
				throw OSError(A_LastError, -1, "AddFontResourceEx refused " . Path)
			_TrayMenuFont.Loaded[Path] := true
			LoggerInfo("TrayMenuFont", "Loaded the tray menu face {1}.", Path)
		}
		return { Family: Face["family"], Path: Path }
	} catch as Err {
		_TrayMenuFont.Refused[Font] := Err.Message
		LoggerError("TrayMenuFont", "The tray menu keeps the system font: {1}.", Err.Message)
		return 0
	}
}

; The HFONT of a face at the system menu font's size and weight.
; @param Family {String} The face's family name (menu_faces.json).
; @returns {Integer} HFONT, 0 when Windows refused it.
_TrayMenuFont_Handle(Family) {
	global _TrayMenuFont
	if (_TrayMenuFont.FontKey == Family) && _TrayMenuFont.Font
		return _TrayMenuFont.Font
	; NONCLIENTMETRICSW (Vista and later) holds lfMenuFont, a LOGFONTW.
	static SPI_GETNONCLIENTMETRICS := 0x29, METRICS_SIZE := 504, MENU_FONT := 224
	static LOGFONT_SIZE := 92, CHAR_SET := 23, FACE_NAME := 28, FACE_CHARS := 32, SYMBOL_CHARSET := 2
	Metrics := Buffer(METRICS_SIZE, 0)
	NumPut("uint", METRICS_SIZE, Metrics, 0)
	if !DllCall("SystemParametersInfoW", "uint", SPI_GETNONCLIENTMETRICS, "uint", METRICS_SIZE, "ptr", Metrics, "uint", 0)
		throw OSError(A_LastError, -1, "SystemParametersInfo gave no menu font")
	LogFont := Buffer(LOGFONT_SIZE, 0)
	DllCall("RtlMoveMemory", "ptr", LogFont, "ptr", Metrics.Ptr + MENU_FONT, "uptr", LOGFONT_SIZE)
	StrPut(SubStr(Family, 1, FACE_CHARS - 1), LogFont.Ptr + FACE_NAME, FACE_CHARS, "UTF-16")
	Handle := DllCall("gdi32\CreateFontIndirectW", "ptr", LogFont, "ptr")
	if !Handle
		throw OSError(A_LastError, -1, "CreateFontIndirect refused " . Family)
	if _TrayMenuFont.Font
		DllCall("gdi32\DeleteObject", "ptr", _TrayMenuFont.Font)
	_TrayMenuFont.Font := Handle
	_TrayMenuFont.FontKey := Family
	if !_TrayMenuFont.CheckFont {
		; The classic check mark is Marlett's « a », at the menu font's height.
		StrPut("Marlett", LogFont.Ptr + FACE_NAME, FACE_CHARS, "UTF-16")
		NumPut("uchar", SYMBOL_CHARSET, LogFont, CHAR_SET)
		_TrayMenuFont.CheckFont := DllCall("gdi32\CreateFontIndirectW", "ptr", LogFont, "ptr")
	}
	return Handle
}

; The MENU visual style of the script window, 0 without visual styles.
_TrayMenuFont_Theme() {
	global _TrayMenuFont
	if !_TrayMenuFont.ThemeOpened {
		_TrayMenuFont.ThemeOpened := true
		_TrayMenuFont.Theme := DllCall("uxtheme\IsThemeActive", "int")
			? DllCall("uxtheme\OpenThemeData", "ptr", A_ScriptHwnd, "wstr", "MENU", "ptr") : 0
	}
	return _TrayMenuFont.Theme
}

_TrayMenuFont_ReleaseTheme() {
	global _TrayMenuFont
	if _TrayMenuFont.Theme
		DllCall("uxtheme\CloseThemeData", "ptr", _TrayMenuFont.Theme)
	_TrayMenuFont.Theme := 0
	_TrayMenuFont.ThemeOpened := false
}





; ==================================
; ==================================
; ======= 3/ Item Conversion =======
; ==================================
; ==================================

; MENUITEMINFOW field offsets for this process's pointer size.
_TrayMenuFont_InfoLayout() {
	static Layout := 0
	if IsObject(Layout)
		return Layout
	P := A_PtrSize
	SubMenu := (P == 8) ? 24 : 20
	TypeData := SubMenu + 4 * P
	Count := TypeData + P
	Bitmap := Count + P
	Layout := { Size: Bitmap + P, Type: 8, State: 12, SubMenu: SubMenu, Data: SubMenu + 3 * P,
		TypeData: TypeData, Count: Count, Bitmap: Bitmap }
	return Layout
}

; Reads one row of a native menu.
; @returns {Object|Integer} { Type, Data, Text, Bitmap }, 0 when unreadable.
_TrayMenuFont_ReadItem(Handle, Position) {
	static MIIM_STATE := 0x1, MIIM_SUBMENU := 0x4, MIIM_DATA := 0x20, MIIM_STRING := 0x40
	static MIIM_BITMAP := 0x80, MIIM_FTYPE := 0x100
	L := _TrayMenuFont_InfoLayout()
	Info := Buffer(L.Size, 0)
	NumPut("uint", L.Size, Info, 0)
	NumPut("uint", MIIM_STATE | MIIM_SUBMENU | MIIM_DATA | MIIM_STRING | MIIM_BITMAP | MIIM_FTYPE, Info, 4)
	if !DllCall("GetMenuItemInfoW", "ptr", Handle, "uint", Position, "int", true, "ptr", Info)
		return 0
	Chars := NumGet(Info, L.Count, "uint")
	Text := ""
	if (Chars > 0) {
		Buf := Buffer((Chars + 1) * 2, 0)
		NumPut("ptr", Buf.Ptr, Info, L.TypeData)
		NumPut("uint", Chars + 1, Info, L.Count)
		if DllCall("GetMenuItemInfoW", "ptr", Handle, "uint", Position, "int", true, "ptr", Info)
			Text := StrGet(Buf, "UTF-16")
	}
	return { Type: NumGet(Info, L.Type, "uint"), Data: NumGet(Info, L.Data, "uptr"), Text: Text,
		Bitmap: NumGet(Info, L.Bitmap, "uptr") }
}

; Sets a row's type flags and item data.
_TrayMenuFont_WriteItem(Handle, Position, TypeFlags, Data) {
	static MIIM_DATA := 0x20, MIIM_FTYPE := 0x100
	L := _TrayMenuFont_InfoLayout()
	Info := Buffer(L.Size, 0)
	NumPut("uint", L.Size, Info, 0)
	NumPut("uint", MIIM_DATA | MIIM_FTYPE, Info, 4)
	NumPut("uint", TypeFlags, Info, L.Type)
	NumPut("uptr", Data, Info, L.Data)
	return DllCall("SetMenuItemInfoW", "ptr", Handle, "uint", Position, "int", true, "ptr", Info) != 0
}

; Whether a native menu belongs to the tray tree. The tree is walked again on
; a miss, since a deferred row may have attached a new submenu.
_TrayMenuFont_IsTray(Handle) {
	global _TrayMenuFont
	if _TrayMenuFont.TrayHandles.Has(Handle)
		return true
	Handles := Map()
	_TrayMenuFont_Collect(A_TrayMenu.Handle, Handles)
	_TrayMenuFont.TrayHandles := Handles
	return Handles.Has(Handle)
}

_TrayMenuFont_Collect(Handle, Handles) {
	if !Handle || Handles.Has(Handle)
		return
	Handles[Handle] := true
	Count := DllCall("GetMenuItemCount", "ptr", Handle, "int")
	loop Max(Count, 0)
		_TrayMenuFont_Collect(DllCall("GetSubMenu", "ptr", Handle, "int", A_Index - 1, "ptr"), Handles)
}

; Owner-draws every text row of one popup in the face, or gives the rows back
; to Windows when the default font is chosen.
; @param Handle {Integer} The popup's HMENU.
; @param Face {Object|Integer} From _TrayMenuFont_Face, 0 for the default.
; @returns {Integer} The rows now owner-drawn.
TrayMenuFont_ConvertPopup(Handle, Face) {
	global _TrayMenuFont
	static MFT_SEPARATOR := 0x800, MFT_OWNERDRAW := 0x100
	if !IsObject(Face) && !_TrayMenuFont.MenuTokens.Has(Handle)
		return 0
	Tokens := _TrayMenuFont.MenuTokens.Get(Handle, [])
	; Windows keeps a row's measured size until the row changes: rows measured
	; in another face are written again, so they are measured in this one.
	Remeasure := IsObject(Face) && (_TrayMenuFont.MenuFaces.Get(Handle, "") != Face.Family)
	Owned := Map()
	for Token in Tokens
		Owned[Token] := true
	Fresh := []
	Count := DllCall("GetMenuItemCount", "ptr", Handle, "int")
	loop Max(Count, 0) {
		Position := A_Index - 1
		Item := _TrayMenuFont_ReadItem(Handle, Position)
		if !IsObject(Item) || (Item.Type & MFT_SEPARATOR)
			continue
		Ours := Owned.Has(Item.Data)
		if !IsObject(Face) {
			if Ours
				_TrayMenuFont_WriteItem(Handle, Position, Item.Type & ~MFT_OWNERDRAW, 0)
			continue
		}
		if (Item.Data != 0) && !Ours
			continue
		Token := Ours ? Item.Data : _TrayMenuFont.NextToken++
		if (!Ours || Remeasure) && !_TrayMenuFont_WriteItem(Handle, Position, Item.Type | MFT_OWNERDRAW, Token) {
			LoggerError("TrayMenuFont", "Row '{1}' could not be owner-drawn (error {2}); Windows draws it.",
				Item.Text, A_LastError)
			continue
		}
		_TrayMenuFont.Items[Token] := { Menu: Handle, Position: Position, Text: Item.Text, Bitmap: Item.Bitmap }
		Fresh.Push(Token)
	}
	for Token in Tokens
		if (!IsObject(Face) || !_TrayMenuFont_HasToken(Fresh, Token)) && _TrayMenuFont.Items.Has(Token)
			_TrayMenuFont.Items.Delete(Token)
	if IsObject(Face) {
		_TrayMenuFont.MenuTokens[Handle] := Fresh
		_TrayMenuFont.MenuFaces[Handle] := Face.Family
	} else {
		_TrayMenuFont.MenuTokens.Delete(Handle)
		if _TrayMenuFont.MenuFaces.Has(Handle)
			_TrayMenuFont.MenuFaces.Delete(Handle)
	}
	return IsObject(Face) ? Fresh.Length : 0
}

_TrayMenuFont_HasToken(Tokens, Token) {
	for Each in Tokens
		if (Each == Token)
			return true
	return false
}

; WM_INITMENUPOPUP: converts a tray popup before Windows measures it.
TrayMenuFont_OnInitPopup(wParam, lParam, Msg, Hwnd) {
	global _TrayMenuFont
	if !IsObject(_TrayMenuFont)
		return
	Font := ReadingPrefs_Get(ConfigLeaf.READING_FONT)
	; The default font with nothing to give back costs no menu read at all.
	if (Font == ReadingPrefs_Default(ConfigLeaf.READING_FONT)) && (_TrayMenuFont.MenuTokens.Count == 0)
		return
	if !_TrayMenuFont_IsTray(wParam)
		return
	Face := _TrayMenuFont_Face(Font)
	if IsObject(Face) {
		try _TrayMenuFont_Handle(Face.Family)
		catch as Err {
			_TrayMenuFont.Refused[Font] := Err.Message
			LoggerError("TrayMenuFont", "The tray menu keeps the system font: {1}.", Err.Message)
			Face := 0
		}
	}
	TrayMenuFont_ConvertPopup(wParam, Face)
}





; ===================================
; ===================================
; ======= 4/ Measure and Draw =======
; ===================================
; ===================================

; The row text before and after its tab (the accelerator column).
_TrayMenuFont_Split(Text) {
	Tab := InStr(Text, "`t")
	return Tab ? [SubStr(Text, 1, Tab - 1), SubStr(Text, Tab + 1)] : [Text, ""]
}

; Pixel metrics of the row layout, from the system's check-mark size.
_TrayMenuFont_Metrics() {
	static SM_CXMENUCHECK := 71, SM_CYMENUCHECK := 72
	Check := DllCall("GetSystemMetrics", "int", SM_CXMENUCHECK, "int")
	Pad := Max(2, Check // 4)
	return { Check: Check, CheckHeight: DllCall("GetSystemMetrics", "int", SM_CYMENUCHECK, "int"),
		Pad: Pad, Gutter: Check + 4 * Pad, Arrow: Check + 2 * Pad }
}

; The width and height of a text in the module's font.
_TrayMenuFont_TextSize(Dc, Text) {
	static DT_CALCRECT := 0x400, DT_SINGLELINE := 0x20
	Rect := Buffer(16, 0)
	DllCall("DrawTextW", "ptr", Dc, "wstr", Text == "" ? " " : Text, "int", -1, "ptr", Rect,
		"uint", DT_CALCRECT | DT_SINGLELINE)
	return { W: Text == "" ? 0 : NumGet(Rect, 8, "int"), H: NumGet(Rect, 12, "int") }
}

; WM_MEASUREITEM: sizes an owner-drawn tray row.
TrayMenuFont_OnMeasureItem(wParam, lParam, Msg, Hwnd) {
	global _TrayMenuFont
	static ODT_MENU := 1
	if !IsObject(_TrayMenuFont) || NumGet(lParam, 0, "uint") != ODT_MENU
		return
	Token := NumGet(lParam, A_PtrSize == 8 ? 24 : 20, "uptr")
	if !_TrayMenuFont.Items.Has(Token) || !_TrayMenuFont.Font
		return
	Parts := _TrayMenuFont_Split(_TrayMenuFont.Items[Token].Text)
	M := _TrayMenuFont_Metrics()
	Dc := DllCall("GetDC", "ptr", 0, "ptr")
	Previous := DllCall("gdi32\SelectObject", "ptr", Dc, "ptr", _TrayMenuFont.Font, "ptr")
	Left := _TrayMenuFont_TextSize(Dc, Parts[1])
	Right := _TrayMenuFont_TextSize(Dc, Parts[2])
	DllCall("gdi32\SelectObject", "ptr", Dc, "ptr", Previous)
	DllCall("ReleaseDC", "ptr", 0, "ptr", Dc)
	Width := M.Gutter + Left.W + (Right.W ? 4 * M.Pad + Right.W : 0) + M.Arrow
	Height := Max(Left.H + 2 * M.Pad, M.CheckHeight + 2 * M.Pad)
	NumPut("uint", Width, lParam, 12)
	NumPut("uint", Height, lParam, 16)
	return true
}

; WM_DRAWITEM: paints an owner-drawn tray row.
TrayMenuFont_OnDrawItem(wParam, lParam, Msg, Hwnd) {
	global _TrayMenuFont
	static ODT_MENU := 1, ODS_SELECTED := 0x1, ODS_GRAYED := 0x2, ODS_DISABLED := 0x4
	static ODS_CHECKED := 0x8, ODS_NOACCEL := 0x100
	if !IsObject(_TrayMenuFont) || NumGet(lParam, 0, "uint") != ODT_MENU
		return
	P := A_PtrSize
	Token := NumGet(lParam, P == 8 ? 56 : 44, "uptr")
	if !_TrayMenuFont.Items.Has(Token) || !_TrayMenuFont.Font
		return
	State := NumGet(lParam, 16, "uint")
	Dc := NumGet(lParam, P == 8 ? 32 : 24, "ptr")
	RectOffset := P == 8 ? 40 : 28
	Rect := Buffer(16, 0)
	DllCall("RtlMoveMemory", "ptr", Rect, "ptr", lParam + RectOffset, "uptr", 16)
	Row := {
		Text: _TrayMenuFont.Items[Token].Text, Bitmap: _TrayMenuFont.Items[Token].Bitmap,
		Selected: (State & ODS_SELECTED) != 0, Disabled: (State & (ODS_GRAYED | ODS_DISABLED)) != 0,
		Checked: (State & ODS_CHECKED) != 0, HidePrefix: (State & ODS_NOACCEL) != 0
	}
	Saved := DllCall("gdi32\SaveDC", "ptr", Dc, "int")
	try _TrayMenuFont_Paint(Dc, Rect, Row)
	finally DllCall("gdi32\RestoreDC", "ptr", Dc, "int", Saved)
	return true
}

; Paints one row: background, check or bitmap, then the text columns.
_TrayMenuFont_Paint(Dc, Rect, Row) {
	global _TrayMenuFont
	static MENU_POPUPBACKGROUND := 9, MENU_POPUPCHECK := 11, MENU_POPUPCHECKBACKGROUND := 12
	static MENU_POPUPITEM := 14, MPI_NORMAL := 1, MPI_HOT := 2, MPI_DISABLED := 3, MPI_DISABLEDHOT := 4
	static MC_CHECKMARKNORMAL := 1, MC_CHECKMARKDISABLED := 2, MCB_DISABLED := 1, MCB_NORMAL := 2
	static TMT_TEXTCOLOR := 3803
	static COLOR_MENU := 4, COLOR_MENUTEXT := 7, COLOR_HIGHLIGHT := 13, COLOR_HIGHLIGHTTEXT := 14
	static COLOR_GRAYTEXT := 17, TRANSPARENT := 1
	static DT_LEFT := 0x0, DT_CENTER := 0x1, DT_RIGHT := 0x2, DT_VCENTER := 0x4, DT_SINGLELINE := 0x20
	static DT_HIDEPREFIX := 0x100000
	M := _TrayMenuFont_Metrics()
	Left := NumGet(Rect, 0, "int"), Top := NumGet(Rect, 4, "int")
	Right := NumGet(Rect, 8, "int"), Bottom := NumGet(Rect, 12, "int")
	CheckRect := Buffer(16, 0)
	CheckLeft := Left + (M.Gutter - M.Check) // 2
	CheckTop := Top + (Bottom - Top - M.CheckHeight) // 2
	NumPut("int", CheckLeft, "int", CheckTop, "int", CheckLeft + M.Check, "int", CheckTop + M.CheckHeight, CheckRect)
	Theme := _TrayMenuFont_Theme()
	if Theme {
		DllCall("uxtheme\DrawThemeBackground", "ptr", Theme, "ptr", Dc, "int", MENU_POPUPBACKGROUND, "int", 0,
			"ptr", Rect, "ptr", 0)
		ItemState := Row.Disabled ? (Row.Selected ? MPI_DISABLEDHOT : MPI_DISABLED)
			: (Row.Selected ? MPI_HOT : MPI_NORMAL)
		if Row.Selected
			DllCall("uxtheme\DrawThemeBackground", "ptr", Theme, "ptr", Dc, "int", MENU_POPUPITEM,
				"int", ItemState, "ptr", Rect, "ptr", 0)
		if Row.Checked {
			DllCall("uxtheme\DrawThemeBackground", "ptr", Theme, "ptr", Dc, "int", MENU_POPUPCHECKBACKGROUND,
				"int", Row.Disabled ? MCB_DISABLED : MCB_NORMAL, "ptr", CheckRect, "ptr", 0)
			DllCall("uxtheme\DrawThemeBackground", "ptr", Theme, "ptr", Dc, "int", MENU_POPUPCHECK,
				"int", Row.Disabled ? MC_CHECKMARKDISABLED : MC_CHECKMARKNORMAL, "ptr", CheckRect, "ptr", 0)
		}
		Color := 0
		if DllCall("uxtheme\GetThemeColor", "ptr", Theme, "int", MENU_POPUPITEM, "int", ItemState,
				"int", TMT_TEXTCOLOR, "uint*", &Color, "int") != 0
			Color := DllCall("GetSysColor", "int", Row.Disabled ? COLOR_GRAYTEXT : COLOR_MENUTEXT, "uint")
	} else {
		Highlight := Row.Selected && !Row.Disabled
		DllCall("FillRect", "ptr", Dc, "ptr", Rect,
			"ptr", DllCall("GetSysColorBrush", "int", Highlight ? COLOR_HIGHLIGHT : COLOR_MENU, "ptr"))
		Color := DllCall("GetSysColor", "int",
			Row.Disabled ? COLOR_GRAYTEXT : (Highlight ? COLOR_HIGHLIGHTTEXT : COLOR_MENUTEXT), "uint")
		if Row.Checked && _TrayMenuFont.CheckFont {
			DllCall("gdi32\SetBkMode", "ptr", Dc, "int", TRANSPARENT)
			DllCall("gdi32\SetTextColor", "ptr", Dc, "uint", Color)
			DllCall("gdi32\SelectObject", "ptr", Dc, "ptr", _TrayMenuFont.CheckFont)
			DllCall("DrawTextW", "ptr", Dc, "wstr", "a", "int", 1, "ptr", CheckRect,
				"uint", DT_CENTER | DT_VCENTER | DT_SINGLELINE)
		}
	}
	if !Row.Checked
		_TrayMenuFont_PaintBitmap(Dc, Row.Bitmap, CheckRect, Row.Disabled)
	DllCall("gdi32\SetBkMode", "ptr", Dc, "int", TRANSPARENT)
	DllCall("gdi32\SetTextColor", "ptr", Dc, "uint", Color)
	DllCall("gdi32\SelectObject", "ptr", Dc, "ptr", _TrayMenuFont.Font)
	Parts := _TrayMenuFont_Split(Row.Text)
	Flags := DT_VCENTER | DT_SINGLELINE | (Row.HidePrefix ? DT_HIDEPREFIX : 0)
	TextRect := Buffer(16, 0)
	NumPut("int", Left + M.Gutter, "int", Top, "int", Right - M.Arrow, "int", Bottom, TextRect)
	DllCall("DrawTextW", "ptr", Dc, "wstr", Parts[1], "int", -1, "ptr", TextRect, "uint", Flags | DT_LEFT)
	if (Parts[2] != "")
		DllCall("DrawTextW", "ptr", Dc, "wstr", Parts[2], "int", -1, "ptr", TextRect, "uint", Flags | DT_RIGHT)
}

; Paints a row's own bitmap (the manifest's row icon) in the check column.
_TrayMenuFont_PaintBitmap(Dc, Bitmap, CheckRect, Disabled) {
	; HBMMENU_* are small predefined values and -1 (HBMMENU_CALLBACK), not bitmaps.
	; NumGet reads a 64-bit HBMMENU_CALLBACK as -1, a 32-bit one as 0xFFFFFFFF.
	static HBMMENU_LAST := 11, HBMMENU_CALLBACK_32 := 0xFFFFFFFF
	static AC_SRC_ALPHA := 0x01, OPAQUE_ALPHA := 0xFF, FADED_ALPHA := 0x60
	if (Bitmap <= HBMMENU_LAST) || (Bitmap == HBMMENU_CALLBACK_32)
		return
	Info := Buffer(A_PtrSize == 8 ? 32 : 24, 0)
	if !DllCall("gdi32\GetObjectW", "ptr", Bitmap, "int", Info.Size, "ptr", Info, "int")
		return
	Width := NumGet(Info, 4, "int"), Height := Abs(NumGet(Info, 8, "int"))
	Bits := NumGet(Info, 18, "ushort")
	X := NumGet(CheckRect, 0, "int") + (NumGet(CheckRect, 8, "int") - NumGet(CheckRect, 0, "int") - Width) // 2
	Y := NumGet(CheckRect, 4, "int") + (NumGet(CheckRect, 12, "int") - NumGet(CheckRect, 4, "int") - Height) // 2
	Memory := DllCall("gdi32\CreateCompatibleDC", "ptr", Dc, "ptr")
	Previous := DllCall("gdi32\SelectObject", "ptr", Memory, "ptr", Bitmap, "ptr")
	try {
		; BLENDFUNCTION { AC_SRC_OVER, 0, constant alpha, alpha format }: a disabled row's icon is
		; faded. Only a 32-bit bitmap carries per-pixel alpha; an opaque constant alpha copies any
		; other depth unchanged, so no screen-capture-shaped blit reaches the compiled exe.
		Blend := ((Disabled ? FADED_ALPHA : OPAQUE_ALPHA) << 16) | ((Bits == 32 ? AC_SRC_ALPHA : 0) << 24)
		DllCall("msimg32\AlphaBlend", "ptr", Dc, "int", X, "int", Y, "int", Width, "int", Height,
			"ptr", Memory, "int", 0, "int", 0, "int", Width, "int", Height, "uint", Blend)
	} finally {
		DllCall("gdi32\SelectObject", "ptr", Memory, "ptr", Previous)
		DllCall("gdi32\DeleteDC", "ptr", Memory)
	}
}

; WM_MENUCHAR: a key pressed in an owner-drawn tray popup runs the row whose
; `&` names it, as Windows does for the rows it draws.
TrayMenuFont_OnMenuChar(wParam, lParam, Msg, Hwnd) {
	global _TrayMenuFont
	static MNC_EXECUTE := 2
	if !IsObject(_TrayMenuFont) || !_TrayMenuFont.MenuTokens.Has(lParam)
		return
	Position := TrayMenuFont_MnemonicPosition(lParam, Chr(wParam & 0xFFFF))
	if (Position < 0)
		return
	return (MNC_EXECUTE << 16) | Position
}

; The position of the converted row of a popup whose mnemonic is a key.
; @param Handle {Integer} The popup's HMENU.
; @param Key {String} The pressed character.
; @returns {Integer} The zero-based position, -1 when no row has it.
TrayMenuFont_MnemonicPosition(Handle, Key) {
	global _TrayMenuFont
	for Token in _TrayMenuFont.MenuTokens.Get(Handle, []) {
		Item := _TrayMenuFont.Items.Get(Token, 0)
		if !IsObject(Item)
			continue
		Text := StrReplace(_TrayMenuFont_Split(Item.Text)[1], "&&", "")
		At := InStr(Text, "&")
		if At && (StrLower(SubStr(Text, At + 1, 1)) == StrLower(Key))
			return Item.Position
	}
	return -1
}
