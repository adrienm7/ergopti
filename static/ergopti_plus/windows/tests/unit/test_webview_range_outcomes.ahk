; tests/unit/test_webview_range_outcomes.ahk

; ==============================================================================
; MODULE: WebView Range Native Outcome Tests
; DESCRIPTION:
; A native script rejection must retire only its staged file and UI request.
; Native success cannot delete a stage while the renderer still needs to fetch it.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/webview_script_fixture.ahk

_WVRO_RangeOutcome(Mode, View, Lines, Unhandled, Failure) {
	Path := _CTU_NewPath()
	Entry := Map("epoch", 51, "webview", View)
	KLWV.windows := Map("typing", Entry)
	try {
		AssertTrue(FSWrite(Path, "{}"))
		if Mode == "sync"
			View.Failure := Failure
		Accepted := KLWV_OnRangeBuildTerminal("typing", 51, 42, "ok", Path)
		AssertEqual(Mode != "sync", Accepted)
		if Mode != "sync" {
			AssertEqual(0, View.Messages.Length)
			AssertTrue(FSExists(Path))
			if Mode == "replace"
				KLWV.windows["typing"] := Map("epoch", 51, "webview", View)
			else if Mode == "close"
				KLWV.windows.Delete("typing")
			else if Mode == "pause"
				Suspend(true)
			if Mode == "success"
				View.Resolve.Call("null")
			else
				View.Reject.Call(Failure)
			_WVSO_Drain(View)
		}
		AssertEqual(0, Unhandled.Length)
		AssertEqual(Mode == "success", !!FSExists(Path),
			"only a rejected native call permits immediate stage removal")
		if Mode == "pause" {
			AssertEqual(0, View.Messages.Length)
			AssertTrue(Entry.Has("pending_range_terminal"))
			AssertEqual(42, Entry["pending_range_terminal"]["request_id"])
			Suspend(false)
			KLWV_FlushPendingRangeTerminals()
			AssertFalse(Entry.Has("pending_range_terminal"))
		}
		ExpectedMessages := Mode == "success" || Mode == "replace" || Mode == "close" ? 0 : 1
		AssertEqual(ExpectedMessages, View.Messages.Length,
			"completion must stay with the exact submitting window")
		if ExpectedMessages {
			Payload := KL_JsonDecode(View.Messages[1])
			AssertEqual("range_terminal", Payload["type"])
			AssertEqual(42, Payload["request_id"])
			AssertEqual("failed", Payload["status"])
		}
		AssertContains(Lines[1], Mode == "success" ? "[DEBUG]" : "[ERROR]")
	} finally FSDelete(Path)
}
Test("WebView range: native rejection releases the current request (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVRO_RangeOutcome.Bind("reject")))
Test("WebView range: synchronous rejection releases the current request (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVRO_RangeOutcome.Bind("sync")))
Test("WebView range: rejected stale entry cannot terminal its replacement (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVRO_RangeOutcome.Bind("replace")))
Test("WebView range: rejected closed window still cleans its stage (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVRO_RangeOutcome.Bind("close")))
Test("WebView range: rejection during pause waits for resume (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVRO_RangeOutcome.Bind("pause")))
Test("WebView range: native success retains the stage for the renderer (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVRO_RangeOutcome.Bind("success")))
