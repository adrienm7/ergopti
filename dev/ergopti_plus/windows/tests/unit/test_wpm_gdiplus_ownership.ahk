; tests/unit/test_wpm_gdiplus_ownership.ahk

; ==============================================================================
; MODULE: WPM GDI+ ownership tests
; DESCRIPTION:
; Injects native acquisition and cleanup failures into the process-lifetime WPM
; graphics transaction without loading or allocating real GDI+ resources.
; ==============================================================================

#Requires AutoHotkey v2.0

class _WPMGO_Native {
	static Events := []
	static FailAt := ""
	static CleanupFailAt := ""

	static Reset(FailAt := "", CleanupFailAt := "") {
		this.Events := []
		this.FailAt := FailAt
		this.CleanupFailAt := CleanupFailAt
	}

	static LoadModule() {
		this.Events.Push("load")
		return this.FailAt == "load" ? 0 : 101
	}

	static FreeModule(Module) {
		this.Events.Push("free:" . Module)
		return this.CleanupFailAt != "free"
	}

	static Startup(StartupInput, &Token) {
		this.Events.Push("startup")
		Token := this.FailAt == "startup" ? 0 : 202
		return this.FailAt == "startup" ? 1 : 0
	}

	static Shutdown(Token) {
		this.Events.Push("shutdown:" . Token)
		return this.CleanupFailAt != "shutdown"
	}

	static CreateFamily(Name, &Family) {
		this.Events.Push("family:" . Name)
		if (this.FailAt == "segoe" and Name == "Segoe UI") {
			Family := 0
			return 1
		}
		if (this.FailAt == "family") {
			Family := 0
			return 1
		}
		Family := 303
		return 0
	}

	static DeleteFamily(Family) {
		this.Events.Push("delete-family:" . Family)
		return this.CleanupFailAt == "family" ? 1 : 0
	}

	static CreateFont(Family, LabelPx, &Font) {
		this.Events.Push("font:" . Family . ":" . LabelPx)
		Font := this.FailAt == "font" ? 0 : 404
		return this.FailAt == "font" ? 1 : 0
	}

	static DeleteFont(Font) {
		this.Events.Push("delete-font:" . Font)
		return this.CleanupFailAt == "font" ? 1 : 0
	}

	static CreateFormat(&FormatHandle) {
		this.Events.Push("format")
		FormatHandle := this.FailAt == "format" ? 0 : 505
		return this.FailAt == "format" ? 1 : 0
	}

	static DeleteFormat(FormatHandle) {
		this.Events.Push("delete-format:" . FormatHandle)
		return this.CleanupFailAt == "format" ? 1 : 0
	}

	static SetFormatAlign(FormatHandle) {
		this.Events.Push("align:" . FormatHandle)
		return this.FailAt == "align" ? 1 : 0
	}

	static SetFormatLineAlign(FormatHandle) {
		this.Events.Push("line-align:" . FormatHandle)
		return this.FailAt == "line-align" ? 1 : 0
	}
}

_WPMGO_Join(Values) {
	Output := ""
	for Value in Values
		Output .= (Output == "" ? "" : ",") . Value
	return Output
}





_WPMGO_StartupFailureReleasesLoadedModule() {
	_WPMGO_Native.Reset("startup")
	Result := _WPMGdipAcquire(15, _WPMGO_Native)
	AssertFalse(Result["ok"])
	AssertFalse(Result["receipt"] is Map,
		"a successful rollback must leave no retained cleanup receipt")
	AssertEqual("load,startup,free:101", _WPMGO_Join(_WPMGO_Native.Events),
		"startup refusal must balance the already loaded module")
}
Test("wpm GDI+ ownership: startup failure releases the module",
	_WPMGO_StartupFailureReleasesLoadedModule)

_WPMGO_FontFailureReleasesDependenciesInReverse() {
	_WPMGO_Native.Reset("font")
	Result := _WPMGdipAcquire(15, _WPMGO_Native)
	AssertFalse(Result["ok"])
	AssertEqual("load,startup,family:Segoe UI,font:303:15,delete-family:303,shutdown:202,free:101",
		_WPMGO_Join(_WPMGO_Native.Events),
		"font refusal must release family, token, and module in reverse order")
}
Test("wpm GDI+ ownership: font failure rolls back every dependency",
	_WPMGO_FontFailureReleasesDependenciesInReverse)

_WPMGO_FormatSetupFailureReleasesEveryHandle() {
	_WPMGO_Native.Reset("line-align")
	Result := _WPMGdipAcquire(15, _WPMGO_Native)
	AssertFalse(Result["ok"])
	AssertEqual("load,startup,family:Segoe UI,font:303:15,format,align:505,line-align:505,delete-format:505,delete-font:404,delete-family:303,shutdown:202,free:101",
		_WPMGO_Join(_WPMGO_Native.Events),
		"format setup refusal must release the complete partial graph transaction")
}
Test("wpm GDI+ ownership: format setup failure releases every handle",
	_WPMGO_FormatSetupFailureReleasesEveryHandle)

_WPMGO_CleanupRefusalRetainsExactDebt() {
	_WPMGO_Native.Reset("", "font")
	Result := _WPMGdipAcquire(15, _WPMGO_Native)
	AssertTrue(Result["ok"], "setup must create a complete ownership receipt")
	Receipt := Result["receipt"]
	AssertFalse(_WPMGdipRelease(Receipt, _WPMGO_Native),
		"the first injected font deletion must remain unresolved")
	AssertEqual(0, Receipt["format"],
		"successfully deleted children must retire from the receipt")
	AssertEqual(404, Receipt["font"],
		"the refused font and all its dependencies must remain owned")
	AssertEqual(303, Receipt["family"])
	AssertEqual(202, Receipt["token"])
	AssertEqual(101, Receipt["module"])
	_WPMGO_Native.CleanupFailAt := ""
	AssertTrue(_WPMGdipRelease(Receipt, _WPMGO_Native),
		"the exact retained receipt must be retryable")
	for Key in ["format", "font", "family", "token", "module"]
		AssertEqual(0, Receipt[Key], "successful retry must retire " . Key)
}
Test("wpm GDI+ ownership: cleanup refusal retains exact retry debt",
	_WPMGO_CleanupRefusalRetainsExactDebt)





class _WPMGF_Native {
	static Events := []
	static CleanupFailAt := ""
	static CreateStatus := 0
	static NextHandle := 700

	static Reset(CleanupFailAt := "", CreateStatus := 0) {
		this.Events := []
		this.CleanupFailAt := CleanupFailAt
		this.CreateStatus := CreateStatus
		this.NextHandle := 700
	}

	static CreateGraphics(MemDC, &Graphics) {
		this.Events.Push("create-graphics:" . MemDC)
		Graphics := 601
		return this.CreateStatus
	}

	static DeleteGraphics(Graphics) {
		this.Events.Push("delete-graphics:" . Graphics)
		return this.CleanupFailAt == "graphics" ? 1 : 0
	}

	static SetSmoothing(Graphics) {
		this.Events.Push("smoothing:" . Graphics)
		return 0
	}

	static SetTextRendering(Graphics) {
		this.Events.Push("text-rendering:" . Graphics)
		return 0
	}

	static DeletePath(Path) {
		this.Events.Push("delete-path:" . Path)
		return this.CleanupFailAt == "path" ? 1 : 0
	}

	static DeleteBrush(Brush) {
		this.Events.Push("delete-brush:" . Brush)
		return this.CleanupFailAt == "brush" ? 1 : 0
	}

	static DeletePen(Pen) {
		this.Events.Push("delete-pen:" . Pen)
		return this.CleanupFailAt == "pen" ? 1 : 0
	}

	static CreatePath(&Path) {
		Path := this.NextHandle++
		this.Events.Push("create-path:" . Path)
		return 0
	}

	static AddPathArc(Path, X, Y, W, H, Start, Sweep) {
		this.Events.Push("arc:" . Path)
		return 0
	}

	static ClosePath(Path) {
		this.Events.Push("close-path:" . Path)
		return 0
	}

	static CreateBrush(Color, &Brush) {
		Brush := this.NextHandle++
		this.Events.Push("create-brush:" . Brush)
		return 0
	}

	static FillPath(Graphics, Brush, Path) {
		this.Events.Push("fill-path:" . Brush)
		return 0
	}

	static CreatePen(Color, Width, &Pen) {
		Pen := this.NextHandle++
		this.Events.Push("create-pen:" . Pen)
		return 0
	}

	static DrawPath(Graphics, Pen, Path) {
		this.Events.Push("draw-path:" . Pen)
		return 0
	}

	static SetClipPath(Graphics, Path) {
		this.Events.Push("set-clip:" . Path)
		return 0
	}

	static FillPolygon(Graphics, Brush, Points, Count) {
		this.Events.Push("fill-polygon:" . Brush . ":" . Count)
		return 0
	}

	static DrawLines(Graphics, Pen, Points, Count) {
		this.Events.Push("draw-lines:" . Pen . ":" . Count)
		return 0
	}

	static ResetClip(Graphics) {
		this.Events.Push("reset-clip:" . Graphics)
		return 0
	}

	static DrawString(Graphics, Text, Font, Rect, FormatHandle, Brush) {
		this.Events.Push("draw-string:" . Brush . ":" . Text)
		return 0
	}
}





_WPMGF_DrawThenThrow(Graphics, Receipt, Native) {
	_WPMGdipFrameOwn(Receipt, "path", 602)
	_WPMGdipFrameOwn(Receipt, "brush", 603)
	throw Error("injected draw failure")
}

_WPMGF_DrawWithPen(Graphics, Receipt, Native) {
	_WPMGdipFrameOwn(Receipt, "path", 602)
	_WPMGdipFrameOwn(Receipt, "pen", 604)
}

_WPMGF_MustNotDraw(Graphics, Receipt, Native) {
	throw Error("draw callback ran after a refused graphics creation")
}

_WPMGF_DrawFailureStillReleasesEveryHandle() {
	_WPMGF_Native.Reset()
	Result := _WPMGdipRunFrame(77, _WPMGF_DrawThenThrow, _WPMGF_Native)
	AssertFalse(Result["ok"])
	AssertFalse(Result["receipt"] is Map,
		"a successful exceptional rollback must leave no retained frame debt")
	AssertEqual("create-graphics:77,smoothing:601,text-rendering:601,delete-brush:603,delete-path:602,delete-graphics:601",
		_WPMGO_Join(_WPMGF_Native.Events),
		"draw exceptions must release every frame handle in reverse order")
}
Test("wpm GDI+ frame: draw exceptions release every native handle",
	_WPMGF_DrawFailureStillReleasesEveryHandle)

_WPMGF_CleanupRefusalRetainsTheWholeDependencyTail() {
	_WPMGF_Native.Reset("pen")
	Result := _WPMGdipRunFrame(77, _WPMGF_DrawWithPen, _WPMGF_Native)
	AssertFalse(Result["ok"])
	AssertTrue(Result["receipt"] is Map,
		"a refused frame deletion must publish exact cleanup debt")
	AssertEqual(3, Result["receipt"]["resources"].Length,
		"the failed pen plus path and graphics dependencies must remain owned")
	_WPMGF_Native.CleanupFailAt := ""
	AssertTrue(_WPMGdipFrameRelease(Result["receipt"], _WPMGF_Native))
	AssertEqual("create-graphics:77,smoothing:601,text-rendering:601,delete-pen:604,delete-pen:604,delete-path:602,delete-graphics:601",
		_WPMGO_Join(_WPMGF_Native.Events),
		"the retained dependency tail must be retried in exact reverse order")
}
Test("wpm GDI+ frame: refused cleanup retains exact retry debt",
	_WPMGF_CleanupRefusalRetainsTheWholeDependencyTail)

_WPMGF_AmbiguousCreateHandleIsStillOwned() {
	_WPMGF_Native.Reset("", 7)
	Result := _WPMGdipRunFrame(77, _WPMGF_MustNotDraw, _WPMGF_Native)
	AssertFalse(Result["ok"])
	AssertEqual("create-graphics:77,delete-graphics:601",
		_WPMGO_Join(_WPMGF_Native.Events),
		"a failed create status with a non-null handle must still release that handle")
}
Test("wpm GDI+ frame: ambiguous failed creates cannot leak a handle",
	_WPMGF_AmbiguousCreateHandleIsStillOwned)

_WPMGF_RealDrawFunctionRoutesEveryAllocationThroughReceipt() {
	_WPMGF_Native.Reset()
	Receipt := _WPMGdipNewFrameReceipt()
	WPMWidget_DrawGraph(601, 160, 80, "42 WPM", "#4499FF", [10, 20],
		Receipt, _WPMGF_Native, 15, 120)
	AssertEqual(6, Receipt["resources"].Length,
		"path, background brush/pen, graph brush/pen, and label brush must be owned")
	AssertTrue(InStr(_WPMGO_Join(_WPMGF_Native.Events), "draw-string:") > 0,
		"the injected native path must reach the terminal label draw")
	AssertTrue(_WPMGdipFrameRelease(Receipt, _WPMGF_Native))
	AssertEqual(0, Receipt["resources"].Length,
		"the real WPM drawing function must leave one fully releasable receipt")
}
Test("wpm GDI+ frame: the real graph draw owns every allocation",
	_WPMGF_RealDrawFunctionRoutesEveryAllocationThroughReceipt)

_WPMGF_DrawActualGraph(Graphics, Receipt, Native) {
	WPMWidget_DrawGraph(Graphics, 160, 80, "42 WPM", "#4499FF",
		[10, 20], Receipt, Native, 15, 120)
}

_WPMGF_ActualGdiPlusFrameCompletesWithoutLeaking() {
	ScreenDC := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
	AssertTrue(ScreenDC != 0, "the native smoke needs a screen-compatible DC")
	MemDC := 0
	Bitmap := 0
	OldBitmap := 0
	InitReceipt := 0
	FrameReceipt := 0
	try {
		MemDC := DllCall("Gdi32\CreateCompatibleDC", "Ptr", ScreenDC, "Ptr")
		AssertTrue(MemDC != 0)
		Bitmap := DllCall("Gdi32\CreateCompatibleBitmap", "Ptr", ScreenDC,
			"Int", 160, "Int", 80, "Ptr")
		AssertTrue(Bitmap != 0)
		OldBitmap := DllCall("Gdi32\SelectObject", "Ptr", MemDC,
			"Ptr", Bitmap, "Ptr")
		AssertTrue(OldBitmap != 0)

		InitResult := _WPMGdipAcquire(15)
		AssertTrue(InitResult["ok"],
			"the native GDI+ initialization smoke must acquire a complete receipt")
		InitReceipt := InitResult["receipt"]
		WPMWidget._gdip_font := InitReceipt["font"]
		WPMWidget._gdip_fmt := InitReceipt["format"]
		FrameResult := _WPMGdipRunFrame(MemDC, _WPMGF_DrawActualGraph)
		if FrameResult["receipt"] is Map
			FrameReceipt := FrameResult["receipt"]
		AssertTrue(FrameResult["ok"],
			"the production GDI+ signatures must render and release one real frame")
	} finally {
		if FrameReceipt is Map
			_WPMGdipFrameRelease(FrameReceipt)
		WPMWidget._gdip_font := 0
		WPMWidget._gdip_fmt := 0
		if InitReceipt is Map
			_WPMGdipRelease(InitReceipt)
		if (MemDC and OldBitmap)
			DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", OldBitmap,
				"Ptr")
		if Bitmap
			DllCall("Gdi32\DeleteObject", "Ptr", Bitmap, "Int")
		if MemDC
			DllCall("Gdi32\DeleteDC", "Ptr", MemDC, "Int")
		if ScreenDC
			DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", ScreenDC, "Int")
	}
}
Test("wpm GDI+ frame: production DllCall signatures render a real bitmap",
	_WPMGF_ActualGdiPlusFrameCompletesWithoutLeaking)
