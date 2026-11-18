; tests/unit/core/ui/webview/test_host_pause.ahk

; ==============================================================================
; MODULE: WebView Host Deferred Callbacks Under Pause
; DESCRIPTION:
; WebViewHost defers each WebMessage and ready callback to a one-shot timer, and
; timers keep firing under native Suspend. Each deferred callback is bound to
; its host and to the callback session (epoch) that created it, and refuses a
; paused, closed or stale session. Navigation still records readiness while
; paused but never flushes the user's queued scripts; the safety timer never
; flushes a paused host; a ready callback refused under pause leaves a receipt
; that only the resume may arm. Every case drives a host built without a
; window or a browser control, so no script reaches a page.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Fixture helpers =======
; ==================================
; ==================================

_WHP_Message(Text) {
	return {TryGetWebMessageAsString: (*) => Text}
}

_WHP_Await(Calls, Count, TimeoutMs := 2000) {
	Started := A_TickCount
	while Calls.Length < Count && A_TickCount - Started < TimeoutMs
		Sleep(10)
	return Calls.Length
}

; Lets every one-shot timer already armed run, paused or not.
_WHP_Drain() {
	Sleep(60)
}





; ================================================
; ================================================
; ======= 2/ Deferred WebMessage callbacks =======
; ================================================
; ================================================

_WHP_PausedMessagesDispatchNothing() {
	Calls := []
	Host := WebViewHost()
	Host.Opts := Map("OnMessage", (H, Payload) => Calls.Push({Host: H, Payload: Payload}))
	WasSuspended := A_IsSuspended
	try {
		Suspend(true)
		Host._OnWebMessage(0, _WHP_Message('{"action":"paused"}'))
		Host._DispatchMessage(Host.Epoch, Map("action", "direct"))
		_WHP_Drain()
		AssertEqual(0, Calls.Length, "a paused host must neither defer nor dispatch a WebMessage")

		Suspend(false)
		Host._OnWebMessage(0, _WHP_Message('{"action":"running"}'))
		AssertEqual(1, _WHP_Await(Calls, 1), "positive control: a running host dispatches its deferred WebMessage")
		AssertTrue(Calls[1].Host == Host && Calls[1].Payload["action"] == "running",
			"the deferred callback must be bound to its own host and carry its payload")

		; A message admitted while running and delivered after the pause began.
		Host._OnWebMessage(0, _WHP_Message('{"action":"overtaken"}'))
		Suspend(true)
		_WHP_Drain()
		Suspend(false)
		_WHP_Drain()
		AssertEqual(1, Calls.Length, "a deferred WebMessage delivered while paused must be dropped")

		Host._DispatchMessage(Host.Epoch - 1, Map("action", "stale"))
		AssertEqual(1, Calls.Length, "a callback from an older session must stay inert")
		Epoch := Host.Epoch
		Host._OnWebMessage(0, _WHP_Message('{"action":"closing"}'))
		Host._Reset()
		AssertEqual(Epoch + 1, Host.Epoch, "a reset must open a new callback session")
		_WHP_Drain()
		AssertEqual(1, Calls.Length, "a reset must invalidate every queued WebMessage callback")
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		Host._Reset()
	}
}
Test("WebView host: paused and stale WebMessages dispatch nothing (webview-host-callback-epoch)",
	_WHP_PausedMessagesDispatchNothing)





; ==============================================================
; ==============================================================
; ======= 3/ Navigation and the safety flush under pause =======
; ==============================================================
; ==============================================================

_WHP_PausedNavigationKeepsUserQueue() {
	Host := WebViewHost()
	Host.Opts := Map("OnMessage", (*) => 0)
	Host.Queue := ["privateFixture();"]
	WasSuspended := A_IsSuspended
	try {
		Suspend(true)
		Host._OnWebMessage(0, _WHP_Message("ready"))
		AssertFalse(Host.Ready || Host.ReadyFired, "a paused host must not take the page's ready message")
		AssertEqual(1, Host.Queue.Length, "a paused ready message must not flush the user's queued scripts")
		Host._SafetyFlush()
		AssertFalse(Host.Ready, "the safety timer must not flush a paused host")
		AssertEqual(1, Host.Queue.Length, "the safety timer must keep a paused host's queue")
		Host._OnNavigationCompleted(0, 0)
		AssertTrue(Host.ReadyFired, "a navigation under pause must still record the page's readiness")
		AssertFalse(Host.Ready, "a navigation under pause must not open the script queue")
		AssertEqual(1, Host.Queue.Length, "a navigation under pause must not flush the user's queued scripts")
		Host.Eval("pausedFixture();")
		AssertEqual(1, Host.Queue.Length, "a paused host must not queue a new script")

		Suspend(false)
		Host._SafetyFlush()
		AssertTrue(Host.Ready, "positive control: the safety timer flushes a running host")
		AssertEqual(0, Host.Queue.Length)
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		Host._Reset()
	}
}
Test("WebView host: a paused navigation and safety flush keep the user queue (webview-host-callback-epoch)",
	_WHP_PausedNavigationKeepsUserQueue)





; ===========================================================
; ===========================================================
; ======= 4/ A ready refused under pause resumes once =======
; ===========================================================
; ===========================================================

_WHP_PausedReadyResumesOnce() {
	Calls := []
	Host := WebViewHost()
	Host.Opts := Map("OnMessage", (*) => 0, "OnReady", (H) => Calls.Push(H))
	WasSuspended := A_IsSuspended
	try {
		Suspend(true)
		Host._OnNavigationCompleted(0, 0)
		_WHP_Drain()
		AssertEqual(0, Calls.Length, "a paused host must not run its ready callback")
		AssertFalse(Host.Ready, "a paused ready must not open the script queue")
		AssertTrue(WebViewHost._PendingReady.Has(Host), "a ready refused under pause must leave a resume receipt")
		WebViewHost.ResumeReady()
		_WHP_Drain()
		AssertEqual(0, Calls.Length, "the receipt must not be armed while the pause lasts")
		AssertFalse(WebViewHost_OnSuspendResume(), "the resume owner refuses while the pause lasts")

		Suspend(false)
		AssertTrue(WebViewHost_OnSuspendResume())
		AssertEqual(1, _WHP_Await(Calls, 1), "the resume must run the refused ready callback")
		AssertTrue(Calls[1] == Host, "the ready callback must be bound to its own host")
		AssertTrue(Host.Ready, "the resumed ready opens the script queue")
		AssertFalse(WebViewHost._PendingReady.Has(Host), "the resumed ready consumes its receipt")
		WebViewHost.ResumeReady()
		_WHP_Drain()
		AssertEqual(1, Calls.Length, "a consumed receipt cannot run the ready callback twice")
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		Host._Reset()
	}
}
Test("WebView host: a ready refused under pause runs once on resume (webview-host-callback-epoch)",
	_WHP_PausedReadyResumesOnce)
