; tests/meta/ui/webview/test_webview_host_callback_epoch.ahk
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
	Nav := _StripFullLineComments(_DriverFuncBody("_OnNavigationCompleted"))
	Safety := _StripFullLineComments(_DriverFuncBody("_SafetyFlush"))
	Dispatch := _StripFullLineComments(_DriverFuncBody("_DispatchReady"))
	Assert(Nav != "" && Dispatch != "" && Safety != "", "navigation, ready, and safety owners must exist")
	Assert(_WVH_NavigationRecoveryContract(Nav, Dispatch, Safety),
		"navigation must retain readiness under pause without flushing commands; resumed init must open only the live host")
	Assert(!_WVH_NavigationRecoveryContract(StrReplace(Nav, "if this.ResetDone", "if A_IsSuspended || this.ResetDone"), Dispatch, Safety),
		"the navigation contract must reject dropping the paused readiness signal")
	Assert(!_WVH_NavigationRecoveryContract(StrReplace(Nav, "if !A_IsSuspended", "if true"), Dispatch, Safety),
		"the navigation contract must reject flushing user commands under pause")
	Assert(!_WVH_NavigationRecoveryContract(StrReplace(Nav, "this._FireOnReady()", ""), Dispatch, Safety),
		"the navigation contract must require the ready admission")
	Assert(!_WVH_NavigationRecoveryContract(Nav, StrReplace(Dispatch, "this.Ready := true", ""), Safety),
		"the navigation contract must require resumed initialization to become ready")
	Assert(!_WVH_NavigationRecoveryContract(Nav, "this.Ready := true`n" . Dispatch, Safety),
		"the navigation contract must reject readiness publication before the pause refusal")
	Assert(!_WVH_NavigationRecoveryContract(Nav, Dispatch . "`nthis._FlushQueue()", Safety),
		"resumed readiness must not replay the user command queue")
	Assert(!_WVH_NavigationRecoveryContract(Nav, Dispatch, Safety . "`nthis._FireOnReady()"),
		"the safety timeout must never create readiness authority")
	Assert(InStr(Safety, "A_IsSuspended || this.ResetDone") > 0,
		"the safety timer must not flush a suspended or closed host")
}

; This bounded source contract distinguishes navigation authority from a timeout
; and preserves the worker's pause refusal before its RAM readiness publication.
_WVH_NavigationRecoveryContract(Nav, Dispatch, Safety) {
	Pause := InStr(Dispatch, "if A_IsSuspended {")
	Publish := InStr(Dispatch, "this.Ready := true")
	Call := InStr(Dispatch, "Callback.Call(this)")
	return RegExMatch(Nav, "if this\.ResetDone \|\| this\.CloseRequested\s+return")
		&& RegExMatch(Nav, "if !A_IsSuspended\s+this\._FlushQueue\(\)\s+this\._FireOnReady\(\)")
		&& !InStr(Nav, "if A_IsSuspended ||")
		&& Pause > 0 && Publish > Pause && Call > Publish
		&& RegExMatch(Dispatch, "s)if A_IsSuspended \{.*?return\s+\}.*?this\.Ready := true")
		&& !InStr(Dispatch, "this._FlushQueue()")
		&& InStr(Safety, "A_IsSuspended || this.ResetDone") > 0
		&& !InStr(Safety, "this._FireOnReady()")
		&& !InStr(Safety, "this._ScheduleReady()")
}

Test("webview host: deferred callbacks are session-owned and suspend-gated", Test_WebViewHostDeferredCallbacksHaveSessionOwnership)
