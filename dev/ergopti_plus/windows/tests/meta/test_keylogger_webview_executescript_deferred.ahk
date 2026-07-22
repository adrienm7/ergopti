; tests/meta/test_keylogger_webview_executescript_deferred.ahk

; ==============================================================================
; MODULE: Keylogger WebView ExecuteScript Deferral Meta Test (F41a)
; DESCRIPTION:
; Same bug already fixed in ui/onboarding/webview.ahk, ui/model_browser/init.ahk,
; ui/changelog/init.ahk and modules/llm/ollama_webview.ahk: the blocking
; ExecuteScript() (== ExecuteScriptAsync().await()) was called directly inside
; the WebMessageReceived callback that triggers it (via KLWV_InjectI18n), spinning
; a nested message loop that re-enters the STA apartment and wedges further
; WebView2 message delivery after exactly one message.
;
; SCOPE: source introspection of modules/keylogger/keylogger_webview.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ ExecuteScript is deferred off-callback ====
; =====================================================
; =====================================================

_KLWVED_CheckExecuteScriptDeferred() {
	Q := Chr(34)   ; ASCII double-quote (the linter bans the backtick-quote escape)
	SyncCallNeedle := "[" . Q . "webview" . Q . "].ExecuteScript("

	InjectBody := _DriverFuncBody("KLWV_InjectI18n")
	Assert(InjectBody != "", "KLWV_InjectI18n must exist in modules/keylogger/keylogger_webview.ahk")
	Assert(InStr(InjectBody, SyncCallNeedle) = 0,
		"KLWV_InjectI18n must not call the synchronous ExecuteScript(...) directly -- it is ExecuteScriptAsync().await(), which spins a nested message loop and wedges WebView2 message delivery when called inside the WebMessageReceived callback")
	Assert(InStr(InjectBody, "SetTimer(") > 0,
		"KLWV_InjectI18n must defer the script execution via SetTimer(..., -1) so it runs outside the current call stack")

	RunScriptBody := _DriverFuncBody("KLWV_RunScript")
	Assert(RunScriptBody != "", "KLWV_RunScript must exist in modules/keylogger/keylogger_webview.ahk")
	Assert(InStr(RunScriptBody, "ExecuteScriptAsync(") > 0,
		"KLWV_RunScript must use fire-and-forget ExecuteScriptAsync(...), not the awaiting ExecuteScript(...)")

	OnMessageBody := _DriverFuncBody("KLWV_OnWebMessage")
	Assert(OnMessageBody != "", "KLWV_OnWebMessage must exist in modules/keylogger/keylogger_webview.ahk")
	Assert(InStr(OnMessageBody, SyncCallNeedle) = 0,
		"KLWV_OnWebMessage must not call the synchronous ExecuteScript(...) directly for the same reentrancy reason as KLWV_InjectI18n")
}
Test("keylogger_webview: ExecuteScript is deferred via SetTimer and runs fire-and-forget, not synchronously inside the WebMessageReceived callback (webview-bridge-sync-executescript, F41a)",
	_KLWVED_CheckExecuteScriptDeferred)
