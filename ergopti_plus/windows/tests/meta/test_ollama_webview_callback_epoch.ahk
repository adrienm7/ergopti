; tests/meta/test_ollama_webview_callback_epoch.ahk
;
; Regression guard for stale Ollama WebView timers. A completed window schedules
; an auto-close after 1.8 s; without immutable ownership it can close a newly
; opened window. The same epoch must fence deferred FlushQueue/RunScript work.

#Requires AutoHotkey v2.0

_OWCE_DeferredCallbacksAreEpochBound() {
	DoneBody := _DriverFuncBody("OllamaWV_Done")
	CloseIfBody := _DriverFuncBody("OllamaWV_CloseIfEpoch")
	CreateBody := _DriverFuncBody("OllamaWV_Create")
	CloseBody := _DriverFuncBody("OllamaWV_Close")
	RunBody := _DriverFuncBody("OllamaWV_RunScript")
	FlushBody := _DriverFuncBody("OllamaWV_FlushQueue")

	Assert(InStr(DoneBody, "OllamaWV_CloseIfEpoch.Bind(captured_epoch)") > 0,
		"OllamaWV_Done must bind its delayed close to the current window epoch, not schedule a bare OllamaWV_Close")
	Assert(InStr(CloseIfBody, "captured_epoch != _OllamaWV_Epoch") > 0,
		"OllamaWV_CloseIfEpoch must reject a timer owned by an older window")
	Assert(InStr(CreateBody, "_OllamaWV_Epoch += 1") > 0 and InStr(CloseBody, "_OllamaWV_Epoch += 1") > 0,
		"creating and closing an Ollama window must invalidate deferred callbacks from its predecessor")
	Assert(InStr(RunBody, "captured_epoch != _OllamaWV_Epoch") > 0,
		"OllamaWV_RunScript must reject stale deferred ExecuteScript work")
	Assert(InStr(FlushBody, "captured_epoch != _OllamaWV_Epoch") > 0,
		"OllamaWV_FlushQueue must reject a stale safety-flush timer")
}
Test("ollama_webview: stale auto-close and deferred scripts cannot mutate a reopened window (ollama-webview-callback-epoch)",
	_OWCE_DeferredCallbacksAreEpochBound)
