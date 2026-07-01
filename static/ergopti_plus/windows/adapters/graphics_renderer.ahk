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
	if !Handle
		return

	; Retrieve the current window size to allocate a matching DIB
	Rect := Buffer(16, 0)
	DllCall("User32\GetClientRect", "Ptr", Handle, "Ptr", Rect)
	W := NumGet(Rect, 8, "Int")
	H := NumGet(Rect, 12, "Int")
	if (W <= 0 or H <= 0)
		return

	ScreenDC := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
	if !ScreenDC
		return

	MemDC := DllCall("Gdi32\CreateCompatibleDC", "Ptr", ScreenDC, "Ptr")
	if !MemDC {
		DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", ScreenDC)
		return
	}

	; 32-bpp top-down DIB — required for per-pixel alpha in UpdateLayeredWindow
	BmpInfo := Buffer(40, 0)
	NumPut("UInt",   40, BmpInfo,  0)   ; biSize
	NumPut("Int",     W, BmpInfo,  4)   ; biWidth
	NumPut("Int",    -H, BmpInfo,  8)   ; biHeight (negative = top-down)
	NumPut("UShort",  1, BmpInfo, 12)   ; biPlanes
	NumPut("UShort", 32, BmpInfo, 14)   ; biBitCount
	NumPut("UInt",    0, BmpInfo, 16)   ; biCompression = BI_RGB

	PixPtr := 0
	HBmp := DllCall("Gdi32\CreateDIBSection",
		"Ptr",  ScreenDC,
		"Ptr",  BmpInfo,
		"UInt", 0,
		"Ptr*", &PixPtr,
		"Ptr",  0,
		"UInt", 0,
		"Ptr")

	if !HBmp {
		DllCall("Gdi32\DeleteDC",     "Ptr", MemDC)
		DllCall("User32\ReleaseDC",   "Ptr", 0, "Ptr", ScreenDC)
		return
	}

	OldBmp := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HBmp, "Ptr")

	; Guarantee GDI cleanup even if DrawFn or UpdateLayeredWindow throw an
	; AHK runtime error (e.g. a DllCall with bad params during development).
	; DrawFn is guarded with Type() instead of a nested try/catch — the catch
	; frame added ~2 ms of AHK overhead on every render even with no exception.
	; On the happy path Type() costs nothing; if DrawFn throws the exception
	; propagates through the outer finally so GDI resources are always released
	; and UpdateLayeredWindow is never called on a partial bitmap.
	try {
		; Delegate all painting to the caller — they receive the memory DC and
		; dimensions so they can call GDI primitives or create a GDI+ Graphics.
		; HasMethod accepts Func, Closure, and BoundFunc — Type()=="Func" rejected
		; closures (capturing nested functions), making spotlight and WPM invisible.
		if HasMethod(DrawFn, "Call") {
			DrawFn(MemDC, W, H)

			; Commit the painted bitmap to the layered window (only reached when
			; DrawFn returned normally — exceptions skip this block). Window position
			; is taken directly from the HWND so no coordinate arithmetic is needed.
			WinRect := Buffer(16, 0)
			DllCall("User32\GetWindowRect", "Ptr", Handle, "Ptr", WinRect)
			WinX := NumGet(WinRect, 0, "Int")
			WinY := NumGet(WinRect, 4, "Int")

			PtDest := Buffer(8, 0)
			NumPut("Int", WinX, PtDest, 0)
			NumPut("Int", WinY, PtDest, 4)
			SizeSrc := Buffer(8, 0)
			NumPut("Int", W, SizeSrc, 0)
			NumPut("Int", H, SizeSrc, 4)
			PtSrc  := Buffer(8, 0)   ; Origin (0, 0) inside MemDC
			Blend  := Buffer(4, 0)
			NumPut("UChar", 0,   Blend, 0)   ; BlendOp = AC_SRC_OVER
			NumPut("UChar", 0,   Blend, 1)   ; BlendFlags
			NumPut("UChar", 255, Blend, 2)   ; SourceConstantAlpha = 255 (per-pixel alpha)
			NumPut("UChar", 1,   Blend, 3)   ; AlphaFormat = AC_SRC_ALPHA

			DllCall("User32\UpdateLayeredWindow",
				"Ptr",  Handle,
				"Ptr",  0,        ; hdcDst = NULL — use the screen DC implicitly
				"Ptr",  PtDest,
				"Ptr",  SizeSrc,
				"Ptr",  MemDC,
				"Ptr",  PtSrc,
				"UInt", 0,
				"Ptr",  Blend,
				"UInt", 2)        ; ULW_ALPHA
		}
	} finally {
		DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", OldBmp)
		DllCall("Gdi32\DeleteObject", "Ptr", HBmp)
		DllCall("Gdi32\DeleteDC",     "Ptr", MemDC)
		DllCall("User32\ReleaseDC",   "Ptr", 0, "Ptr", ScreenDC)
	}
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
