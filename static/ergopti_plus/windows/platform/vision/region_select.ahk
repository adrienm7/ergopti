; platform/vision/region_select.ahk

; ==============================================================================
; MODULE: Screen Region Selection (Windows)
; DESCRIPTION:
; Lets the user draw one screen rectangle for the « Capture → texte » action
; (Ctrl+O): a dimmed overlay over the whole virtual screen, a frame that
; follows the drag, Escape or a right click to cancel. The rectangle is handed
; to the screen vision service, which captures and reads it.
;
; FEATURES & RATIONALE:
; 1. Windows has no selection tool a script can wait on: the Snipping Tool
;    answers through the clipboard, which would replace what the user copied
;    even when nothing is read. This overlay leaves the clipboard alone.
; 2. One selection at a time, closed after the timings registry's
;    region_select_timeout_ms so an abandoned overlay never stays on screen.
; 3. A click without a drag (under 4 pixels) is a cancel, not a capture.
; 4. Screen coordinates: the rectangle is in the pixels MouseGetPos reports,
;    which the worker's capture uses as they are (per-monitor scaling is a
;    field check listed in TODO.md).
; ==============================================================================

#Requires AutoHotkey v2.0

class RegionSelectOwner {
	static overlay := 0
	static frame := 0
	static callback := 0
	static start := 0
	static timer := 0
}

; The least width and height, in pixels, of a drawn rectangle.
REGION_SELECT_MIN_PX() {
	return 4
}




; ==================================
; ==================================
; ======= 1/ Public API ============
; ==================================
; ==================================

; Shows the overlay; Callback(Rect, Reason) runs once with a Map x, y, width,
; height, or with 0 and "cancelled". Returns false when a selection is open.
RegionSelect(Callback) {
	if IsObject(RegionSelectOwner.overlay)
		return false
	CoordMode("Mouse", "Screen")
	Left := SysGet(76), Top := SysGet(77), Width := SysGet(78), Height := SysGet(79)
	Overlay := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale")
	Overlay.BackColor := "000000"
	Overlay.OnEvent("Escape", (*) => _RegionSelectEnd(0, "cancelled"))
	Overlay.OnEvent("Close", (*) => _RegionSelectEnd(0, "cancelled"))
	Frame := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20 +Owner" . Overlay.Hwnd)
	Frame.BackColor := "3A7BD5"
	RegionSelectOwner.overlay := Overlay, RegionSelectOwner.frame := Frame
	RegionSelectOwner.callback := Callback, RegionSelectOwner.start := 0
	Overlay.Show("x" . Left . " y" . Top . " w" . Width . " h" . Height . " NoActivate")
	WinSetTransparent(70, Overlay)
	WinActivate(Overlay)
	OnMessage(0x0201, _RegionSelectDown)
	OnMessage(0x0204, _RegionSelectRightDown)
	RegionSelectOwner.timer := (*) => _RegionSelectEnd(0, "cancelled")
	SetTimer(RegionSelectOwner.timer, -TimingsGet("screen_vision", "region_select_timeout_ms"))
	return true
}




; ==================================
; ==================================
; ======= 2/ Drag ==================
; ==================================
; ==================================

_RegionSelectDown(wParam, lParam, Msg, Hwnd) {
	if !IsObject(RegionSelectOwner.overlay) || Hwnd != RegionSelectOwner.overlay.Hwnd
		return
	MouseGetPos(&X, &Y)
	RegionSelectOwner.start := [X, Y]
	SetTimer(_RegionSelectTrack, 15)
	return 0
}

_RegionSelectRightDown(wParam, lParam, Msg, Hwnd) {
	if IsObject(RegionSelectOwner.overlay) && Hwnd == RegionSelectOwner.overlay.Hwnd {
		_RegionSelectEnd(0, "cancelled")
		return 0
	}
}

; The rectangle between the drag start and the pointer.
_RegionSelectRect() {
	MouseGetPos(&X, &Y)
	Start := RegionSelectOwner.start
	return Map("x", Min(X, Start[1]), "y", Min(Y, Start[2]), "width", Abs(X - Start[1]),
		"height", Abs(Y - Start[2]))
}

_RegionSelectTrack() {
	if !IsObject(RegionSelectOwner.overlay) || !IsObject(RegionSelectOwner.start) {
		SetTimer(_RegionSelectTrack, 0)
		return
	}
	Rect := _RegionSelectRect()
	if GetKeyState("LButton", "P") {
		RegionSelectOwner.frame.Show("x" . Rect["x"] . " y" . Rect["y"] . " w" . Max(Rect["width"], 1)
			. " h" . Max(Rect["height"], 1) . " NoActivate")
		WinSetTransparent(90, RegionSelectOwner.frame)
		return
	}
	SetTimer(_RegionSelectTrack, 0)
	if Rect["width"] < REGION_SELECT_MIN_PX() || Rect["height"] < REGION_SELECT_MIN_PX()
		return _RegionSelectEnd(0, "cancelled")
	_RegionSelectEnd(Rect, "")
}

; Closes the overlay and answers once.
_RegionSelectEnd(Rect, Reason) {
	if !IsObject(RegionSelectOwner.overlay)
		return
	OnMessage(0x0201, _RegionSelectDown, 0)
	OnMessage(0x0204, _RegionSelectRightDown, 0)
	SetTimer(_RegionSelectTrack, 0)
	if IsObject(RegionSelectOwner.timer)
		SetTimer(RegionSelectOwner.timer, 0)
	Callback := RegionSelectOwner.callback
	try RegionSelectOwner.frame.Destroy()
	try RegionSelectOwner.overlay.Destroy()
	RegionSelectOwner.overlay := 0, RegionSelectOwner.frame := 0, RegionSelectOwner.callback := 0
	RegionSelectOwner.start := 0, RegionSelectOwner.timer := 0
	Callback.Call(Rect, Reason)
}
