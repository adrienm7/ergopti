; adapters/graphics_renderer.ahk

; ==============================================================================
; MODULE: GraphicsRenderer Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the GraphicsRenderer port contract defined in
; static/ergopti_plus/_shared/core/ports/GraphicsRenderer.spec.js. Wraps the Win32
; CreateWindowEx / GDI+ / UpdateLayeredWindow pipeline behind five canonical
; functions so callers manage layered windows without touching raw DllCalls.
;
; NAMING CONVENTION:
; Port method         → AHK name
; createWindow(opts)  → GR_CreateWindow(Opts)
; destroyWindow(h)    → GR_DestroyWindow(Handle)
; drawBitmap(h, fn)   → GR_DrawBitmap(Handle, DrawFn)
; show(h)             → GR_Show(Handle)
; hide(h)             → GR_Hide(Handle)
;
; WINDOW FLAGS:
; WS_EX_LAYERED    = 0x00080000  -- per-pixel alpha via UpdateLayeredWindow
; WS_EX_TRANSPARENT= 0x00000020  -- click-through (mouse events pass through)
; WS_EX_TOPMOST    = 0x00000008  -- always above other windows
; WS_EX_TOOLWINDOW = 0x00000080  -- suppresses DWM corner rounding + taskbar entry
; WS_POPUP         = 0x80000000  -- borderless top-level window
;
; GDI+ LIFECYCLE:
; GdiplusStartup / GdiplusShutdown are NOT managed here — callers that need
; GDI+ inside their DrawFn must call LoadLibrary("gdiplus") and
; GdiplusStartup themselves (see spotlight.ahk for the pattern). This keeps
; the adapter focused on window lifecycle and bitmap upload only.
; ==============================================================================

; Requires: GraphicsRenderer




; =============================================================
; =============================================================
; ======= 1/ Window Creation and Destruction ==================
; =============================================================
; =============================================================

; Creates a borderless, layered, click-through top-level window.
; Returns the HWND on success, 0 on failure.
; @param Opts {Map}  Required keys: x, y, w, h.
;                    Optional: clickThrough (default true), alwaysOnTop (default true).
GR_CreateWindow(Opts) {
	X := Opts.Has("x") ? Opts["x"] : 0
	Y := Opts.Has("y") ? Opts["y"] : 0
	W := Opts.Has("w") ? Opts["w"] : 64
	H := Opts.Has("h") ? Opts["h"] : 64
	ClickThrough := !Opts.Has("clickThrough") or Opts["clickThrough"]
	AlwaysOnTop  := !Opts.Has("alwaysOnTop")  or Opts["alwaysOnTop"]

	; Build the extended style flags from caller preferences
	ExStyle := 0x00080000   ; WS_EX_LAYERED — required for UpdateLayeredWindow
	ExStyle |= 0x00000080   ; WS_EX_TOOLWINDOW — suppress DWM rounding + taskbar
	if ClickThrough
		ExStyle |= 0x00000020   ; WS_EX_TRANSPARENT
	if AlwaysOnTop
		ExStyle |= 0x00000008   ; WS_EX_TOPMOST

	Hwnd := 0
	try Hwnd := DllCall("User32\CreateWindowEx",
		"UInt",  ExStyle,
		"Str",   "Static",
		"Str",   "",
		"UInt",  0x80000000,   ; WS_POPUP — borderless top-level
		"Int",   X,
		"Int",   Y,
		"Int",   W,
		"Int",   H,
		"Ptr",   0,
		"Ptr",   0,
		"Ptr",   0,
		"Ptr",   0,
		"Ptr")

	if !Hwnd
		return 0

	; Tell DWM not to apply Windows 11 automatic corner rounding — it overrides
	; SetWindowRgn on layered windows and produces an unwanted OS arc.
	; DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_DONOTROUND = 1.
	Pref := Buffer(4, 0)
	NumPut("UInt", 1, Pref)
	try DllCall("Dwmapi\DwmSetWindowAttribute",
		"Ptr", Hwnd, "UInt", 33, "Ptr", Pref, "UInt", 4)

	return Hwnd
}

; Destroys the native window identified by Handle and releases OS resources.
; Silently ignores a zero / falsy handle.
; @param Handle {Ptr} HWND returned by GR_CreateWindow.
GR_DestroyWindow(Handle) {
	if !Handle
		return
	try DllCall("User32\DestroyWindow", "Ptr", Handle)
}




; =============================================================
; =============================================================
; ======= 2/ Bitmap Paint and Upload =========================
; =============================================================
; =============================================================

class _GRBitmapNative {
	static GetClientRect(Handle, Rect) {
		return DllCall("User32\GetClientRect", "Ptr", Handle, "Ptr", Rect,
			"Int") != 0
	}

	static GetScreenDC() {
		return DllCall("User32\GetDC", "Ptr", 0, "Ptr")
	}

	static CreateMemoryDC(ScreenDC) {
		return DllCall("Gdi32\CreateCompatibleDC", "Ptr", ScreenDC, "Ptr")
	}

	static CreateBitmap(ScreenDC, BitmapInfo, &Pixels) {
		return DllCall("Gdi32\CreateDIBSection", "Ptr", ScreenDC,
			"Ptr", BitmapInfo, "UInt", 0, "Ptr*", &Pixels,
			"Ptr", 0, "UInt", 0, "Ptr")
	}

	static SelectObject(MemoryDC, ObjectHandle) {
		return DllCall("Gdi32\SelectObject", "Ptr", MemoryDC,
			"Ptr", ObjectHandle, "Ptr")
	}

	static GetWindowRect(Handle, Rect) {
		return DllCall("User32\GetWindowRect", "Ptr", Handle, "Ptr", Rect,
			"Int") != 0
	}

	static UpdateLayeredWindow(Handle, Dest, Size, MemoryDC, Source, Blend) {
		return DllCall("User32\UpdateLayeredWindow", "Ptr", Handle,
			"Ptr", 0, "Ptr", Dest, "Ptr", Size, "Ptr", MemoryDC,
			"Ptr", Source, "UInt", 0, "Ptr", Blend, "UInt", 2,
			"Int") != 0
	}

	static DeleteObject(ObjectHandle) {
		return DllCall("Gdi32\DeleteObject", "Ptr", ObjectHandle, "Int") != 0
	}

	static DeleteMemoryDC(MemoryDC) {
		return DllCall("Gdi32\DeleteDC", "Ptr", MemoryDC, "Int") != 0
	}

	static ReleaseScreenDC(ScreenDC) {
		return DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", ScreenDC,
			"Int") != 0
	}
}





global _GRBitmapCleanupDebt := []

_GRBitmapNewReceipt() {
	return Map("screen_dc", 0, "memory_dc", 0, "bitmap", 0,
		"old_bitmap", 0, "bitmap_selected", false)
}

_GRBitmapSelectSucceeded(ObjectHandle) {
	return ObjectHandle != 0 and ObjectHandle != -1
}

; Releases only resources whose dependants have already been released. A
; refused restoration or deletion leaves the exact dependency tail for retry.
_GRBitmapRelease(Receipt, Native := _GRBitmapNative) {
	if !(Receipt is Map)
		return true
	try {
		if Receipt.Get("bitmap_selected", false) {
			Restored := Native.SelectObject(Receipt["memory_dc"],
				Receipt["old_bitmap"])
			if !_GRBitmapSelectSucceeded(Restored)
				return false
			Receipt["bitmap_selected"] := false
			Receipt["old_bitmap"] := 0
		}
		if Receipt.Get("bitmap", 0) {
			if Native.DeleteObject(Receipt["bitmap"]) != true
				return false
			Receipt["bitmap"] := 0
		}
		if Receipt.Get("memory_dc", 0) {
			if Native.DeleteMemoryDC(Receipt["memory_dc"]) != true
				return false
			Receipt["memory_dc"] := 0
		}
		if Receipt.Get("screen_dc", 0) {
			if Native.ReleaseScreenDC(Receipt["screen_dc"]) != true
				return false
			Receipt["screen_dc"] := 0
		}
		return true
	} catch {
		return false
	}
}

_GRBitmapSettle(Receipt, Native := _GRBitmapNative) {
	global _GRBitmapCleanupDebt
	if _GRBitmapRelease(Receipt, Native)
		return true
	PreviousCritical := Critical("On")
	try _GRBitmapCleanupDebt.Push(Receipt)
	finally Critical(PreviousCritical)
	return false
}

_GRBitmapDrainDebt(Native := _GRBitmapNative) {
	global _GRBitmapCleanupDebt
	PreviousCritical := Critical("On")
	try {
		Pending := _GRBitmapCleanupDebt
		_GRBitmapCleanupDebt := []
	} finally Critical(PreviousCritical)
	Failed := []
	for Receipt in Pending {
		if !_GRBitmapRelease(Receipt, Native)
			Failed.Push(Receipt)
	}
	PreviousCritical := Critical("On")
	try {
		for Receipt in Failed
			_GRBitmapCleanupDebt.Push(Receipt)
		return _GRBitmapCleanupDebt.Length == 0
	} finally Critical(PreviousCritical)
}

_GRDrawBitmapRun(Handle, DrawFn, Native := _GRBitmapNative) {
	if !Handle or !HasMethod(DrawFn, "Call")
		return false
	if !_GRBitmapDrainDebt(Native)
		return false
	Receipt := _GRBitmapNewReceipt()
	Succeeded := false
	Released := false
	try {
		Rect := Buffer(16, 0)
		if !Native.GetClientRect(Handle, Rect)
			return false
		W := NumGet(Rect, 8, "Int")
		H := NumGet(Rect, 12, "Int")
		if (W <= 0 or H <= 0)
			return false

		Receipt["screen_dc"] := Native.GetScreenDC()
		if !Receipt["screen_dc"]
			return false
		Receipt["memory_dc"] := Native.CreateMemoryDC(Receipt["screen_dc"])
		if !Receipt["memory_dc"]
			return false

		BitmapInfo := Buffer(40, 0)
		NumPut("UInt", 40, BitmapInfo, 0)
		NumPut("Int", W, BitmapInfo, 4)
		NumPut("Int", -H, BitmapInfo, 8)
		NumPut("UShort", 1, BitmapInfo, 12)
		NumPut("UShort", 32, BitmapInfo, 14)
		NumPut("UInt", 0, BitmapInfo, 16)
		Pixels := 0
		Receipt["bitmap"] := Native.CreateBitmap(Receipt["screen_dc"],
			BitmapInfo, &Pixels)
		if !Receipt["bitmap"]
			return false

		OldBitmap := Native.SelectObject(Receipt["memory_dc"],
			Receipt["bitmap"])
		if !_GRBitmapSelectSucceeded(OldBitmap)
			return false
		Receipt["old_bitmap"] := OldBitmap
		Receipt["bitmap_selected"] := true

		DrawFn.Call(Receipt["memory_dc"], W, H)
		WindowRect := Buffer(16, 0)
		if !Native.GetWindowRect(Handle, WindowRect)
			return false
		Dest := Buffer(8, 0)
		NumPut("Int", NumGet(WindowRect, 0, "Int"), Dest, 0)
		NumPut("Int", NumGet(WindowRect, 4, "Int"), Dest, 4)
		Size := Buffer(8, 0)
		NumPut("Int", W, Size, 0)
		NumPut("Int", H, Size, 4)
		Source := Buffer(8, 0)
		Blend := Buffer(4, 0)
		NumPut("UChar", 0, Blend, 0)
		NumPut("UChar", 0, Blend, 1)
		NumPut("UChar", 255, Blend, 2)
		NumPut("UChar", 1, Blend, 3)
		Succeeded := Native.UpdateLayeredWindow(Handle, Dest, Size,
			Receipt["memory_dc"], Source, Blend)
	} finally {
		Released := _GRBitmapSettle(Receipt, Native)
	}
	return Succeeded == true and Released
}

; Sets up a 32-bpp GDI memory DC, calls DrawFn(pGfx, MemDC, W, H) so the
; caller can paint via GDI or GDI+ into the DC, then uploads the result to
; the layered window via UpdateLayeredWindow. Cleans up all GDI objects.
; Safe no-op when Handle is 0.
; @param Handle {Ptr}      HWND returned by GR_CreateWindow.
; @param DrawFn {Callable} Called as DrawFn(MemDC, W, H). The adapter passes
;                          the memory DC handle so callers that draw with raw
;                          GDI can select objects into it directly. Callers
;                          that use GDI+ create their Graphics object from
;                          MemDC themselves via GdipCreateFromHDC.
GR_DrawBitmap(Handle, DrawFn) {
	return _GRDrawBitmapRun(Handle, DrawFn)
}




; =============================================================
; =============================================================
; ======= 3/ Visibility Control ==============================
; =============================================================
; =============================================================

; Makes the window visible without stealing keyboard focus.
; Maps to ShowWindow(SW_SHOWNOACTIVATE = 4).
; Safe no-op when Handle is 0.
; @param Handle {Ptr} HWND returned by GR_CreateWindow.
GR_Show(Handle) {
	if !Handle
		return
	try DllCall("User32\ShowWindow", "Ptr", Handle, "Int", 4)   ; SW_SHOWNOACTIVATE
}

; Hides the window from the screen without destroying it.
; Maps to ShowWindow(SW_HIDE = 0).
; Safe no-op when Handle is 0.
; @param Handle {Ptr} HWND returned by GR_CreateWindow.
GR_Hide(Handle) {
	if !Handle
		return
	try DllCall("User32\ShowWindow", "Ptr", Handle, "Int", 0)   ; SW_HIDE
}

; Port dispatch map (ADAPTER_GRAPHICS_RENDERER) — the single-source-of-truth contract
; surface, verified against _shared/core/ports/contracts.json by
; tools/test/test-port-compliance.cjs.
global ADAPTER_GRAPHICS_RENDERER := Map(
    "createWindow", GR_CreateWindow,
    "destroyWindow", GR_DestroyWindow,
    "drawBitmap", GR_DrawBitmap,
    "hide", GR_Hide,
    "show", GR_Show
)
