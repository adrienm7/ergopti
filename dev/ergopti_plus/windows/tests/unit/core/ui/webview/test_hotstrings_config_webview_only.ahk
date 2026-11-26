; tests/unit/core/ui/webview/test_hotstrings_config_webview_only.ahk

; ==============================================================================
; MODULE: Hotstring Settings WebView-Only Refusal Tests
; DESCRIPTION:
; The hotstring settings window has no native form (maintainer decision
; 2026-11-21). Its public entry runs with the suite's genuinely absent WebView2
; binding: no Gui of this process may appear, the WebView2-required message is
; shown exactly once, and the refusal is logged at ERROR. The removed native
; window was built and shown instead.
; ==============================================================================

#Requires AutoHotkey v2.0

; Every top-level window this process owns, hidden ones included.
_HCWV_OwnWindows() {
	PreviousDetect := DetectHiddenWindows(true)
	try return WinGetList("ahk_class AutoHotkeyGUI ahk_pid " . ProcessExist())
	finally DetectHiddenWindows(PreviousDetect)
}

_HCWV_Case() {
	global _LOGGER_TEST_SINK, _HCWWeb_Gui
	PreviousSink := _LOGGER_TEST_SINK
	Logs := [], Shown := [], Result := "unset", Created := 0
	AssertTrue(WebView_UnavailableReason() != "", "The suite runs without a usable WebView2")
	ShownBefore := TestMsgBoxCount()
	Before := Map()
	for Hwnd in _HCWV_OwnWindows()
		Before[Hwnd] := true
	try {
		TestMsgBoxResponder((Text, Title, Options) => (Shown.Push({Text: Text, Title: Title}), ""))
		_LoggerFlushRepeats(true)
		LoggerSetTestSink((Line) => Logs.Push(Line))
		Result := OpenHotstringsConfigWindow()
		_LoggerFlushRepeats(true)
	} finally {
		LoggerSetTestSink(PreviousSink)
		TestMsgBoxResponder("")
		; Count what the opening built, then retire it so a regression cannot
		; linger on the desktop.
		for Hwnd in _HCWV_OwnWindows()
			if !Before.Has(Hwnd) {
				Created += 1
				try WinClose("ahk_id " . Hwnd)
			}
	}
	AssertEqual(0, Created, "No native settings window may be built without WebView2")
	AssertTrue((Result is Integer) && Result == 0, "A refused opening must report that nothing opened")
	AssertFalse(IsObject(_HCWWeb_Gui), "The WebView host must not publish a window")
	AssertEqual(ShownBefore + 1, TestMsgBoxCount(), "The user must be told exactly once")
	AssertEqual(1, Shown.Length)
	AssertEqual(t("webview.required"), Shown[1].Text, "The message must be the shared WebView2-required text")
	Errors := []
	for Line in Logs
		if InStr(Line, "[ERROR]") && InStr(Line, "The hotstring settings cannot open: WebView2 is required")
			Errors.Push(Line)
	AssertEqual(1, Errors.Length, "The refusal must be logged once at ERROR")
}

Test("Hotstring settings: an absent WebView2 shows the required message and builds no native window (hotstrings-config-webview-only)",
	_HCWV_Case)
