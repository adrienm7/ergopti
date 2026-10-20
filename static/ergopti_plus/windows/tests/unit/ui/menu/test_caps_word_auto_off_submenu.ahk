; tests/unit/ui/menu/test_caps_word_auto_off_submenu.ahk

; ==============================================================================
; MODULE: CapsWord Auto-Off Submenu
; DESCRIPTION:
; Renders « CapsWord : désactivation automatique » from caps_word_auto_off_group
; and checks its rows: the delay choice, one checkbox per catalogue delimiter
; with the catalogue's separators, one per pointer kind, the gesture row greyed
; on Windows, and a click that stores the setting.
; ==============================================================================

#Requires AutoHotkey v2.0




_CWSM_Rows() {
	Rows := []
	Menu := _SC_CapsWordAutoOffSubmenu()
	try {
		Count := DllCall("GetMenuItemCount", "ptr", Menu.Handle, "int")
		Loop Count {
			Buffer_ := Buffer(1024, 0)
			Length := DllCall("GetMenuStringW", "ptr", Menu.Handle, "uint", A_Index - 1, "ptr", Buffer_, "int", 512, "uint", 0x400, "int")
			State := DllCall("GetMenuState", "ptr", Menu.Handle, "uint", A_Index - 1, "uint", 0x400, "uint")
			Rows.Push(Map("label", StrGet(Buffer_, Length), "state", State,
				"id", DllCall("GetMenuItemID", "ptr", Menu.Handle, "int", A_Index - 1, "uint")))
		}
	} finally Menu.Delete()
	return Rows
}

_CWSM_RendersEveryRow() {
	Rows := _CWSM_Rows()
	Delimiters := 0, Separators := 0
	for Row in CapsWordAutoOffTerminatorRows()
		Row.Has("separator") ? Separators++ : Delimiters++
	Kinds := CapsWordAutoOffPointerKinds().Length
	; choice, ---, header, delimiters with separators, ---, header, pointer rows (+ greyed gesture)
	AssertEqual(1 + 1 + 1 + Delimiters + Separators + 1 + 1 + Kinds + 1, Rows.Length,
		"every declared row and every catalogue entry is drawn")
	Greyed := 0
	for Row in Rows {
		if (Row["state"] & 0x3) && InStr(Row["label"], t("menu.caps_word.pointer.gesture")) == 1
			Greyed++
	}
	AssertEqual(1, Greyed, "the gesture row is greyed with its reason on Windows")
	Values := CapsWordAutoOffValues()
	for Kind in CapsWordAutoOffPointerKinds() {
		Label := t("menu.caps_word.pointer." . Kind)
		Found := 0
		for Row in Rows {
			if Row["label"] == Label {
				Found++
				AssertEqual(Values["pointer"][Kind] == 1, (Row["state"] & 0x8) != 0, Kind . " tick follows its setting")
			}
		}
		AssertEqual(1, Found, Kind . " has exactly one row")
	}
}
Test("caps-word submenu: the delay, each delimiter and each pointer kind are drawn", _CWSM_RendersEveryRow)
