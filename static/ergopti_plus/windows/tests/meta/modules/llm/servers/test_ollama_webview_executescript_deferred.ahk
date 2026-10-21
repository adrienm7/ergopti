; tests/meta/modules/llm/servers/test_ollama_webview_executescript_deferred.ahk

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
	Assert(InStr(EvalBody, ".ExecuteScript(") = 0,
		"OllamaWV_EvalJS must not call the synchronous ExecuteScript(...) directly -- it is ExecuteScriptAsync().await(), which spins a nested message loop and wedges WebView2 message delivery when called inside the WebMessageReceived callback")
	ScheduleBody := _DriverFuncBody("_OllamaWV_ScheduleDelivery")
	Assert(ScheduleBody != "", "the exact delivery scheduler must exist")
	Assert(InStr(EvalBody, "_OllamaWV_ScheduleDelivery(Owner)") > 0
		and InStr(ScheduleBody, "SetTimer(Timer, -1)") > 0,
		"ready producers must reach the actual deferred timer scheduler")
	Assert(InStr(ScheduleBody, "_OllamaWV_DeliveryCurrent(Owner)") > 0,
		"the timer scheduler must retain exact session authority")
	Assert(InStr(EvalBody, "WebView_RunScriptAsync(") = 0,
		"ready producers cannot bypass their deferred native boundary")

	RunScriptBody := _DriverFuncBody("OllamaWV_RunScript")
	Assert(RunScriptBody != "", "OllamaWV_RunScript must exist in modules/llm/ollama_webview.ahk")
	Assert(InStr(RunScriptBody, "WebView_RunScriptAsync(") > 0,
		"OllamaWV_RunScript must use the observed nonblocking native script boundary")

	FlushBody := _DriverFuncBody("OllamaWV_FlushQueue")
	FlushOwned := _DriverFuncBody("_OllamaWV_FlushOwned")
	Assert(FlushBody != "" and FlushOwned != "", "both readiness entry and owned worker must exist")
	Assert(InStr(FlushBody, "_OllamaWV_FlushOwned(Owner, Pending)") > 0
		and InStr(FlushOwned, "_OllamaWV_ScheduleDelivery(Delivery)") > 0,
		"readiness must publish through the same deferred delivery owner")
	Assert(InStr(FlushBody, "_OllamaWV_WebView.ExecuteScript(") = 0
		and InStr(FlushOwned, ".ExecuteScript(") = 0
		and InStr(FlushOwned, "WebView_RunScriptAsync(") = 0,
		"OllamaWV_FlushQueue must not call the synchronous ExecuteScript(...) directly for the same reentrancy reason as OllamaWV_EvalJS")
}
Test("ollama_webview: ExecuteScript is deferred via SetTimer and runs fire-and-forget, not synchronously inside the WebMessageReceived callback (webview-bridge-sync-executescript)",
	_OWVED_CheckExecuteScriptDeferred)
