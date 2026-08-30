; tests/unit/test_spotlight_ownership.ahk

; ==============================================================================
; MODULE: Spotlight ownership tests
; DESCRIPTION:
; Exercises partial HWND acquisition and GDI+ Graphics cleanup without creating
; real windows or graphics resources in the headless suite.
; ==============================================================================

#Requires AutoHotkey v2.0

global _SOW_Events := []

_SOW_Reset() {
	global _SOW_Events := []
}

_SOW_Create(Opts) {
	global _SOW_Events
	_SOW_Events.Push("create")
	return 7101
}

_SOW_CreateZero(Opts) {
	global _SOW_Events
	_SOW_Events.Push("create")
	return 0
}

_SOW_DrawOk(Hwnd, PaintFn) {
	global _SOW_Events
	_SOW_Events.Push("draw:" . Hwnd)
}

_SOW_DrawFails(Hwnd, PaintFn) {
	global _SOW_Events
	_SOW_Events.Push("draw:" . Hwnd)
	throw Error("injected draw refusal")
}

_SOW_ShowOk(Hwnd) {
	global _SOW_Events
	_SOW_Events.Push("show:" . Hwnd)
}

_SOW_ShowFails(Hwnd) {
	global _SOW_Events
	_SOW_Events.Push("show:" . Hwnd)
	throw Error("injected show refusal")
}

_SOW_Destroy(Hwnd) {
	global _SOW_Events
	_SOW_Events.Push("destroy:" . Hwnd)
}

_SOW_NoPaint(*) {
}

_SOW_Join(Values) {
	Output := ""
	for Value in Values
		Output .= (Output == "" ? "" : ",") . Value
	return Output
}

_SOW_JoinEvents() {
	global _SOW_Events
	return _SOW_Join(_SOW_Events)
}





_SOW_DrawFailureDestroysPartialWindow() {
	_SOW_Reset()
	Threw := false
	try _SpotlightCreateOverlayWindow(Map(), _SOW_NoPaint, _SOW_Create,
		_SOW_DrawFails, _SOW_ShowOk, _SOW_Destroy)
	catch Error
		Threw := true
	AssertTrue(Threw, "the injected draw failure must propagate")
	AssertEqual("create,draw:7101,destroy:7101", _SOW_JoinEvents(),
		"the creator must destroy an HWND whose draw step failed")
}
Test("spotlight ownership: draw failure destroys the unpublished window",
	_SOW_DrawFailureDestroysPartialWindow)

_SOW_ShowFailureDestroysPartialWindow() {
	_SOW_Reset()
	Threw := false
	try _SpotlightCreateOverlayWindow(Map(), _SOW_NoPaint, _SOW_Create,
		_SOW_DrawOk, _SOW_ShowFails, _SOW_Destroy)
	catch Error
		Threw := true
	AssertTrue(Threw, "the injected show failure must propagate")
	AssertEqual("create,draw:7101,show:7101,destroy:7101", _SOW_JoinEvents(),
		"the creator must destroy an HWND whose show step failed")
}
Test("spotlight ownership: show failure destroys the unpublished window",
	_SOW_ShowFailureDestroysPartialWindow)

_SOW_SuccessTransfersWindowOnce() {
	_SOW_Reset()
	Hwnd := _SpotlightCreateOverlayWindow(Map(), _SOW_NoPaint, _SOW_Create,
		_SOW_DrawOk, _SOW_ShowOk, _SOW_Destroy)
	AssertEqual(7101, Hwnd, "successful preparation must return the owned HWND")
	AssertEqual("create,draw:7101,show:7101", _SOW_JoinEvents(),
		"a transferred HWND must not be destroyed by its former owner")
	_SOW_Reset()
	AssertEqual(0, _SpotlightCreateOverlayWindow(Map(), _SOW_NoPaint,
		_SOW_CreateZero, _SOW_DrawOk, _SOW_ShowOk, _SOW_Destroy))
	AssertEqual("create", _SOW_JoinEvents(),
		"a refused create must not invoke dependent operations")
}
Test("spotlight ownership: success transfers exactly one prepared window",
	_SOW_SuccessTransfersWindowOnce)





class _SOW_GdiNative {
	static Events := []

	static CreateGraphics(MemDC, &Graphics) {
		this.Events.Push("create:" . MemDC)
		Graphics := 8801
		return 0
	}

	static SetSmoothing(Graphics) {
		this.Events.Push("smooth:" . Graphics)
		return 0
	}

	static SetCompositingMode(Graphics) {
		this.Events.Push("mode:" . Graphics)
		return 0
	}

	static SetCompositingQuality(Graphics) {
		this.Events.Push("quality:" . Graphics)
		return 0
	}

	static DeleteGraphics(Graphics) {
		this.Events.Push("delete:" . Graphics)
		return 0
	}
}

_SOW_PaintFails(Graphics, W, H) {
	_SOW_GdiNative.Events.Push("paint:" . Graphics . ":" . W . "x" . H)
	throw Error("injected paint failure")
}

_SOW_GraphicsContextIsDeletedAfterPaintFailure() {
	_SOW_GdiNative.Events := []
	Threw := false
	try _SpotlightDrawWithGdiPlus(_SOW_PaintFails, 44, 120, 80,
		_SOW_GdiNative)
	catch Error
		Threw := true
	AssertTrue(Threw, "the injected paint failure must propagate")
	AssertEqual("create:44,smooth:8801,mode:8801,quality:8801,paint:8801:120x80,delete:8801",
		_SOW_Join(_SOW_GdiNative.Events),
		"DeleteGraphics must run exactly once after a callback failure")
}
Test("spotlight ownership: paint failure deletes the GDI+ Graphics context",
	_SOW_GraphicsContextIsDeletedAfterPaintFailure)





class _SOW_PaintNative {
	static Events := []
	static FailAt := ""

	static Reset(FailAt := "") {
		this.Events := []
		this.FailAt := FailAt
	}

	static CreateBrush(Color, &Brush) {
		this.Events.Push("create-brush")
		Brush := 5101
		return this.FailAt == "create-brush" ? 1 : 0
	}

	static DeleteBrush(Brush) {
		this.Events.Push("delete-brush:" . Brush)
		return this.FailAt == "delete-brush" ? 1 : 0
	}

	static FillEllipse(Graphics, Brush, X, Y, W, H) {
		this.Events.Push("fill-ellipse")
		return this.FailAt == "fill-ellipse" ? 1 : 0
	}

	static FillRectangle(Graphics, Brush, X, Y, W, H) {
		this.Events.Push("fill-rectangle")
		return this.FailAt == "fill-rectangle" ? 1 : 0
	}

	static CreatePen(Color, Width, &Pen) {
		this.Events.Push("create-pen")
		Pen := 5102
		return this.FailAt == "create-pen" ? 1 : 0
	}

	static DeletePen(Pen) {
		this.Events.Push("delete-pen:" . Pen)
		return this.FailAt == "delete-pen" ? 1 : 0
	}

	static DrawEllipse(Graphics, Pen, X, Y, W, H) {
		this.Events.Push("draw-ellipse")
		return this.FailAt == "draw-ellipse" ? 1 : 0
	}

	static DrawRectangle(Graphics, Pen, X, Y, W, H) {
		this.Events.Push("draw-rectangle")
		return this.FailAt == "draw-rectangle" ? 1 : 0
	}
}

_SOW_WithPaintDebtIsolated(TestFn) {
	global _SpotlightPaintCleanupDebt
	OriginalDebt := _SpotlightPaintCleanupDebt
	_SpotlightPaintCleanupDebt := []
	try TestFn.Call()
	finally _SpotlightPaintCleanupDebt := OriginalDebt
}

_SOW_CircleFailureReleasesItsPartialBrush() {
	_SOW_PaintNative.Reset("fill-ellipse")
	Threw := false
	try _SpotlightDrawCircleResources(11, 2, 10, 3, 0x10, 0x20,
		_SOW_PaintNative)
	catch Error
		Threw := true
	AssertTrue(Threw, "the injected ellipse failure must propagate")
	AssertEqual("create-brush,fill-ellipse,delete-brush:5101",
		_SOW_Join(_SOW_PaintNative.Events),
		"a circle failure before pen creation must still delete its brush")
}
Test("spotlight paint ownership: partial circle failures release the brush (spotlight-paint-resource-ownership)",
	_SOW_WithPaintDebtIsolated.Bind(_SOW_CircleFailureReleasesItsPartialBrush))

_SOW_CrossSuccessReleasesPenThenBrush() {
	_SOW_PaintNative.Reset()
	_SpotlightDrawCrossResources(11, 2, 10, 6, 2, 0x10, 0x20,
		_SOW_PaintNative)
	AssertEqual("create-brush,fill-rectangle,fill-rectangle,create-pen,draw-rectangle,draw-rectangle,delete-pen:5102,delete-brush:5101",
		_SOW_Join(_SOW_PaintNative.Events),
		"the completed cross must unwind every resource in reverse order")
}
Test("spotlight paint ownership: completed crosses release every handle (spotlight-paint-resource-ownership)",
	_SOW_WithPaintDebtIsolated.Bind(_SOW_CrossSuccessReleasesPenThenBrush))

_SOW_RefusedCleanupBlocksNewPaintUntilRetry() {
	global _SpotlightPaintCleanupDebt
	_SOW_PaintNative.Reset("delete-pen")
	try _SpotlightDrawCircleResources(11, 2, 10, 3, 0x10, 0x20,
		_SOW_PaintNative)
	AssertEqual(1, _SpotlightPaintCleanupDebt.Length,
		"a refused pen deletion must retain the exact paint receipt")
	CreatesBefore := _SOW_CountPaintEvent("create-brush")
	try _SpotlightDrawCircleResources(11, 2, 10, 3, 0x10, 0x20,
		_SOW_PaintNative)
	AssertEqual(CreatesBefore, _SOW_CountPaintEvent("create-brush"),
		"persistent cleanup debt must block every new paint allocation")
	_SOW_PaintNative.FailAt := ""
	_SpotlightDrawCircleResources(11, 2, 10, 3, 0x10, 0x20,
		_SOW_PaintNative)
	AssertEqual(0, _SpotlightPaintCleanupDebt.Length)
}

_SOW_CountPaintEvent(Expected) {
	Count := 0
	for Event in _SOW_PaintNative.Events {
		if Event == Expected
			Count += 1
	}
	return Count
}
Test("spotlight paint ownership: refused cleanup blocks allocations until retry (spotlight-paint-resource-ownership)",
	_SOW_WithPaintDebtIsolated.Bind(_SOW_RefusedCleanupBlocksNewPaintUntilRetry))
