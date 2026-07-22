; tests/meta/test_model_browser_webview_bridge.ahk

; ==============================================================================
; MODULE: Model Browser WebView Bridge Meta Test (Pattern 4)
; DESCRIPTION:
; Companion to test_changelog_webview_bridge.ahk -- the identical three-bug
; cluster (discarded WebMessageReceived subscription, file:// opaque origin,
; synchronous ExecuteScript inside the WebMessageReceived callback) was
; independently confirmed in ui/model_browser/init.ahk.
;
; SCOPE: source introspection of ui/model_browser/init.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Subscription handle is persisted =========
; =====================================================
; =====================================================

_MBWB_CheckSubscriptionPersisted() {
	Body := _DriverFuncBody("_LLM_ModelBrowser_ShowWeb")
	Assert(Body != "", "_LLM_ModelBrowser_ShowWeb must exist in ui/model_browser/init.ahk")

	CallPos := InStr(Body, "_LLM_MBW_WebView.WebMessageReceived(")
	Assert(CallPos > 0, "_LLM_ModelBrowser_ShowWeb must call _LLM_MBW_WebView.WebMessageReceived(...) as a method")

	LineStart := CallPos
	loop {
		if (LineStart <= 1 or SubStr(Body, LineStart, 1) = "`n")
			break
		LineStart--
	}
	Line := Trim(SubStr(Body, LineStart, CallPos - LineStart + 40))
	Assert(InStr(Line, "_LLM_MBW_MsgSub :=") > 0,
		"_LLM_ModelBrowser_ShowWeb must capture the return value of WebMessageReceived(...) into _LLM_MBW_MsgSub -- a bare, uncaptured call lets AHK free the subscription almost immediately")
}
Test("model_browser: WebMessageReceived subscription handle is captured into _LLM_MBW_MsgSub, not discarded (webview-bridge-discarded-subscription)",
	_MBWB_CheckSubscriptionPersisted)




; =====================================================
; =====================================================
; ======= 2/ Navigation uses the vhost, not file:// ====
; =====================================================
; =====================================================

_MBWB_CheckVirtualHostNavigation() {
	HtmlBody := _DriverFuncBody("_LLM_MBW_HtmlUrl")
	Assert(HtmlBody != "", "_LLM_MBW_HtmlUrl must exist in ui/model_browser/init.ahk")
	Assert(InStr(HtmlBody, "file:///") = 0,
		"_LLM_MBW_HtmlUrl must not return a file:// URL -- file:// is an opaque security origin the JS->AHK channel does not reliably deliver from")
	Assert(InStr(HtmlBody, "https://") > 0,
		"_LLM_MBW_HtmlUrl must return an https:// virtual-host URL")

	ShowBody := _DriverFuncBody("_LLM_ModelBrowser_ShowWeb")
	Assert(InStr(ShowBody, "SetVirtualHostNameToFolderMapping(") > 0,
		"_LLM_ModelBrowser_ShowWeb must call SetVirtualHostNameToFolderMapping to map the virtual host before navigating")
}
Test("model_browser: navigation uses an https:// virtual host, not an opaque file:// origin (webview-bridge-file-origin)",
	_MBWB_CheckVirtualHostNavigation)




; =====================================================
; =====================================================
; ======= 3/ ExecuteScript is deferred off-callback ====
; =====================================================
; =====================================================

_MBWB_CheckExecuteScriptDeferred() {
	EvalBody := _DriverFuncBody("_LLM_MBW_Eval")
	Assert(EvalBody != "", "_LLM_MBW_Eval must exist in ui/model_browser/init.ahk")
	Assert(InStr(EvalBody, "_LLM_MBW_WebView.ExecuteScript(") = 0,
		"_LLM_MBW_Eval must not call the synchronous ExecuteScript(...) directly -- it is ExecuteScriptAsync().await(), which spins a nested message loop and wedges WebView2 message delivery when called inside the WebMessageReceived callback")
	Assert(InStr(EvalBody, "SetTimer(") > 0,
		"_LLM_MBW_Eval must defer the script execution via SetTimer(..., -1) so it runs outside the current call stack")

	RunScriptBody := _DriverFuncBody("_LLM_MBW_RunScript")
	Assert(RunScriptBody != "", "_LLM_MBW_RunScript must exist in ui/model_browser/init.ahk")
	Assert(InStr(RunScriptBody, "ExecuteScriptAsync(") > 0,
		"_LLM_MBW_RunScript must use fire-and-forget ExecuteScriptAsync(...), not the awaiting ExecuteScript(...)")

	FlushBody := _DriverFuncBody("_LLM_MBW_FlushQueue")
	Assert(InStr(FlushBody, "_LLM_MBW_WebView.ExecuteScript(") = 0,
		"_LLM_MBW_FlushQueue must not call the synchronous ExecuteScript(...) directly for the same reentrancy reason as _LLM_MBW_Eval")
}
Test("model_browser: ExecuteScript is deferred via SetTimer and runs fire-and-forget, not synchronously inside the WebMessageReceived callback (webview-bridge-sync-executescript)",
	_MBWB_CheckExecuteScriptDeferred)
