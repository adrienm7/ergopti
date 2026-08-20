; tests/meta/test_webview_host_callback_epoch.ahk
#Requires AutoHotkey v2.0

Test_WebViewHostDeferredCallbacksHaveSessionOwnership() {
	; Move-resilient: selected by content, not by path.
	Src := _DriverDirConcat("infra")
	Assert(InStr(Src, "Epoch      := 0") > 0,
		"WebViewHost must keep an explicit callback-session epoch")
	Assert(InStr(Src, "SetTimer(this._DispatchMessage.Bind(this, this.Epoch, Payload), -1)") > 0,
		"deferred WebMessage callbacks must bind 'this' AND capture the creating host epoch — obj.Method returns an UNBOUND Func whose first parameter is the implicit this, so omitting it shifts every argument and the timer raises 'Missing a required parameter'")
	Assert(InStr(Src, "SetTimer(this._DispatchReady.Bind(this, this.Epoch), -1)") > 0,
		"deferred ready callbacks must bind 'this' AND capture the creating host epoch")
	Assert(InStr(Src, "A_IsSuspended || this.ResetDone || (CallbackEpoch != this.Epoch)") > 0,
		"deferred callbacks must reject suspend, close, and stale-session execution")
	Reset := _DriverFuncBody("_Reset")
	Assert(InStr(Reset, "this.Epoch += 1") > 0,
		"closing/resetting a host must invalidate all queued callbacks")
	Nav := _DriverFuncBody("_OnNavigationCompleted")
	Safety := _DriverFuncBody("_SafetyFlush")
	Assert(InStr(Nav, "A_IsSuspended || this.ResetDone") > 0,
		"navigation completion must not revive a suspended or closed host")
	Assert(InStr(Safety, "A_IsSuspended || this.ResetDone") > 0,
		"the safety timer must not flush a suspended or closed host")
}

Test("webview host: deferred callbacks are session-owned and suspend-gated", Test_WebViewHostDeferredCallbacksHaveSessionOwnership)
