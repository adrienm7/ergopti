; tests/meta/test_webview_host_callback_epoch.ahk
#Requires AutoHotkey v2.0

Test_WebViewHostDeferredCallbacksHaveSessionOwnership() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := FileRead(WindowsDir . "\lib\webview_utils.ahk")
	Assert(InStr(Src, "Epoch      := 0") > 0,
		"WebViewHost must keep an explicit callback-session epoch")
	Assert(InStr(Src, "SetTimer(this._DispatchMessage.Bind(this.Epoch, Payload), -1)") > 0,
		"deferred WebMessage callbacks must capture the creating host epoch")
	Assert(InStr(Src, "SetTimer(this._DispatchReady.Bind(this.Epoch), -1)") > 0,
		"deferred ready callbacks must capture the creating host epoch")
	Assert(InStr(Src, "A_IsSuspended || this.ResetDone || (CallbackEpoch != this.Epoch)") > 0,
		"deferred callbacks must reject suspend, close, and stale-session execution")
	Reset := _DriverFuncBody("_Reset")
	Assert(InStr(Reset, "this.Epoch += 1") > 0,
		"closing/resetting a host must invalidate all queued callbacks")
}

Test("webview host: deferred callbacks are session-owned and suspend-gated", Test_WebViewHostDeferredCallbacksHaveSessionOwnership)
