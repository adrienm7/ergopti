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
