; tests/meta/test_changelog_webview_bridge.ahk

; ==============================================================================
; MODULE: Changelog WebView Bridge Meta Test (Pattern 4)
; DESCRIPTION:
; Three independent bugs found in ui/changelog/init.ahk, all killing the
; JS<->AHK bridge in different ways:
;
; 1. The WebMessageReceived subscription's return value was discarded --
;    AHK's refcounting frees it via __Delete almost immediately, silently
;    unsubscribing the handler.
; 2. Navigation used a file:// URL -- an opaque security origin the
;    chrome.webview JS->AHK channel does not reliably deliver from.
; 3. _CLW_Eval/_CLW_FlushQueue called ExecuteScript() (== ExecuteScriptAsync()
;    .await()) directly inside the WebMessageReceived callback that
;    typically triggers them, re-entering the STA apartment and wedging
;    further message delivery after exactly one message.
;
; SCOPE: source introspection of ui/changelog/init.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Subscription handle is persisted =========
; =====================================================
; =====================================================

_CLWB_CheckSubscriptionPersisted() {
	Body := _DriverFuncBody("_CLW_BuildWindow")
	Assert(Body != "", "_CLW_BuildWindow must exist in ui/changelog/init.ahk")

	CallPos := InStr(Body, "_CLW_WebView.WebMessageReceived(")
	Assert(CallPos > 0, "_CLW_BuildWindow must call _CLW_WebView.WebMessageReceived(...) as a method")

	LineStart := CallPos
	loop {
		if (LineStart <= 1 or SubStr(Body, LineStart, 1) = "`n")
			break
		LineStart--
	}
	Line := Trim(SubStr(Body, LineStart, CallPos - LineStart + 40))
	Assert(InStr(Line, "_CLW_MsgSub :=") > 0,
		"_CLW_BuildWindow must capture the return value of WebMessageReceived(...) into _CLW_MsgSub -- a bare, uncaptured call lets AHK free the subscription almost immediately")
}
Test("changelog: WebMessageReceived subscription handle is captured into _CLW_MsgSub, not discarded (webview-bridge-discarded-subscription)",
	_CLWB_CheckSubscriptionPersisted)




; =====================================================
; =====================================================
; ======= 2/ Navigation uses the vhost, not file:// ====
; =====================================================
; =====================================================

_CLWB_CheckVirtualHostNavigation() {
	HtmlBody := _DriverFuncBody("_CLW_HtmlUrl")
	Assert(HtmlBody != "", "_CLW_HtmlUrl must exist in ui/changelog/init.ahk")
	Assert(InStr(HtmlBody, "file:///") = 0,
		"_CLW_HtmlUrl must not return a file:// URL -- file:// is an opaque security origin the JS->AHK channel does not reliably deliver from")
	Assert(InStr(HtmlBody, "https://") > 0,
		"_CLW_HtmlUrl must return an https:// virtual-host URL")

	BuildBody := _DriverFuncBody("_CLW_BuildWindow")
	Assert(InStr(BuildBody, "SetVirtualHostNameToFolderMapping(") > 0,
		"_CLW_BuildWindow must call SetVirtualHostNameToFolderMapping to map the virtual host before navigating")
}
Test("changelog: navigation uses an https:// virtual host, not an opaque file:// origin (webview-bridge-file-origin)",
	_CLWB_CheckVirtualHostNavigation)




; =====================================================
; =====================================================
; ======= 3/ ExecuteScript is deferred off-callback ====
; =====================================================
; =====================================================

_CLWB_CheckExecuteScriptDeferred() {
	EvalBody := _DriverFuncBody("_CLW_Eval")
	Assert(EvalBody != "", "_CLW_Eval must exist in ui/changelog/init.ahk")
	Assert(InStr(EvalBody, "_CLW_WebView.ExecuteScript(") = 0,
		"_CLW_Eval must not call the synchronous ExecuteScript(...) directly -- it is ExecuteScriptAsync().await(), which spins a nested message loop and wedges WebView2 message delivery when called inside the WebMessageReceived callback")
	Assert(InStr(EvalBody, "SetTimer(") > 0,
		"_CLW_Eval must defer the script execution via SetTimer(..., -1) so it runs outside the current call stack")

	RunScriptBody := _DriverFuncBody("_CLW_RunScript")
	Assert(RunScriptBody != "", "_CLW_RunScript must exist in ui/changelog/init.ahk")
	Assert(InStr(RunScriptBody, "ExecuteScriptAsync(") > 0,
		"_CLW_RunScript must use fire-and-forget ExecuteScriptAsync(...), not the awaiting ExecuteScript(...)")

	FlushBody := _DriverFuncBody("_CLW_FlushQueue")
	Assert(InStr(FlushBody, "_CLW_WebView.ExecuteScript(") = 0,
		"_CLW_FlushQueue must not call the synchronous ExecuteScript(...) directly for the same reentrancy reason as _CLW_Eval")
}
Test("changelog: ExecuteScript is deferred via SetTimer and runs fire-and-forget, not synchronously inside the WebMessageReceived callback (webview-bridge-sync-executescript)",
	_CLWB_CheckExecuteScriptDeferred)
