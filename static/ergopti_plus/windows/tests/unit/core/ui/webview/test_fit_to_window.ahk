; tests/unit/core/ui/webview/test_fit_to_window.ahk

; ==============================================================================
; MODULE: WebView Window Resize Regression
; DESCRIPTION:
; A WebView2 controller fills its parent window. The hosts parent it to a
; placeholder Text control created at the opening size, so a resize that only
; called Fill() kept the page at that size: widening the layout manager left
; the composer cramped beside an empty band. These tests use real hidden native
; windows and a passive controller that records the rect Fill() would read.
; ==============================================================================

#Requires AutoHotkey v2.0

; Records the parent's client size at each Fill(), as the vendor wrapper reads it.
class _WVFW_Controller {
	__New(ParentWindow) {
		this.ParentWindow := ParentWindow
		this.Filled := []
	}
	Fill() {
		this.Filled.Push(_WVFW_ClientSize(this.ParentWindow))
	}
}

_WVFW_ClientSize(Hwnd) {
	Rect := Buffer(16, 0)
	AssertTrue(DllCall("user32\GetClientRect", "ptr", Hwnd, "ptr", Rect, "int"), "client rect readable")
	return NumGet(Rect, 8, "int") . "x" . NumGet(Rect, 12, "int")
}

_WVFW_Window() {
	Window := Gui("+Resize")
	Window.MarginX := 0, Window.MarginY := 0
	Placeholder := Window.Add("Text", "x0 y0 w320 h200", "")
	Window.Show("Hide w320 h200")
	return {Window: Window, Placeholder: Placeholder}
}

_WVFW_GrowsThePlaceholder() {
	Host := _WVFW_Window()
	try {
		Host.Window.Show("Hide w900 h640")
		Expected := _WVFW_ClientSize(Host.Window.Hwnd)
		Controller := _WVFW_Controller(Host.Placeholder.Hwnd)
		WebView_FitToWindow(Controller)
		AssertEqual(1, Controller.Filled.Length, "the controller is filled once")
		AssertEqual(Expected, Controller.Filled[1], "the placeholder is resized before Fill reads it")
		AssertEqual(Expected, _WVFW_ClientSize(Host.Placeholder.Hwnd))
	} finally Host.Window.Destroy()
}

_WVFW_LeavesATopLevelParent() {
	Host := _WVFW_Window()
	try {
		Before := _WVFW_ClientSize(Host.Window.Hwnd)
		Controller := _WVFW_Controller(Host.Window.Hwnd)
		WebView_FitToWindow(Controller)
		AssertEqual(Before, _WVFW_ClientSize(Host.Window.Hwnd), "a top-level parent is never moved")
		AssertEqual(Before, Controller.Filled[1])
	} finally Host.Window.Destroy()
}

_WVFW_LayoutManagerFollowsItsWindow() {
	global _LayMgrWeb_Controller
	Window := _LayMgrWeb_NewWindow()
	try {
		Style := DllCall("user32\GetWindowLongPtrW", "ptr", Window.Hwnd, "int", -16, "ptr")
		AssertTrue(Style & 0x40000, "the layout manager window has a sizing border (WS_THICKFRAME)")
		AssertTrue(Style & 0x10000, "the layout manager window can be maximized (WS_MAXIMIZEBOX)")
		Window.MarginX := 0, Window.MarginY := 0
		Placeholder := Window.Add("Text", "x0 y0 w720 h560", "")
		Window.Show("Hide w1200 h800")
		Previous := IsSet(_LayMgrWeb_Controller) ? _LayMgrWeb_Controller : 0
		_LayMgrWeb_Controller := _WVFW_Controller(Placeholder.Hwnd)
		try _LayMgrWeb_OnResize(Window, 0, 1200, 800)
		finally {
			Controller := _LayMgrWeb_Controller
			if IsObject(Previous)
				_LayMgrWeb_Controller := Previous
			else
				_LayMgrWeb_Controller := unset
		}
		Expected := _WVFW_ClientSize(Window.Hwnd)
		AssertEqual(1, Controller.Filled.Length, "the resize fills the page")
		AssertEqual(Expected, Controller.Filled[1], "the page follows the widened window")
	} finally Window.Destroy()
}

; Every Size handler resizes the control hosting its page, never Fill() alone.
_WVFW_NoHandlerFillsAFixedPlaceholder() {
	Source := _DriverSourceNoComments()
	Position := 1, Handlers := 0, Fitted := 0
	; Definitions only: the signature is followed by its opening brace.
	while RegExMatch(Source, "im)^[ \t]*(\w*On(?:Gui)?(?:Resize|Size))\([^)\r\n]*\)\s*\{", &Match, Position) {
		Position := Match.Pos + Match.Len
		Body := _DriverFuncBody(Match[1])
		AssertTrue(InStr(Body, Match[1] . "("), "the scanned body is the handler's own")
		Handlers += 1
		if InStr(Body, "WebView_FitToWindow(")
			Fitted += 1
		AssertFalse(InStr(Body, ".Fill()") && !InStr(Body, ".Move(0, 0, "),
			Match[1] . " fills its page without resizing the control that hosts it")
	}
	AssertTrue(Handlers >= 14, "the scan reaches the WebView Size handlers (" . Handlers . ")")
	AssertTrue(Fitted >= 11, "the placeholder hosts fit through the shared helper (" . Fitted . ")")
}

Test("WebView resize: the placeholder grows to the window before Fill (webview-fit-to-window)", _WVFW_GrowsThePlaceholder)
Test("WebView resize: a controller parented to its window is only filled (webview-fit-to-window)", _WVFW_LeavesATopLevelParent)
Test("WebView resize: the layout manager is resizable and its page follows it (webview-fit-to-window)", _WVFW_LayoutManagerFollowsItsWindow)
Test("WebView resize: no Size handler fills a fixed placeholder (webview-fit-to-window)", _WVFW_NoHandlerFillsAFixedPlaceholder)
