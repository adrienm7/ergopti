; tray/adapters/notify_icon.ahk

; ==============================================================================
; MODULE: Notification Icon Adapter (AutoHotkey)
; DESCRIPTION:
; Owns one extra notification-area icon beside the AutoHotkey tray icon, and
; paints a short number into an icon handle. metrics/ui/wpm/tray_readout.ahk uses it
; for the live typing speed, the Windows counterpart of the macOS menu bar
; readout and of linux/metrics/ui/wpm/tray_readout.lua.
;
; FEATURES & RATIONALE:
; 1. One icon per (window, id) pair. AutoHotkey keeps uID 1028 for its own icon,
;    so a distinct id beside the same hidden script window never disturbs it.
; 2. No callback message: like the macOS readout, the icon does nothing on a
;    click; the Metrics menu is where it is switched off.
; 3. Shown and hidden through NIS_HIDDEN once added, so the icon keeps its place
;    in the notification area instead of being re-added on every burst.
; 4. Explorer forgets every icon when it restarts and broadcasts the
;    registered "TaskbarCreated" message; the owner re-adds its icon on it.
; 5. The painter needs GDI+ already started by its caller (the WPM widget owns
;    the process-lifetime token) and returns an HICON the caller destroys once
;    the shell has taken a newer one.
; ==============================================================================

#Requires AutoHotkey v2.0

; Shell_NotifyIconW messages, flags and states.
global NOTIFY_ICON_NIM_ADD := 0
global NOTIFY_ICON_NIM_MODIFY := 1
global NOTIFY_ICON_NIM_DELETE := 2
global NOTIFY_ICON_NIF_ICON := 0x2
global NOTIFY_ICON_NIF_TIP := 0x4
global NOTIFY_ICON_NIF_STATE := 0x8
global NOTIFY_ICON_NIF_SHOWTIP := 0x80
global NOTIFY_ICON_NIS_HIDDEN := 0x1
; szTip holds 128 UTF-16 units, terminator included.
global NOTIFY_ICON_TIP_CHARS := 127





; =========================================
; =========================================
; ======= 1/ Notification-area icon =======
; =========================================
; =========================================

; The message Explorer broadcasts once it has (re)built the notification area.
; @returns {Integer} The registered message id, 0 when registration failed.
NotifyIcon_TaskbarCreatedMessage() {
	return DllCall("User32\RegisterWindowMessageW", "Str", "TaskbarCreated", "UInt")
}

; Builds a NOTIFYICONDATAW for (Hwnd, Id). Offsets follow the documented
; layout for both pointer sizes: hIcon is pointer-aligned after four 32-bit
; fields, szTip follows it, dwState and dwStateMask follow the 128-unit tip.
_NotifyIcon_Data(Hwnd, Id, Flags) {
	IconAt := A_PtrSize = 8 ? 32 : 20
	TipAt := IconAt + A_PtrSize
	Data := Buffer(A_PtrSize = 8 ? 976 : 956, 0)
	NumPut("UInt", Data.Size, Data, 0)
	NumPut("Ptr", Hwnd, Data, A_PtrSize = 8 ? 8 : 4)
	NumPut("UInt", Id, Data, A_PtrSize = 8 ? 16 : 8)
	NumPut("UInt", Flags, Data, A_PtrSize = 8 ? 20 : 12)
	return {Data: Data, IconAt: IconAt, TipAt: TipAt, StateAt: TipAt + 256}
}

; Adds or updates the icon with its image, tooltip and visibility.
; @param Hwnd {Integer} Owner window (the script's hidden main window).
; @param Id {Integer} The icon's id beside that window.
; @param HIcon {Integer} Icon handle; the shell copies it.
; @param Tip {String} Hover text, cut to the shell's limit.
; @param Hidden {Boolean} Whether the icon is hidden.
; @param Add {Boolean} True for the first publication (or after Explorer restarts).
; @returns {Boolean} Whether the shell accepted the call.
NotifyIcon_Publish(Hwnd, Id, HIcon, Tip, Hidden, Add := false) {
	Spec := _NotifyIcon_Data(Hwnd, Id, NOTIFY_ICON_NIF_ICON | NOTIFY_ICON_NIF_TIP
		| NOTIFY_ICON_NIF_STATE | NOTIFY_ICON_NIF_SHOWTIP)
	NumPut("Ptr", HIcon, Spec.Data, Spec.IconAt)
	StrPut(SubStr(Tip, 1, NOTIFY_ICON_TIP_CHARS), Spec.Data.Ptr + Spec.TipAt, NOTIFY_ICON_TIP_CHARS + 1, "UTF-16")
	NumPut("UInt", Hidden ? NOTIFY_ICON_NIS_HIDDEN : 0, Spec.Data, Spec.StateAt)
	NumPut("UInt", NOTIFY_ICON_NIS_HIDDEN, Spec.Data, Spec.StateAt + 4)
	return DllCall("Shell32\Shell_NotifyIconW", "UInt", Add ? NOTIFY_ICON_NIM_ADD : NOTIFY_ICON_NIM_MODIFY,
		"Ptr", Spec.Data, "Int") != 0
}

; Hides or shows the icon without touching its image.
; @returns {Boolean} Whether the shell accepted the call.
NotifyIcon_SetHidden(Hwnd, Id, Hidden) {
	Spec := _NotifyIcon_Data(Hwnd, Id, NOTIFY_ICON_NIF_STATE)
	NumPut("UInt", Hidden ? NOTIFY_ICON_NIS_HIDDEN : 0, Spec.Data, Spec.StateAt)
	NumPut("UInt", NOTIFY_ICON_NIS_HIDDEN, Spec.Data, Spec.StateAt + 4)
	return DllCall("Shell32\Shell_NotifyIconW", "UInt", NOTIFY_ICON_NIM_MODIFY, "Ptr", Spec.Data, "Int") != 0
}

; Removes the icon from the notification area.
; @returns {Boolean} Whether the shell accepted the call.
NotifyIcon_Delete(Hwnd, Id) {
	Spec := _NotifyIcon_Data(Hwnd, Id, 0)
	return DllCall("Shell32\Shell_NotifyIconW", "UInt", NOTIFY_ICON_NIM_DELETE, "Ptr", Spec.Data, "Int") != 0
}

; Releases an icon handle the shell no longer shows.
; @returns {Boolean} Whether Windows released it.
NotifyIcon_DestroyIcon(HIcon) {
	return HIcon = 0 || DllCall("User32\DestroyIcon", "Ptr", HIcon, "Int") != 0
}





; =================================
; =================================
; ======= 2/ Number painter =======
; =================================
; =================================

; Paints Text centred on a rounded fill into a square icon.
; @param Size {Integer} Icon side in physical pixels.
; @param Text {String} The number to show.
; @param FillArgb {Integer} 0xAARRGGBB of the rounded background.
; @param TextRgb {Integer} 0xRRGGBB of the number.
; @param FontPx {Integer} Largest font size; shrunk until the text fits.
; @param InsetPx {Integer} Margin the text keeps from the left and right edges.
; @param RadiusPx {Integer} Corner radius of the fill.
; @returns {Integer} A new HICON the caller owns.
; @throws {Error} When any GDI+ step fails; nothing is leaked.
NotifyIcon_PaintNumber(Size, Text, FillArgb, TextRgb, FontPx, InsetPx, RadiusPx) {
	Bitmap := 0, Graphics := 0, Path := 0, Fill := 0, Ink := 0
	Family := 0, Font := 0, TextFormat := 0, HIcon := 0
	try {
		_NotifyIcon_Ok(DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", Size, "Int", Size,
			"Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &Bitmap))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", Bitmap, "Ptr*", &Graphics))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", Graphics, "Int", 4))
		; Greyscale antialiasing: the shell composites the icon, where ClearType
		; fringes would show as colour.
		_NotifyIcon_Ok(DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", Graphics, "Int", 4))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipGraphicsClear", "Ptr", Graphics, "UInt", 0))
		D := RadiusPx * 2, Edge := Size - 1
		_NotifyIcon_Ok(DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &Path))
		for Arc in [[0, 0, 180], [Edge - D, 0, 270], [Edge - D, Edge - D, 0], [0, Edge - D, 90]]
			_NotifyIcon_Ok(DllCall("gdiplus\GdipAddPathArc", "Ptr", Path, "Float", Arc[1], "Float", Arc[2],
				"Float", D, "Float", D, "Float", Arc[3], "Float", 90))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipClosePathFigure", "Ptr", Path))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipCreateSolidFill", "UInt", FillArgb, "Ptr*", &Fill))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipFillPath", "Ptr", Graphics, "Ptr", Fill, "Ptr", Path))

		_NotifyIcon_Ok(DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", &Family))
		; NoWrap | NoClip, centred both ways.
		_NotifyIcon_Ok(DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x5000, "UShort", 0, "Ptr*", &TextFormat))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", TextFormat, "Int", 1))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", TextFormat, "Int", 1))
		Layout := Buffer(16, 0), Bound := Buffer(16, 0)
		NumPut("Float", Size, Layout, 8), NumPut("Float", Size, Layout, 12)
		Px := FontPx
		loop {
			; Bold, in pixels, so the size does not depend on the display's DPI.
			_NotifyIcon_Ok(DllCall("gdiplus\GdipCreateFont", "Ptr", Family, "Float", Px, "Int", 1, "Int", 2, "Ptr*", &Font))
			_NotifyIcon_Ok(DllCall("gdiplus\GdipMeasureString", "Ptr", Graphics, "WStr", Text, "Int", -1,
				"Ptr", Font, "Ptr", Layout, "Ptr", TextFormat, "Ptr", Bound, "Ptr", 0, "Ptr", 0))
			if NumGet(Bound, 8, "Float") <= Size - 2 * InsetPx || Px <= 6
				break
			DllCall("gdiplus\GdipDeleteFont", "Ptr", Font), Font := 0
			Px -= 1
		}
		_NotifyIcon_Ok(DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFF000000 | TextRgb, "Ptr*", &Ink))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipDrawString", "Ptr", Graphics, "WStr", Text, "Int", -1,
			"Ptr", Font, "Ptr", Layout, "Ptr", TextFormat, "Ptr", Ink))
		_NotifyIcon_Ok(DllCall("gdiplus\GdipCreateHICONFromBitmap", "Ptr", Bitmap, "Ptr*", &HIcon))
		return HIcon
	} finally {
		for Pair in [["GdipDeleteBrush", Ink], ["GdipDeleteFont", Font], ["GdipDeleteStringFormat", TextFormat],
				["GdipDeleteFontFamily", Family], ["GdipDeleteBrush", Fill], ["GdipDeletePath", Path],
				["GdipDeleteGraphics", Graphics], ["GdipDisposeImage", Bitmap]] {
			if Pair[2]
				DllCall("gdiplus\" . Pair[1], "Ptr", Pair[2])
		}
	}
}

; A GDI+ status other than Ok fails the paint.
_NotifyIcon_Ok(Status) {
	if Status != 0
		throw OSError("GDI+ status " . Status . " while painting the readout icon.")
}
