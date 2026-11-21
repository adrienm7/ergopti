; tests/unit/core/ui/webview/test_webview_take_focus.ahk

; ==============================================================================
; MODULE: WebView Keyboard Focus On Open (PCK-16)
; DESCRIPTION:
; Showing a host window focuses the host, not the browser: the page's own
; focus() then lands in a document without keyboard focus, so typing at once
; into the action picker, the prompt editor or a cleanup page did nothing until
; a click. macOS and Linux focus their web views on open. These tests run the
; real shared host build over a passive controller that records MoveFocus, and
; check that every production window creating a controller hands it the focus,
; unless the window is shown without activation.
; ==============================================================================

#Requires AutoHotkey v2.0

class _WVTF_View {
	__New() {
		this.Settings := {}
	}
	WebMessageReceived(Handler) => {}
	NavigationCompleted(Handler) => {}
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(*) => 0
}

class _WVTF_Controller {
	__New(ParentWindow) {
		this.ParentWindow := ParentWindow
		this.CoreWebView2 := _WVTF_View()
		this.Focus := []
		this.Closed := 0
	}
	MoveFocus(Reason) {
		this.Focus.Push(Reason)
	}
	Fill() {
	}
	Close() {
		this.Closed += 1
	}
}

class _WVTF_RefusingController extends _WVTF_Controller {
	MoveFocus(Reason) {
		throw OSError("controlled focus refusal")
	}
}

; The real build with only the native window hidden and the browser passive.
class _WVTF_Host extends WebViewHost {
	Probe := 0
	_ShowWindow(Window, Options) {
		this.ShownWith := Options
		Window.Show("Hide w320 h200")
	}
	_RuntimeAvailable(Loader) => true
	_CreateController(PlaceholderHwnd, Loader) {
		this.Probe := _WVTF_Controller(PlaceholderHwnd)
		return this.Probe
	}
}

_WVTF_Build(Opts) {
	Host := _WVTF_Host()
	Host.AppId := "pck16_focus_probe"
	Host.Opts := Opts
	Opts["Title"] := "pck-16 focus probe"
	Opts["OnMessage"] := (*) => 0
	try {
		AssertTrue(Host._Build(), "the passive host builds")
		return Host.Probe.Focus.Clone()
	} finally Host.Close()
}

_WVTF_HostHandsThePageTheFocus() {
	global WEBVIEW_MOVE_FOCUS_PROGRAMMATIC
	Focus := _WVTF_Build(Map())
	AssertEqual(1, Focus.Length, "pck-16: an activated window hands its page the keyboard once")
	AssertEqual(WEBVIEW_MOVE_FOCUS_PROGRAMMATIC, Focus[1], "the host moves the focus, not a Tab")
	AssertEqual(0, WEBVIEW_MOVE_FOCUS_PROGRAMMATIC, "COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC")
}
Test("webview focus: the shared host hands the page the keyboard on open (pck-16)", _WVTF_HostHandsThePageTheFocus)

_WVTF_NoActivateKeepsTheKeyboard() {
	AssertEqual(0, _WVTF_Build(Map("NoActivate", true)).Length,
		"a window shown without activation never takes the keyboard")
}
Test("webview focus: a window shown without activation leaves the keyboard alone (pck-16)", _WVTF_NoActivateKeepsTheKeyboard)

_WVTF_RefusalIsLogged() {
	Before := 0
	for Line in LoggerRingBufferSnapshot()
		if InStr(Line, "could not take the keyboard focus")
			Before += 1
	AssertFalse(WebView_TakeFocus(_WVTF_RefusingController(0)), "a refused focus is reported")
	After := 0
	for Line in LoggerRingBufferSnapshot()
		if InStr(Line, "could not take the keyboard focus")
			After += 1
	AssertEqual(Before + 1, After, "a refused focus is logged, never silent")
}
Test("webview focus: a refused focus is logged (pck-16)", _WVTF_RefusalIsLogged)

; Every production window that creates a controller hands it the focus, unless
; it is shown without activation (the error dialog) or its browser is a pane
; beside native buttons that keep the default focus (the update prompt's notes,
; named by the call that loads them).
_WVTF_EveryWindowTakesTheFocus() {
	Census := _DriverProductionSourceCensus()
	PaneOwners := ["_Updater_NavigateReleaseNotes"]
	Checked := 0, Missing := []
	for Path in Census.Paths {
		Code := _StripFullLineComments(FileRead(Path, "UTF-8"))
		if !InStr(Code, "WebView2.create(")
			continue
		Checked += 1
		if InStr(Code, "WebView_TakeFocus(") || InStr(Code, 'Show("NoActivate ')
			continue
		Pane := false
		for Owner in PaneOwners
			if InStr(Code, Owner . "(")
				Pane := true
		if !Pane
			Missing.Push(SubStr(Path, StrLen(Census.Root) + 2))
	}
	AssertTrue(Checked >= 15, "the census reaches every controller owner: " . Checked)
	AssertEqual("", _WVTF_Join(Missing), "pck-16: these windows never hand their page the keyboard")
}
Test("webview focus: every window creating a controller hands it the keyboard (pck-16)", _WVTF_EveryWindowTakesTheFocus)

_WVTF_Join(Items) {
	Text := ""
	for Item in Items
		Text .= (Text == "" ? "" : ", ") . Item
	return Text
}
