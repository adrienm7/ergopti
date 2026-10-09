; tests/meta/test_webview_script_observer.ahk

; ==============================================================================
; MODULE: WebView Native Observer Coverage
; DESCRIPTION:
; One observed native execution boundary prevents a sibling UI host from dropping
; its Promise. Centralization must never reintroduce synchronous result waiting.
; ==============================================================================

#Requires AutoHotkey v2.0

_WVSO_AllNativeCallsAreObserved() {
	Source := _DriverSourceNoComments()
	Body := _DriverFuncBody("WebView_RunScriptAsync")
	Assert(Source != "", "the complete driver must be available")
	Assert(Body != "", "the native script boundary must exist")
	StrReplace(Source, ".ExecuteScriptAsync(", "", , &NativeCalls)
	AssertEqual(1, NativeCalls, "all hosts must share the one observed native execution site")
	AssertContains(Body, ".ExecuteScriptAsync(")
	AssertContains(Body, ".onSettled(")
	AssertFalse(InStr(Body, ".await"), "native execution must not wait on the keyboard thread")
	AssertFalse(InStr(Body, ".ExecuteScript("), "the convenience method waits synchronously")
	AssertFalse(InStr(Body, "Sleep("), "the observer must not poll for native completion")
}
Test("WebView script: every native execution uses the nonblocking observer (webview-script-outcome)",
	_WVSO_AllNativeCallsAreObserved)
