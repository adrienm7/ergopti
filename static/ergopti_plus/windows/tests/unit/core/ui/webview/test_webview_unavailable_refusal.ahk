; tests/unit/core/ui/webview/test_webview_unavailable_refusal.ahk

; ==============================================================================
; MODULE: WebView Unavailable Refusal Tests
; DESCRIPTION:
; No WebView window has a native substitute (maintainer decision 2026-11-21).
; The shared admission names why WebView2 cannot open, and the refusal shows the
; one localized message that says how to recover: update a runtime below the
; minimum, else install or repair WebView2.
; ==============================================================================

#Requires AutoHotkey v2.0

_WVUR_Value(Value) {
	return Value
}

; Runs Body with a captured MsgBox and log sink.
_WVUR_With(Body) {
	global _LOGGER_TEST_SINK
	PreviousSink := _LOGGER_TEST_SINK
	World := {Shown: [], Logs: [], Result: "unset"}
	try {
		TestMsgBoxResponder((Text, Title, Options) => (World.Shown.Push({Text: Text, Title: Title, Options: Options}), ""))
		_LoggerFlushRepeats(true)
		LoggerSetTestSink((Line) => World.Logs.Push(Line))
		Body.Call(World)
		_LoggerFlushRepeats(true)
	} finally {
		LoggerSetTestSink(PreviousSink)
		TestMsgBoxResponder("")
	}
	return World
}

_WVUR_ErrorLines(World, Surface) {
	Lines := []
	for Line in World.Logs
		if InStr(Line, "[ERROR]") && InStr(Line, "The " . Surface . " cannot open: WebView2 is required")
			Lines.Push(Line)
	return Lines
}

; The minimum is compared part by part: "100.0" is newer than "87.0.664.8" though
; a string comparison says otherwise. No runtime at all is left to creation.
_WVUR_RuntimeMinimum() {
	global WEBVIEW_MIN_RUNTIME_VERSION
	for Version in ["", WEBVIEW_MIN_RUNTIME_VERSION, "87.0.664.9", "100.0.0.0", "141.0.3537.71"]
		AssertFalse(WebView_RuntimeIsRefused(_WVUR_Value.Bind(Version)), "version '" . Version . "' is admitted")
	for Version in ["87.0.664.7", "86.0.622.38", "9.0.0.0"]
		AssertTrue(WebView_RuntimeIsRefused(_WVUR_Value.Bind(Version)), "version " . Version . " is refused")
}
Test("webview-refusal: a runtime below the minimum is refused, compared part by part (webview-no-native-fallback)",
	_WVUR_RuntimeMinimum)

; The unit suite never loads the vendored binding, so its genuine admission
; refuses here exactly as on a machine without WebView2.
_WVUR_AbsentBindingRefuses() {
	World := _WVUR_With((W) => (W.Result := WebView_RequireAvailable("probe window", _WVUR_Value.Bind(""))))
	AssertFalse(World.Result, "an absent binding admits nothing")
	AssertEqual(1, World.Shown.Length, "the user is told exactly once")
	AssertEqual(t("webview.required"), World.Shown[1].Text, "the message says to install WebView2")
	AssertEqual(WindowTitle(t("common.error_title")), World.Shown[1].Title, "under the shared error caption")
	Lines := _WVUR_ErrorLines(World, "probe window")
	AssertEqual(1, Lines.Length, "the refusal is logged once at ERROR")
	AssertContains(Lines[1], "the WebView2 binding is not loaded", "the log names what failed")
}
Test("webview-refusal: an absent WebView2 shows the WebView2-required message once (webview-no-native-fallback)",
	_WVUR_AbsentBindingRefuses)

_WVUR_OldRuntimeRefuses() {
	global WEBVIEW_MIN_RUNTIME_VERSION
	World := _WVUR_With((W) => (W.Result := WebView_RefuseUnavailable("probe window", "creation failed",
		_WVUR_Value.Bind("86.0.622.38"))))
	AssertFalse(World.Result, "a refusal opens nothing")
	AssertEqual(1, World.Shown.Length, "the user is told exactly once")
	AssertContains(World.Shown[1].Text, WEBVIEW_MIN_RUNTIME_VERSION, "the message names the minimum")
	AssertContains(World.Shown[1].Text, "86.0.622.38", "and the version found")
	AssertContains(World.Shown[1].Text, "https://go.microsoft.com/fwlink/p/?LinkId=2124703",
		"and where to update it")
	Lines := _WVUR_ErrorLines(World, "probe window")
	AssertEqual(1, Lines.Length, "the refusal is logged once at ERROR")
	AssertContains(Lines[1], "creation failed", "the log keeps the reason")
}
Test("webview-refusal: a runtime below the minimum says to update it, with no simple form (webview-no-native-fallback)",
	_WVUR_OldRuntimeRefuses)

_WVUR_CurrentRuntimeSaysInstall() {
	World := _WVUR_With((W) => WebView_RefuseUnavailable("probe window", "creation failed",
		_WVUR_Value.Bind("141.0.3537.71")))
	AssertEqual(1, World.Shown.Length, "the user is told exactly once")
	AssertEqual(t("webview.required"), World.Shown[1].Text, "a current runtime that failed is installed or repaired")
}
Test("webview-refusal: a failed current runtime says to install or repair WebView2 (webview-no-native-fallback)",
	_WVUR_CurrentRuntimeSaysInstall)

; No locale may still promise the removed simple form.
_WVUR_NoSimpleFormPromise() {
	global _SharedDir
	for Lang in StrSplit("ar cs da de en es fr he hi it ja ko nl no pl pt ru sv tr uk zh", " ") {
		Data := JsonParse(FileRead(_SharedDir . "\core\i18n\data\locales\" . Lang . ".json", "UTF-8"))
		AssertContains(Data["webview.runtime_too_old"], "https://go.microsoft.com/fwlink/p/?LinkId=2124703",
			Lang . ": the old-runtime message must say where to update")
	}
}
Test("webview-refusal: every locale tells where to update an old runtime (webview-no-native-fallback)",
	_WVUR_NoSimpleFormPromise)
