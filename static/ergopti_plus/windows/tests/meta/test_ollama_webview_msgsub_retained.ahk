; tests/meta/test_ollama_webview_msgsub_retained.ahk

; ==============================================================================
; MODULE: OllamaWV MsgSub Retention Guard
; DESCRIPTION:
; Regression guard for modules/llm/ollama_webview.ahk discarding the return
; value of WebMessageReceived() — the same GC-unsubscribe bug already fixed
; at 9 sibling WebView2 hosts (see docs/PROJECT_MEMORY.md's
; project_webview2_bridge_gotchas entry, item 3). Currently dormant
; (OllamaWV_Show has zero live callers after the AHK-29 winget refactor,
; confirmed via `grep -rn "OllamaWV_Show(" .`), but OllamaWV_Close retains 2
; live callers and the whole module is actively maintained — the fix costs
; nothing at runtime and protects the code path the moment it is wired to a
; live caller again.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaOllamaWebviewMsgSubRetained() {
	Body := _DriverFuncBody("OllamaWV_Create")
	Assert(Body != "", "OllamaWV_Create must exist in modules/llm/ollama_webview.ahk")

	Assert(InStr(Body, "_OllamaWV_MsgSub := _OllamaWV_WebView.WebMessageReceived(OllamaWV_OnWebMessage)") > 0,
		"OllamaWV_Create must store the WebMessageReceived() subscription handle in the persistent _OllamaWV_MsgSub global, mirroring ui/onboarding/webview.ahk's _OnbWeb_MsgSub fix")

	CloseBody := _DriverFuncBody("OllamaWV_Close")
	Assert(CloseBody != "", "OllamaWV_Close must exist")
	Assert(InStr(CloseBody, "_OllamaWV_MsgSub") > 0,
		"OllamaWV_Close must release _OllamaWV_MsgSub as part of its teardown")
}
Test("ollama_webview: OllamaWV_Create retains its WebMessageReceived subscription handle", _MetaOllamaWebviewMsgSubRetained)
