; tests/meta/ui/webview/test_webview_deferred_host_actions.ahk

; ==============================================================================
; MODULE: WebView Host Deferred Actions
; DESCRIPTION:
; WebView2 hosts never tear down or mutate from inside the COM message
; callback: teardown is deferred out of the callback, a deferred action is
; bound to the singleton session that queued it, and it rechecks Suspend at
; effect time. Written as class loops over every host.
; ==============================================================================

#Requires AutoHotkey v2.0

; _PromptEdWeb_EditId and saving overwrote the WRONG profile.
; F-27/ Teardown ran synchronously on the WebMessageReceived stack: the
; F-28  subscription currently dispatching was released, then the controller
; closed and the Gui destroyed. Uncatchable SEH class; must be deferred
; Class loop: no message handler may tear its own host down synchronously.
_A0720WV_TeardownIsDeferredOutOfTheCallback() {
	Cases := Map(
		"_LLM_MBW_OnWebMessage", ["_LLM_MBW_OnClose(", "_LLM_MBW_Reset("],
		"_HsEdWeb_OnWebMessage", ["_HsEdWeb_Close(", "_HsEdWeb_Save("],
		"_OnbWeb_OnWebMessage", ["_OnbWeb_Finish(", "_Onboarding_Commit(", "_OnbWeb_Reset("]
	)
	for Fn, Forbidden in Cases {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must exist")
		for _, Call in Forbidden {
			Assert(InStr(Body, Call) = 0,
				Fn . " must not call " . Call . " directly — it runs on the WebMessageReceived stack, where releasing the subscription currently dispatching and then closing the controller / destroying the Gui is an uncatchable access-violation class. Hand off with SetTimer(-1), as ui/onboarding/webview.ahk documents")
		}
		Assert(InStr(Body, "SetTimer(") > 0,
			Fn . " must defer its side-effecting work out of the COM callback with SetTimer(-1)")
	}
}
Test("webview: hosts never tear down from inside the COM callback (F-27, F-28, AHK-055)",
	_A0720WV_TeardownIsDeferredOutOfTheCallback)


; Every deferred callback must carry the session that scheduled it. Otherwise a
; one-shot timer from a closed session can resolve the replacement host's mutable
; globals and close it, inject JS into it, or persist the old payload through it.
_A0720WV_DeferredActionsOwnTheirSession() {
	Cases := Map(
		"ActPickWeb", ["_ActPickWeb_TryOpen", "_ActPickWeb_OnWebMessage", "_ActPickWeb_Reset"],
		"OnbWeb", ["_Onboarding_TryWeb", "_OnbWeb_OnWebMessage", "_OnbWeb_Reset"],
		"HsEdWeb", ["_HsEdWeb_TryOpen", "_HsEdWeb_OnWebMessage", "_HsEdWeb_Reset"],
		"PiEdWeb", ["_PiEdWeb_TryOpen", "_PiEdWeb_OnWebMessage", "_PiEdWeb_Reset"],
		"PathsEdWeb", ["_PathsEdWeb_TryOpen", "_PathsEdWeb_OnWebMessage", "_PathsEdWeb_Reset"],
		"HCWWeb", ["_HCWWeb_TryOpen", "_HCWWeb_OnWebMessage", "_HCWWeb_Reset"]
	)
	for Prefix, Fns in Cases {
		TryOpenBody := _DriverFuncBody(Fns[1])
		HandlerBody := _DriverFuncBody(Fns[2])
		ResetBody := _DriverFuncBody(Fns[3])
		SessionCallBody := _DriverFuncBody("_" . Prefix . "_SessionCall")
		Assert(InStr(TryOpenBody, ".Bind(SessionEpoch)") > 0,
			Prefix . " must allocate and bind a session epoch when opening")
		Assert(InStr(HandlerBody, "SessionCall.Bind(SessionEpoch") > 0,
			Prefix . " must reject messages and defer work with the captured session epoch")
		Assert(InStr(ResetBody, "SessionEpoch += 1") > 0,
			Prefix . " reset must revoke every callback queued by the closing session")
		Assert(InStr(SessionCallBody, "SessionCurrent(SessionEpoch)") > 0
			&& InStr(SessionCallBody, "Callback(Params*)") > 0,
			Prefix . " must validate ownership immediately before invoking the deferred effect")
	}
}
Test("webview: deferred actions cannot cross singleton sessions (AHK-054)",
	_A0720WV_DeferredActionsOwnTheirSession)


_A0720WV_DeferredMutationsRecheckSuspend() {
	Effects := [
		"_ActPickWeb_Confirm",
		"_OnbWeb_Finish",
		"_OnbWeb_RegisterGesturesAuto",
		"_OnbWeb_RegisterGesturesManual",
		"_HsEdWeb_SavePref",
		"_PathsEdWeb_Browse",
		"_PathsEdWeb_Save",
		"_PromptEdWeb_Save",
		"_PromptEdWeb_ApplyProfileForContext",
		"_LLM_MBW_ApplyModel",
		"_HCWWeb_Dispatch"
	]
	for _, Fn in Effects {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must exist")
		Assert(InStr(Body, "A_IsSuspended") > 0,
			Fn . " must revalidate Suspend on the deferred effect stack, not only before its timer was scheduled")
	}
}
Test("webview: deferred mutations recheck Suspend at effect time (AHK-061)",
	_A0720WV_DeferredMutationsRecheckSuspend)
