; tests/meta/test_ollama_webview_executescript_deferred.ahk

; ==============================================================================
; MODULE: Ollama WebView ExecuteScript Deferral Meta Test (Pattern 4)
; DESCRIPTION:
; Third instance of the same bug already fixed in ui/changelog/init.ahk and
; ui/model_browser/init.ahk: ExecuteScript() (== ExecuteScriptAsync().await())
; was called directly inside the WebMessageReceived callback that triggers
; it, re-entering the STA apartment and wedging further WebView2 message
; delivery after exactly one message.
;
; SCOPE: source introspection of modules/llm/ollama_webview.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ ExecuteScript is deferred off-callback ====
; =====================================================
; =====================================================

_OWVED_CheckExecuteScriptDeferred() {
	EvalBody := _DriverFuncBody("OllamaWV_EvalJS")
	Assert(EvalBody != "", "OllamaWV_EvalJS must exist in modules/llm/ollama_webview.ahk")
	Assert(InStr(EvalBody, "_OllamaWV_WebView.ExecuteScript(") = 0,
		"OllamaWV_EvalJS must not call the synchronous ExecuteScript(...) directly -- it is ExecuteScriptAsync().await(), which spins a nested message loop and wedges WebView2 message delivery when called inside the WebMessageReceived callback")
	Assert(InStr(EvalBody, "SetTimer(") > 0,
		"OllamaWV_EvalJS must defer the script execution via SetTimer(..., -1) so it runs outside the current call stack")

	RunScriptBody := _DriverFuncBody("OllamaWV_RunScript")
	Assert(RunScriptBody != "", "OllamaWV_RunScript must exist in modules/llm/ollama_webview.ahk")
	Assert(InStr(RunScriptBody, "ExecuteScriptAsync(") > 0,
		"OllamaWV_RunScript must use fire-and-forget ExecuteScriptAsync(...), not the awaiting ExecuteScript(...)")

	FlushBody := _DriverFuncBody("OllamaWV_FlushQueue")
	Assert(InStr(FlushBody, "_OllamaWV_WebView.ExecuteScript(") = 0,
		"OllamaWV_FlushQueue must not call the synchronous ExecuteScript(...) directly for the same reentrancy reason as OllamaWV_EvalJS")
}
Test("ollama_webview: ExecuteScript is deferred via SetTimer and runs fire-and-forget, not synchronously inside the WebMessageReceived callback (webview-bridge-sync-executescript)",
	_OWVED_CheckExecuteScriptDeferred)
