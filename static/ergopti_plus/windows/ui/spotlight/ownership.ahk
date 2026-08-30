; ui/spotlight/ownership.ahk

; ==============================================================================
; MODULE: Spotlight native ownership
; DESCRIPTION:
; Keeps each overlay HWND and GDI+ Graphics context owned until every dependent
; acquisition step succeeds. Test seams make partial native failure deterministic.
; ==============================================================================

#Requires AutoHotkey v2.0





class _SpotlightSessionNative {
	static LoadModule() {
		return DllCall("Kernel32\LoadLibraryW", "Str", "gdiplus.dll", "Ptr")
	}

	static Startup(&Token) {
		StartupInput := Buffer(24, 0)
		NumPut("UInt", 1, StartupInput)
		return DllCall("gdiplus\GdiplusStartup", "Ptr*", &Token,
			"Ptr", StartupInput, "Ptr", 0)
	}

	static DestroyWindow(Hwnd) {
		GR_DestroyWindow(Hwnd)
		return DllCall("User32\IsWindow", "Ptr", Hwnd, "Int") == 0
	}

	static Shutdown(Token) {
		DllCall("gdiplus\GdiplusShutdown", "Ptr", Token)
		return true
	}

	static FreeModule(Module) {
		return DllCall("Kernel32\FreeLibrary", "Ptr", Module, "Int") != 0
	}
}

class _SpotlightSessionTimerNative {
	static Arm() {
		SetTimer(_SpotlightTick, 100)
	}

	static Stop() {
		SetTimer(_SpotlightTick, 0)
	}
}





_SpotlightNewState() {
	return Map(
		"Phase", "idle",
		"Generation", 0,
		"Active", false,
		"Session", 0,
		"StartX", 0,
		"StartY", 0,
		"StartedTick", 0,
		"DurationMs", 0
	)
}

_SpotlightResetStateFields(State, Phase) {
	State["Phase"] := Phase
	State["Active"] := false
	State["Session"] := 0
	State["StartX"] := 0
	State["StartY"] := 0
	State["StartedTick"] := 0
	State["DurationMs"] := 0
}

; Reserves the only build slot before the first native allocation. Replacing an
; active overlay atomically detaches its exact receipt; callers in starting,
; cancelling, or cleaning phases are rejected instead of overwriting ownership.
_SpotlightClaimStart(State, TimerNative := _SpotlightSessionTimerNative) {
	if !(State is Map)
		throw TypeError("Spotlight state must be a Map")
	PreviousCritical := Critical("On")
	try {
		Phase := State.Get("Phase", "idle")
		if (Phase == "starting" or Phase == "cancelling"
				or Phase == "cleaning") {
			return Map("ok", false, "generation", 0, "previous", 0)
		}
		TimerNative.Stop()
		Previous := Phase == "active" ? State.Get("Session", 0) : 0
		Generation := State.Get("Generation", 0) + 1
		State["Generation"] := Generation
		_SpotlightResetStateFields(State, "starting")
		return Map("ok", true, "generation", Generation,
			"previous", Previous)
	} finally Critical(PreviousCritical)
}

_SpotlightAbandonStart(State, Generation) {
	PreviousCritical := Critical("On")
	try {
		if (State.Get("Generation", 0) != Generation
				or !(State.Get("Phase", "idle") == "starting"
					or State.Get("Phase", "idle") == "cancelling"))
			return false
		_SpotlightResetStateFields(State, "idle")
		return true
	} finally Critical(PreviousCritical)
}

_SpotlightPublishStart(State, Generation, Receipt, Data,
		TimerNative := _SpotlightSessionTimerNative) {
	if !(Receipt is Map) or !(Data is Map)
		throw TypeError("Spotlight publication requires receipt and data Maps")
	PreviousCritical := Critical("On")
	try {
		if (State.Get("Phase", "idle") != "starting"
				or State.Get("Generation", 0) != Generation)
			return false
		try {
			TimerNative.Arm()
			State["Session"] := Receipt
			State["StartX"] := Data["StartX"]
			State["StartY"] := Data["StartY"]
			State["StartedTick"] := Data["StartedTick"]
			State["DurationMs"] := Data["DurationMs"]
			State["Active"] := true
			State["Phase"] := "active"
			return true
		} catch {
			try TimerNative.Stop()
			throw
		}
	} finally Critical(PreviousCritical)
}

_SpotlightActiveSnapshot(State) {
	PreviousCritical := Critical("On")
	try {
		if (State.Get("Phase", "idle") != "active"
				or !State.Get("Active", false))
			return 0
		return Map("Generation", State["Generation"],
			"StartX", State["StartX"], "StartY", State["StartY"],
			"StartedTick", State["StartedTick"],
			"DurationMs", State["DurationMs"])
	} finally Critical(PreviousCritical)
}

_SpotlightClaimDismiss(State, ExpectedGeneration := 0,
		TimerNative := _SpotlightSessionTimerNative) {
	PreviousCritical := Critical("On")
	try {
		Generation := State.Get("Generation", 0)
		if (ExpectedGeneration and Generation != ExpectedGeneration)
			return Map("ok", false, "generation", Generation, "receipt", 0)
		Phase := State.Get("Phase", "idle")
		if (Phase == "cleaning" or Phase == "cancelling")
			return Map("ok", false, "generation", Generation, "receipt", 0)
		TimerNative.Stop()
		if (Phase == "starting") {
			_SpotlightResetStateFields(State, "cancelling")
			return Map("ok", true, "generation", Generation, "receipt", 0,
				"pending", true)
		}
		if (Phase != "active")
			return Map("ok", false, "generation", Generation, "receipt", 0)
		Receipt := State.Get("Session", 0)
		_SpotlightResetStateFields(State, "cleaning")
		return Map("ok", true, "generation", Generation, "receipt", Receipt,
			"pending", false)
	} finally Critical(PreviousCritical)
}

_SpotlightFinishDismiss(State, Generation) {
	PreviousCritical := Critical("On")
	try {
		if (State.Get("Generation", 0) != Generation
				or State.Get("Phase", "idle") != "cleaning")
			return false
		_SpotlightResetStateFields(State, "idle")
		return true
	} finally Critical(PreviousCritical)
}





global _SpotlightSessionCleanupDebt := []

_SpotlightSessionNewReceipt() {
	return Map("module", 0, "token", 0, "windows", [])
}

_SpotlightSessionAcquireGdi(Receipt, Native := _SpotlightSessionNative) {
	if !(Receipt is Map) or !(Receipt.Get("windows", 0) is Array)
		throw TypeError("Spotlight session receipt is invalid")
	Receipt["module"] := Native.LoadModule()
	if !Receipt["module"]
		throw Error("LoadLibraryW refused gdiplus.dll")
	Token := 0
	StartupStatus := -1
	try StartupStatus := Native.Startup(&Token)
	finally {
		if Token
			Receipt["token"] := Token
	}
	if (StartupStatus != 0 or !Token)
		throw Error("GdiplusStartup failed with status " . StartupStatus)
}

_SpotlightSessionOwnWindow(Receipt, Hwnd) {
	if !(Receipt is Map) or !(Receipt.Get("windows", 0) is Array)
		throw TypeError("Spotlight session receipt is invalid")
	if !Hwnd
		throw Error("Spotlight overlay creation returned a null HWND")
	Receipt["windows"].Push(Hwnd)
	return Hwnd
}

_SpotlightSessionAcquireWindow(Receipt, CreateFn,
		Native := _SpotlightSessionNative) {
	if !HasMethod(CreateFn, "Call")
		throw TypeError("Spotlight window creator must be callable")
	Hwnd := 0
	Transferred := false
	try {
		Hwnd := CreateFn.Call()
		_SpotlightSessionOwnWindow(Receipt, Hwnd)
		Transferred := true
		return Hwnd
	} finally {
		if (Hwnd and !Transferred)
			try Native.DestroyWindow(Hwnd)
	}
}

; Releases windows in reverse creation order, then the GDI+ token, then the
; module. A refused step retains that handle and all dependencies below it.
_SpotlightSessionRelease(Receipt, Native := _SpotlightSessionNative) {
	if !(Receipt is Map) or !(Receipt.Get("windows", 0) is Array)
		return true
	try {
		Windows := Receipt["windows"]
		while Windows.Length {
			if Native.DestroyWindow(Windows[Windows.Length]) != true
				return false
			Windows.Pop()
		}
		if Receipt.Get("token", 0) {
			if Native.Shutdown(Receipt["token"]) != true
				return false
			Receipt["token"] := 0
		}
		if Receipt.Get("module", 0) {
			if Native.FreeModule(Receipt["module"]) != true
				return false
			Receipt["module"] := 0
		}
		return true
	} catch {
		return false
	}
}

_SpotlightSessionSettle(Receipt, Native := _SpotlightSessionNative) {
	global _SpotlightSessionCleanupDebt
	if _SpotlightSessionRelease(Receipt, Native)
		return true
	PreviousCritical := Critical("On")
	try _SpotlightSessionCleanupDebt.Push(Receipt)
	finally Critical(PreviousCritical)
	return false
}

_SpotlightSessionDrainDebt(Native := _SpotlightSessionNative) {
	global _SpotlightSessionCleanupDebt
	PreviousCritical := Critical("On")
	try {
		Pending := _SpotlightSessionCleanupDebt
		_SpotlightSessionCleanupDebt := []
	} finally Critical(PreviousCritical)
	Failed := []
	for Receipt in Pending {
		if !_SpotlightSessionRelease(Receipt, Native)
			Failed.Push(Receipt)
	}
	PreviousCritical := Critical("On")
	try {
		for Receipt in Failed
			_SpotlightSessionCleanupDebt.Push(Receipt)
		return _SpotlightSessionCleanupDebt.Length == 0
	} finally Critical(PreviousCritical)
}





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
