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





global _SpotlightPaintCleanupDebt := []

class _SpotlightPaintNative {
	static CreateBrush(Color, &Brush) {
		return DllCall("gdiplus\GdipCreateSolidFill", "UInt", Color,
			"Ptr*", &Brush)
	}

	static DeleteBrush(Brush) {
		return DllCall("gdiplus\GdipDeleteBrush", "Ptr", Brush)
	}

	static FillEllipse(Graphics, Brush, X, Y, W, H) {
		return DllCall("gdiplus\GdipFillEllipse", "Ptr", Graphics,
			"Ptr", Brush, "Float", X, "Float", Y, "Float", W,
			"Float", H)
	}

	static FillRectangle(Graphics, Brush, X, Y, W, H) {
		return DllCall("gdiplus\GdipFillRectangle", "Ptr", Graphics,
			"Ptr", Brush, "Float", X, "Float", Y, "Float", W,
			"Float", H)
	}

	static CreatePen(Color, Width, &Pen) {
		return DllCall("gdiplus\GdipCreatePen1", "UInt", Color,
			"Float", Width, "Int", 2, "Ptr*", &Pen)
	}

	static DeletePen(Pen) {
		return DllCall("gdiplus\GdipDeletePen", "Ptr", Pen)
	}

	static DrawEllipse(Graphics, Pen, X, Y, W, H) {
		return DllCall("gdiplus\GdipDrawEllipse", "Ptr", Graphics,
			"Ptr", Pen, "Float", X, "Float", Y, "Float", W,
			"Float", H)
	}

	static DrawRectangle(Graphics, Pen, X, Y, W, H) {
		return DllCall("gdiplus\GdipDrawRectangle", "Ptr", Graphics,
			"Ptr", Pen, "Float", X, "Float", Y, "Float", W,
			"Float", H)
	}
}

_SpotlightPaintNewReceipt() {
	return Map("resources", [])
}

_SpotlightPaintOwn(Receipt, Kind, Handle) {
	if !(Receipt is Map) or !(Receipt.Get("resources", 0) is Array)
		throw TypeError("Spotlight paint receipt is invalid")
	if !Handle
		throw ValueError("Spotlight cannot own a null " . Kind . " handle")
	Receipt["resources"].Push(Map("kind", Kind, "handle", Handle))
	return Handle
}

_SpotlightPaintRequireCreated(Receipt, Kind, Status, Handle, Description) {
	if Handle
		_SpotlightPaintOwn(Receipt, Kind, Handle)
	if (Status != 0 or !Handle)
		throw Error(Description . " failed with status " . Status)
	return Handle
}

_SpotlightPaintRequireOk(Status, Description) {
	if Status != 0
		throw Error(Description . " failed with status " . Status)
}

_SpotlightPaintRelease(Receipt, Native := _SpotlightPaintNative) {
	if !(Receipt is Map) or !(Receipt.Get("resources", 0) is Array)
		return true
	Resources := Receipt["resources"]
	while Resources.Length {
		Resource := Resources[Resources.Length]
		Status := -1
		try switch Resource["kind"] {
		case "brush": Status := Native.DeleteBrush(Resource["handle"])
		case "pen": Status := Native.DeletePen(Resource["handle"])
		}
		catch
			return false
		if Status != 0
			return false
		Resources.Pop()
	}
	return true
}

_SpotlightPaintSettle(Receipt, Native := _SpotlightPaintNative) {
	global _SpotlightPaintCleanupDebt
	PreviousCritical := Critical("On")
	try {
		if _SpotlightPaintRelease(Receipt, Native)
			return true
		_SpotlightPaintCleanupDebt.Push(Receipt)
		return false
	} finally Critical(PreviousCritical)
}

_SpotlightPaintDrainDebt(Native := _SpotlightPaintNative) {
	global _SpotlightPaintCleanupDebt
	PreviousCritical := Critical("On")
	try {
		Pending := _SpotlightPaintCleanupDebt
		_SpotlightPaintCleanupDebt := []
		for Receipt in Pending {
			if !_SpotlightPaintRelease(Receipt, Native)
				_SpotlightPaintCleanupDebt.Push(Receipt)
		}
		return _SpotlightPaintCleanupDebt.Length == 0
	} finally Critical(PreviousCritical)
}

_SpotlightPaintRun(PaintFn, Native := _SpotlightPaintNative) {
	if !HasMethod(PaintFn, "Call")
		throw TypeError("Spotlight paint callback must be callable")
	if !_SpotlightPaintDrainDebt(Native)
		throw Error("Previous Spotlight paint cleanup is still pending")
	Receipt := _SpotlightPaintNewReceipt()
	Failure := 0
	try PaintFn.Call(Receipt, Native)
	catch as Err
		Failure := Err
	Released := _SpotlightPaintSettle(Receipt, Native)
	if Failure is Error
		throw Failure
	if !Released
		throw Error("Spotlight paint cleanup was refused")
}

_SpotlightPaintCircleBody(Graphics, Pad, Radius, StrokeWidth, FillColor,
		StrokeColor, Receipt, Native) {
	Brush := 0
	Status := Native.CreateBrush(FillColor, &Brush)
	_SpotlightPaintRequireCreated(Receipt, "brush", Status, Brush,
		"GdipCreateSolidFill for the Spotlight circle")
	_SpotlightPaintRequireOk(Native.FillEllipse(Graphics, Brush, Pad, Pad,
		Radius * 2, Radius * 2), "GdipFillEllipse for the Spotlight circle")

	Pen := 0
	Status := Native.CreatePen(StrokeColor, StrokeWidth, &Pen)
	_SpotlightPaintRequireCreated(Receipt, "pen", Status, Pen,
		"GdipCreatePen1 for the Spotlight circle")
	Inset := StrokeWidth / 2
	_SpotlightPaintRequireOk(Native.DrawEllipse(Graphics, Pen, Pad + Inset,
		Pad + Inset, Radius * 2 - StrokeWidth, Radius * 2 - StrokeWidth),
		"GdipDrawEllipse for the Spotlight circle")
}

_SpotlightDrawCircleResources(Graphics, Pad, Radius, StrokeWidth, FillColor,
		StrokeColor, Native := _SpotlightPaintNative) {
	PaintFn := _SpotlightPaintCircleBody.Bind(Graphics, Pad, Radius,
		StrokeWidth, FillColor, StrokeColor)
	_SpotlightPaintRun(PaintFn, Native)
}

_SpotlightPaintCrossBody(Graphics, Pad, HalfSize, BarWidth, StrokeWidth,
		FillColor, StrokeColor, Receipt, Native) {
	HalfBar := BarWidth / 2
	Brush := 0
	Status := Native.CreateBrush(FillColor, &Brush)
	_SpotlightPaintRequireCreated(Receipt, "brush", Status, Brush,
		"GdipCreateSolidFill for the Spotlight cross")
	_SpotlightPaintRequireOk(Native.FillRectangle(Graphics, Brush, Pad,
		Pad + HalfSize - HalfBar, HalfSize * 2, BarWidth),
		"horizontal fill for the Spotlight cross")
	_SpotlightPaintRequireOk(Native.FillRectangle(Graphics, Brush,
		Pad + HalfSize - HalfBar, Pad, BarWidth, HalfSize * 2),
		"vertical fill for the Spotlight cross")

	Pen := 0
	Status := Native.CreatePen(StrokeColor, StrokeWidth, &Pen)
	_SpotlightPaintRequireCreated(Receipt, "pen", Status, Pen,
		"GdipCreatePen1 for the Spotlight cross")
	Inset := StrokeWidth / 2
	_SpotlightPaintRequireOk(Native.DrawRectangle(Graphics, Pen, Pad + Inset,
		Pad + HalfSize - HalfBar + Inset, HalfSize * 2 - StrokeWidth,
		BarWidth - StrokeWidth), "horizontal stroke for the Spotlight cross")
	_SpotlightPaintRequireOk(Native.DrawRectangle(Graphics, Pen,
		Pad + HalfSize - HalfBar + Inset, Pad + Inset,
		BarWidth - StrokeWidth, HalfSize * 2 - StrokeWidth),
		"vertical stroke for the Spotlight cross")
}

_SpotlightDrawCrossResources(Graphics, Pad, HalfSize, BarWidth, StrokeWidth,
		FillColor, StrokeColor, Native := _SpotlightPaintNative) {
	PaintFn := _SpotlightPaintCrossBody.Bind(Graphics, Pad, HalfSize, BarWidth,
		StrokeWidth, FillColor, StrokeColor)
	_SpotlightPaintRun(PaintFn, Native)
}
