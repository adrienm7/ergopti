; tests/unit/ui/webview/test_personal_editors_webview_only.ahk

; ==============================================================================
; MODULE: Personal Editors WebView-Only Refusal Tests
; DESCRIPTION:
; The Windows personal editors have no native form (maintainer decision
; 2026-11-11). Their public entry points run with a genuinely absent WebView2
; loader: no Gui may remain, the WebView2-required message is shown exactly
; once, and the refusal is logged at ERROR with the reason.
; ==============================================================================

#Requires AutoHotkey v2.0

; Every top-level window this process owns, hidden ones included.
_PEWO_OwnWindows() {
	PreviousDetect := DetectHiddenWindows(true)
	try return WinGetList("ahk_class AutoHotkeyGUI ahk_pid " . ProcessExist())
	finally DetectHiddenWindows(PreviousDetect)
}

_PEWO_Case(Surface, OpenFn, StateFn) {
	global _VendorDir, _LOGGER_TEST_SINK
	Root := A_Temp . "\ergopti_webview_only_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Root)
	AssertTrue((Creation is Integer) && Creation == 1, "Only an exclusively acquired private root may be removed")
	OldVendor := _VendorDir, PreviousSink := _LOGGER_TEST_SINK
	Logs := [], Shown := [], Result := "unset"
	ShownBefore := TestMsgBoxCount()
	Before := Map()
	for Hwnd in _PEWO_OwnWindows()
		Before[Hwnd] := true
	try {
		; The private root holds no 64bit\WebView2Loader.dll: the genuine
		; availability branch refuses, with no browser port replaced.
		_VendorDir := Root
		TestMsgBoxResponder((Text, Title, Options) => (Shown.Push({ Text: Text, Title: Title, Options: Options }), ""))
		_LoggerFlushRepeats(true)
		LoggerSetTestSink((Line) => Logs.Push(Line))
		Result := OpenFn.Call()
		_LoggerFlushRepeats(true)
	} finally {
		LoggerSetTestSink(PreviousSink)
		TestMsgBoxResponder("")
		_VendorDir := OldVendor
		DirDelete(Root, true)
	}
	AssertTrue((Result is Integer) && Result == 0, "a refused WebView opening must report that nothing opened")
	Created := 0
	for Hwnd in _PEWO_OwnWindows()
		if !Before.Has(Hwnd)
			Created += 1
	AssertEqual(0, Created, "no native editor or retained host window may remain after the refusal")
	AssertFalse(StateFn.Call(), "the WebView host must not publish a window")
	AssertEqual(ShownBefore + 1, TestMsgBoxCount(), "the user must be told exactly once")
	AssertEqual(1, Shown.Length)
	AssertEqual(t("webview.required"), Shown[1].Text, "the message must be the shared WebView2-required text")
	Errors := []
	for Line in Logs
		if InStr(Line, "[ERROR]") && InStr(Line, "The " . Surface . " cannot open: WebView2 is required")
			Errors.Push(Line)
	AssertEqual(1, Errors.Length, "the refusal must be logged once at ERROR")
	AssertContains(Errors[1], "WebView2Loader.dll is missing", "the logged reason must name what failed")
}

Test("Personal hotstrings editor: an absent WebView2 shows the required message and builds no native Gui (personal-editors-webview-only)",
	_PEWO_Case.Bind("personal hotstrings editor", () => OpenPersonalEditor("alpha"), () => IsObject(_HsEdWeb_Gui)))

Test("Personal information editor: an absent WebView2 shows the required message and builds no native Gui (personal-editors-webview-only)",
	_PEWO_Case.Bind("personal information editor", () => PersonalInformationEditor(), () => IsObject(_PiEdWeb_Gui)))
