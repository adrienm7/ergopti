; tests/unit/core/ui/webview/test_model_browser_webview_only.ahk

; ==============================================================================
; MODULE: Model Browser WebView-Only Refusal Test
; DESCRIPTION:
; The LLM model browser has no native ListView any more (maintainer decision
; 2026-11-21): it used to open one whenever WebView2 was missing, and that
; window popped up on the desktop during every AHK run. Its public entry runs
; here with a genuinely absent WebView2 loader: nothing opens, no window of
; this process remains, the WebView2-required message is shown exactly once,
; and the refusal is logged at ERROR with its reason.
; ==============================================================================

#Requires AutoHotkey v2.0

; Every top-level window this process owns, hidden ones included.
_MBWO_OwnWindows() {
	PreviousDetect := DetectHiddenWindows(true)
	try return WinGetList("ahk_class AutoHotkeyGUI ahk_pid " . ProcessExist())
	finally DetectHiddenWindows(PreviousDetect)
}

_MBWO_AbsentWebViewRefuses() {
	global _VendorDir, _LOGGER_TEST_SINK
	Root := A_Temp . "\ergopti_model_browser_webview_only_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Root)
	AssertTrue((Creation is Integer) && Creation == 1, "Only an exclusively acquired private root may be removed")
	OldVendor := _VendorDir, PreviousSink := _LOGGER_TEST_SINK
	Logs := [], Shown := [], Result := "unset", Created := [], Reason := ""
	ShownBefore := TestMsgBoxCount()
	Before := Map()
	for Hwnd in _MBWO_OwnWindows()
		Before[Hwnd] := true
	try {
		; The suite loads no WebView2 binding, and the private root holds no
		; 64bit\WebView2Loader.dll either: the genuine availability branch
		; refuses, with no browser port replaced.
		_VendorDir := Root
		Reason := WebView_UnavailableReason()
		TestMsgBoxResponder((Text, Title, Options) => (Shown.Push({ Text: Text, Title: Title, Options: Options }), ""))
		_LoggerFlushRepeats(true)
		LoggerSetTestSink((Line) => Logs.Push(Line))
		Result := LLM_ModelBrowser_Show()
		_LoggerFlushRepeats(true)
	} finally {
		LoggerSetTestSink(PreviousSink)
		TestMsgBoxResponder("")
		_VendorDir := OldVendor
		DirDelete(Root, true)
		; Count before cleanup, then retire anything a regression opened so a
		; failing run leaves no window on the desktop.
		for Hwnd in _MBWO_OwnWindows()
			if !Before.Has(Hwnd)
				Created.Push(Hwnd)
		for Hwnd in Created
			try GuiFromHwnd(Hwnd).Destroy()
	}
	AssertTrue((Result is Integer) && Result == 0, "a refused model browser opening must report that nothing opened")
	AssertEqual(0, Created.Length, "no native browser or retained host window may remain after the refusal")
	AssertFalse(IsSet(_LLM_MBW_Gui), "the WebView host must not publish a window")
	AssertEqual(ShownBefore + 1, TestMsgBoxCount(), "the user must be told exactly once")
	AssertEqual(1, Shown.Length)
	AssertEqual(t("webview.required"), Shown[1].Text, "the message must be the shared WebView2-required text")
	Errors := []
	for Line in Logs
		if InStr(Line, "[ERROR]") && InStr(Line, "The model browser cannot open: WebView2 is required")
			Errors.Push(Line)
	AssertEqual(1, Errors.Length, "the refusal must be logged once at ERROR")
	AssertTrue(Reason != "", "the suite must genuinely lack a usable WebView2")
	AssertContains(Errors[1], "(" . Reason . ")", "the logged reason must name what failed")
}

Test("LLM model browser: an absent WebView2 shows the required message and builds no native window (model-browser-webview-only)",
	_MBWO_AbsentWebViewRefuses)
