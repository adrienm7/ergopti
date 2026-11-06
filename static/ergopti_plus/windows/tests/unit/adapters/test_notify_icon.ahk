; tests/unit/adapters/test_notify_icon.ahk

; ==============================================================================
; MODULE: Notification Icon Adapter Tests
; DESCRIPTION:
; The WPM readout's notification icon (adapters/notify_icon.ahk) against the
; real shell and real GDI+: a painted number yields a usable icon handle at the
; shell's small-icon size, and an icon added beside the script window is
; reported by the shell until it is deleted, then can be added again, as after
; an Explorer restart.
; ==============================================================================

#Requires AutoHotkey v2.0

; An id distinct from the readout's own (0x4550) and AutoHotkey's (1028).
global _NIT_ICON_ID := 0x4551

_NIT_StartGdip() {
	static Token := 0
	if Token
		return true
	AssertTrue(DllCall("Kernel32\LoadLibraryW", "Str", "gdiplus.dll", "Ptr") != 0, "gdiplus.dll must load")
	Input := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
	NumPut("UInt", 1, Input, 0)
	AssertEqual(0, DllCall("gdiplus\GdiplusStartup", "Ptr*", &Token, "Ptr", Input, "Ptr", 0), "GDI+ must start")
	return true
}

; Whether the shell reports an icon for (A_ScriptHwnd, Id).
_NIT_ShellHasIcon(Id) {
	Ident := Buffer(A_PtrSize = 8 ? 40 : 28, 0)
	NumPut("UInt", Ident.Size, Ident, 0)
	NumPut("Ptr", A_ScriptHwnd, Ident, A_PtrSize = 8 ? 8 : 4)
	NumPut("UInt", Id, Ident, A_PtrSize = 8 ? 16 : 8)
	Rect := Buffer(16, 0)
	return DllCall("Shell32\Shell_NotifyIconGetRect", "Ptr", Ident, "Ptr", Rect, "Int") = 0
}

; The icon's colour bitmap width, from GetIconInfo.
_NIT_IconWidth(HIcon) {
	Info := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
	AssertTrue(DllCall("User32\GetIconInfo", "Ptr", HIcon, "Ptr", Info, "Int") != 0, "the handle must be an icon")
	MaskAt := A_PtrSize = 8 ? 16 : 12
	Mask := NumGet(Info, MaskAt, "Ptr"), Colour := NumGet(Info, MaskAt + A_PtrSize, "Ptr")
	try {
		Bitmap := Buffer(A_PtrSize = 8 ? 32 : 24, 0)
		AssertTrue(DllCall("Gdi32\GetObjectW", "Ptr", Colour, "Int", Bitmap.Size, "Ptr", Bitmap, "Int") > 0)
		return NumGet(Bitmap, 4, "Int")
	} finally {
		DllCall("Gdi32\DeleteObject", "Ptr", Mask)
		DllCall("Gdi32\DeleteObject", "Ptr", Colour)
	}
}

_NIT_PaintsAtTheSmallIconSize() {
	_NIT_StartGdip()
	Size := SysGet(49)
	for Text in ["0", "87", "142"] {
		HIcon := NotifyIcon_PaintNumber(Size, Text, 0x80123456, 0xFFFFFF, Round(Size * 24 / 44),
			Round(Size * 3 / 44), Round(Size * 8 / 44))
		AssertTrue(HIcon != 0, "a painted number must yield an icon: " . Text)
		try AssertEqual(Size, _NIT_IconWidth(HIcon), "the icon is drawn at the shell's small-icon side")
		finally AssertTrue(NotifyIcon_DestroyIcon(HIcon), "the caller can release the icon")
	}
}
Test("notify icon: a painted number yields an icon at the small-icon size (wpm-tray-readout)",
	_NIT_PaintsAtTheSmallIconSize)

_NIT_AddDeleteReAdd() {
	global _NIT_ICON_ID
	_NIT_StartGdip()
	Size := SysGet(49)
	HIcon := NotifyIcon_PaintNumber(Size, "42", 0xFF333344, 0xFFFFFF, Round(Size / 2), 1, 2)
	try {
		AssertFalse(_NIT_ShellHasIcon(_NIT_ICON_ID), "control: no icon before the add")
		AssertTrue(NotifyIcon_Publish(A_ScriptHwnd, _NIT_ICON_ID, HIcon, "42 WPM", false, true), "the shell accepts the add")
		AssertTrue(_NIT_ShellHasIcon(_NIT_ICON_ID), "the shell reports the added icon")
		AssertTrue(NotifyIcon_Publish(A_ScriptHwnd, _NIT_ICON_ID, HIcon, "43 WPM", false), "an update modifies it in place")
		AssertTrue(NotifyIcon_SetHidden(A_ScriptHwnd, _NIT_ICON_ID, true), "the icon can be hidden")
		AssertTrue(NotifyIcon_SetHidden(A_ScriptHwnd, _NIT_ICON_ID, false), "and shown again")
		AssertTrue(NotifyIcon_Delete(A_ScriptHwnd, _NIT_ICON_ID), "the shell accepts the delete")
		AssertFalse(_NIT_ShellHasIcon(_NIT_ICON_ID), "a deleted icon is gone")
		AssertFalse(NotifyIcon_Publish(A_ScriptHwnd, _NIT_ICON_ID, HIcon, "42 WPM", false), "a modify cannot resurrect it")
		AssertTrue(NotifyIcon_Publish(A_ScriptHwnd, _NIT_ICON_ID, HIcon, "42 WPM", false, true),
			"a fresh add works, as after TaskbarCreated")
	} finally {
		NotifyIcon_Delete(A_ScriptHwnd, _NIT_ICON_ID)
		NotifyIcon_DestroyIcon(HIcon)
	}
}
Test("notify icon: add, update, hide, delete and re-add against the real shell (wpm-tray-readout)",
	_NIT_AddDeleteReAdd)
