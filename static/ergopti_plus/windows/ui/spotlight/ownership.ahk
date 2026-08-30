; ui/spotlight/ownership.ahk

; ==============================================================================
; MODULE: Spotlight native ownership
; DESCRIPTION:
; Keeps each overlay HWND and GDI+ Graphics context owned until every dependent
; acquisition step succeeds. Test seams make partial native failure deterministic.
; ==============================================================================

#Requires AutoHotkey v2.0





class _SpotlightGdiNative {
	static CreateGraphics(MemDC, &Graphics) {
		return DllCall("gdiplus\GdipCreateFromHDC", "Ptr", MemDC,
			"Ptr*", &Graphics)
	}

	static SetSmoothing(Graphics) {
		return DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", Graphics,
			"Int", 4)
	}

	static SetCompositingMode(Graphics) {
		return DllCall("gdiplus\GdipSetCompositingMode", "Ptr", Graphics,
			"Int", 0)
	}

	static SetCompositingQuality(Graphics) {
		return DllCall("gdiplus\GdipSetCompositingQuality", "Ptr", Graphics,
			"Int", 0)
	}

	static DeleteGraphics(Graphics) {
		return DllCall("gdiplus\GdipDeleteGraphics", "Ptr", Graphics)
	}
}





; Creates the GDI+ Graphics context used for one bitmap paint. Every successful
; CreateGraphics call is paired with DeleteGraphics even when setup or the
; caller's drawing callback fails.
_SpotlightDrawWithGdiPlus(DrawCallback, MemDC, W, H,
		Native := _SpotlightGdiNative) {
	if !HasMethod(DrawCallback, "Call")
		throw TypeError("Spotlight draw callback must be callable")
	pGfx := 0
	CreateStatus := Native.CreateGraphics(MemDC, &pGfx)
	if (CreateStatus != 0 or !pGfx) {
		if pGfx
			try Native.DeleteGraphics(pGfx)
		throw Error("Spotlight could not create its GDI+ Graphics context")
	}
	try {
		if Native.SetSmoothing(pGfx) != 0
			throw Error("Spotlight could not configure GDI+ smoothing")
		if Native.SetCompositingMode(pGfx) != 0
			throw Error("Spotlight could not configure GDI+ compositing mode")
		if Native.SetCompositingQuality(pGfx) != 0
			throw Error("Spotlight could not configure GDI+ compositing quality")
		DrawCallback.Call(pGfx, W, H)
	} finally {
		Native.DeleteGraphics(pGfx)
	}
}





; Transfers an overlay HWND to the caller only after both drawing and showing
; complete. Until then this function remains the sole owner and destroys the
; partial window on every exceptional exit.
_SpotlightCreateOverlayWindow(Opts, DrawCallback, CreateFn := 0,
		DrawBitmapFn := 0, ShowFn := 0, DestroyFn := 0) {
	ResolvedCreate := HasMethod(CreateFn, "Call") ? CreateFn : GR_CreateWindow
	ResolvedDraw := HasMethod(DrawBitmapFn, "Call") ? DrawBitmapFn : GR_DrawBitmap
	ResolvedShow := HasMethod(ShowFn, "Call") ? ShowFn : GR_Show
	ResolvedDestroy := HasMethod(DestroyFn, "Call") ? DestroyFn : GR_DestroyWindow
	Hwnd := ResolvedCreate.Call(Opts)
	if !Hwnd
		return 0
	Transferred := false
	try {
		PaintFn := _SpotlightDrawWithGdiPlus.Bind(DrawCallback)
		ResolvedDraw.Call(Hwnd, PaintFn)
		ResolvedShow.Call(Hwnd)
		Transferred := true
		return Hwnd
	} finally {
		if !Transferred
			try ResolvedDestroy.Call(Hwnd)
	}
}
