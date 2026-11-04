; tests/unit/ui/webview/test_webview_script_outcomes.ahk

; ==============================================================================
; MODULE: WebView Native Script Outcome Tests
; DESCRIPTION:
; Real vendored promises expose delayed native failures that synchronous mocks
; hide. No WebView window is created and no application JavaScript is executed.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../support/webview_script_fixture.ahk
_WVSO_LocaleOutcome(Reject, View, Lines, Unhandled, Failure) {
	KLWV.windows := Map("apps", Map("epoch", 51, "webview", View))
	KLWV_RunScript("apps", "PRIVATE-SCRIPT-CANARY", Reject ? "en" : "fr", 51)
	Before := Lines.Length
	if Reject
		View.Reject.Call(Failure)
	else
		View.Resolve.Call("null")
	_WVSO_Drain(View)
	AssertEqual(1, View.Scripts.Length)
	AssertEqual(0, Unhandled.Length, "a rejected native Promise must not escape on a timer")
	AssertEqual(0, Before, "submitting a native call is not its successful completion")
	AssertEqual(1, Lines.Length, "one native outcome must produce one local diagnostic")
	AssertContains(Lines[1], Reject ? "[ERROR]" : "[DEBUG]")
	AssertContains(Lines[1], "Keystats.locale")
	AssertFalse(InStr(Lines[1], "PRIVATE-SCRIPT"), "neither script nor rejected payload may enter logs")
}
Test("WebView script: locale native success is observed only after completion (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVSO_LocaleOutcome.Bind(false)))
Test("WebView script: locale native rejection is contained and redacted (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVSO_LocaleOutcome.Bind(true)))

_WVSO_Callback(Calls, Failure, ShouldThrow, Succeeded) {
	Calls.Push(Succeeded)
	if ShouldThrow
		throw Failure
}

_WVSO_DirectOutcome(Mode, View, Lines, Unhandled, Failure) {
	Calls := []
	if Mode == "sync"
		View.Failure := Failure
	Accepted := WebView_RunScriptAsync(View, "PRIVATE-SCRIPT-CANARY", "Test." . Mode,
		_WVSO_Callback.Bind(Calls, Failure, Mode == "callback"))
	AssertEqual(Mode != "sync", Accepted)
	if Mode != "sync" {
		AssertEqual(0, Calls.Length)
		AssertEqual(0, Lines.Length)
		if Mode == "reject"
			View.Reject.Call(Failure)
		else
			View.Resolve.Call("PRIVATE-SCRIPT-RESULT-CANARY")
		_WVSO_Drain(View)
	}
	AssertEqual(0, Unhandled.Length)
	AssertEqual(1, Calls.Length, "the consumer receives exactly one outcome")
	AssertEqual(Mode != "sync" && Mode != "reject", Calls[1])
	AssertEqual(Mode == "callback" ? 2 : 1, Lines.Length)
	AssertContains(Lines[-1], Mode == "resolve" ? "[DEBUG]" : "[ERROR]")
	if Mode == "callback"
		AssertContains(Lines[-1], "phase=callback")
	for Line in Lines
		AssertFalse(InStr(Line, "PRIVATE-SCRIPT"), "outcome diagnostics must be payload-free")
}
Test("WebView script: native resolution invokes its consumer (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVSO_DirectOutcome.Bind("resolve")))
Test("WebView script: native rejection invokes its consumer (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVSO_DirectOutcome.Bind("reject")))
Test("WebView script: synchronous refusal reports failure (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVSO_DirectOutcome.Bind("sync")))
Test("WebView script: throwing consumer is observed locally (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVSO_DirectOutcome.Bind("callback")))

_WVSO_InvalidCallback(View, Lines, Unhandled, Failure) {
	for Invalid in [1, "0", 0.0, Map()] {
		Refused := false
		try WebView_RunScriptAsync(View, "void 0", "Test.invalid", Invalid)
		catch TypeError
			Refused := true
		AssertTrue(Refused)
	}
	AssertEqual(0, View.Scripts.Length, "invalid observers must fail before native submission")
	AssertEqual(0, Lines.Length)
}
Test("WebView script: invalid consumer fails before submission (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVSO_InvalidCallback))

_WVSO_AlreadySettled(View, Lines, Unhandled, Failure) {
	View.Resolve.Call("null")
	_WVSO_Drain(View)
	Calls := []
	AssertTrue(WebView_RunScriptAsync(View, "void 0", "Test.already-settled",
		(Succeeded) => Calls.Push(Succeeded)))
	; The original task is gone: onCompleted now schedules a separate next-tick callback.
	Started := A_TickCount
	while Calls.Length == 0 && A_TickCount - Started < 2000
		Sleep(1)
	AssertEqual(1, Calls.Length)
	AssertTrue(Calls[1])
	AssertEqual(1, Lines.Length)
	AssertContains(Lines[1], "[DEBUG]")
	AssertEqual(0, Unhandled.Length)
}
Test("WebView script: an already-settled Promise still notifies its observer (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVSO_AlreadySettled))

_WVSO_NativeCode(View, Lines, Unhandled, Failure) {
	NativeError := OSError(5)
	NativeError.Message := "PRIVATE-SCRIPT-NATIVE-CANARY"
	AssertTrue(WebView_RunScriptAsync(View, "PRIVATE-SCRIPT-CANARY", "Test.native-code"))
	View.Reject.Call(NativeError)
	_WVSO_Drain(View)
	AssertEqual(1, Lines.Length)
	AssertContains(Lines[1], "[ERROR]")
	AssertContains(Lines[1], "error_type=OSError")
	AssertContains(Lines[1], "code=5")
	AssertFalse(InStr(Lines[1], "PRIVATE-SCRIPT"))
	AssertEqual(0, Unhandled.Length)
}
Test("WebView script: native error codes survive without their sensitive messages (webview-script-outcome)",
	_WVSO_WithFixture.Bind(_WVSO_NativeCode))


class _WVSO_PausedHost extends WebViewHost {
	Deliveries := 0
	_RunScript(Js) {
		try super._RunScript(Js)
		finally this.Deliveries += 1
	}
}

_WVSO_HostPause(FromQueue, View, Lines, Unhandled, Failure) {
	Host := _WVSO_PausedHost()
	Host.AppId := "private-pause-fixture"
	Host.WebView := View
	Host.Ready := !FromQueue
	try {
		; Admit the real timer before pause, then allow that timer to run only
		; after suspension. Both producers share the native submission boundary.
		PreviousCritical := Critical("On")
		try {
			Host.Eval("privatePausedCommand();")
			if FromQueue
				Host._FlushQueue()
			Suspend(true)
		} finally Critical(PreviousCritical)
		Started := A_TickCount
		while Host.Deliveries == 0 && A_TickCount - Started < 2000
			Sleep(1)
		AssertEqual(1, Host.Deliveries, "the admitted script timer must actually execute under pause")
		AssertEqual(0, View.Scripts.Length, "a paused host must not submit queued browser work")
		AssertEqual(0, Host.Queue.Length, "refused work cannot replay after resume")
		Suspend(false)
		Host.Eval("privateCurrentCommand();")
		Started := A_TickCount
		while Host.Deliveries < 2 && A_TickCount - Started < 2000
			Sleep(1)
		AssertEqual(2, Host.Deliveries)
		AssertEqual(1, View.Scripts.Length, "resume admits only a fresh script")
		AssertEqual("privateCurrentCommand();", View.Scripts[1])
	} finally {
		Host.Close()
		Suspend(false)
	}
}
Test("WebView script: pause fences a ready host's native timer (webview-script-pause)",
	_WVSO_WithFixture.Bind(_WVSO_HostPause.Bind(false)))
Test("WebView script: pause fences timers released by readiness (webview-script-pause)",
	_WVSO_WithFixture.Bind(_WVSO_HostPause.Bind(true)))


_WVSO_HostPauseAdmission(View, Lines, Unhandled, Failure) {
	Host := WebViewHost()
	Host.WebView := View
	try {
		Suspend(true)
		Host.Eval("privatePausedAdmission();")
		AssertEqual(0, Host.Queue.Length, "scripts requested under pause cannot be retained for later delivery")
		AssertEqual(0, View.Scripts.Length)
	} finally {
		Host.Close()
		Suspend(false)
	}
}
Test("WebView script: paused admission cannot retain work for resume (webview-script-pause)",
	_WVSO_WithFixture.Bind(_WVSO_HostPauseAdmission))
