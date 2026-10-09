; tests/unit/test_ui_warm_hosts.ahk

; ==============================================================================
; MODULE: Warm UI Host Ownership Tests
; DESCRIPTION:
; Retention must revoke all active sessions, preserve hidden native HWNDs and
; release cached controllers on invalidation or shutdown. Fresh documents are
; fenced separately from AHK epochs because native queues survive host reuse.
; ==============================================================================

#Requires AutoHotkey v2.0

class _UIWH_Controller {
	IsVisible := true
	Closed := 0
	Close() {
		this.Closed += 1
	}
}

_UIWH_MetricsRetention() {
	SavedWindows := KLWV.windows
	SavedWarm := KLWV.warm_hosts
	SavedOpening := KLWV.opening
	SavedCloseRequest := KLWV.close_during_open
	G := Gui()
	G.Show("Hide w220 h140")
	C := _UIWH_Controller()
	Entry := Map("gui", G, "controller", C, "webview", {}, "udir", "",
		"reuse_key", "fixture", "epoch", 51, "msg_sub", 0, "nav_sub", 0,
		"metrics_dir", "private", "first_paint_done", true)
	KLWV.windows := Map("typing", Entry)
	KLWV.warm_hosts := Map()
	KLWV.opening := Map()
	KLWV.close_during_open := Map()
	try {
		AssertEqual(1, KLWV_Hide("typing", {}), "an old GUI callback is refused")
		AssertTrue(KLWV_IsCurrent("typing", 51))
		AssertEqual(1, KLWV_Hide("typing", G))
		AssertFalse(KLWV_IsCurrent("typing", 51), "the hidden session has no live lookup")
		AssertFalse(DllCall("IsWindowVisible", "Ptr", G.Hwnd), "retained host stays invisible")
		AssertFalse(C.IsVisible)
		AssertEqual(0, C.Closed, "manual closure must not destroy Chromium")
		AssertFalse(Entry.Has("msg_sub") || Entry.Has("nav_sub"), "native handlers retire first")
		AssertEqual(5, KLWV.warm_hosts["typing"].Count, "data and worker state cannot enter the native cache")
		for Key in ["gui", "controller", "webview", "udir", "reuse_key"]
			AssertTrue(KLWV.warm_hosts["typing"].Has(Key), "retained native owner: " . Key)
		Cached := KLWV_TakeWarmHost("typing", "fixture")
		AssertTrue(Cached["controller"] == C)
		AssertEqual(0, KLWV.warm_hosts.Count, "reuse transfers ownership exactly once")
		KLWV.warm_hosts["typing"] := Cached
		AssertEqual(0, KLWV_TakeWarmHost("typing", "different-locale-or-store"))
		AssertEqual(1, C.Closed, "changed configuration disposes the old host")
		AssertEqual(0, KLWV.warm_hosts.Count)
		KLWV_CloseAll()
		AssertEqual(1, C.Closed, "shutdown cannot double-close an invalidated host")
	} finally {
		KLWV_CloseAll()
		try G.Destroy()
		KLWV.windows := SavedWindows
		KLWV.warm_hosts := SavedWarm
		KLWV.opening := SavedOpening
		KLWV.close_during_open := SavedCloseRequest
	}
}
Test("metrics: retained host revokes its session and invalidates exactly once (ui-warm-reopen)",
	_UIWH_MetricsRetention)

_UIWH_DiagnosticsRetention() {
	global _HC_Gui, _HC_Controller, _HC_WebView, _HC_MsgSub, _HC_Session
	global _HC_WindowEpoch, _HC_ResetDone, _HC_ReuseKey, _HC_ProbeRun
	global _HC_Opening, _HC_CloseDuringOpen
	global _HC_RequestSerial, _HC_PendingSerial, _HC_PendingMode
	SavedSerial := _HC_RequestSerial
	SavedPendingSerial := _HC_PendingSerial
	HadPending := IsSet(_HC_PendingMode)
	SavedPending := HadPending ? _HC_PendingMode : ""
	Saved := Map("gui", IsSet(_HC_Gui) ? _HC_Gui : 0,
		"controller", IsSet(_HC_Controller) ? _HC_Controller : 0,
		"webview", IsSet(_HC_WebView) ? _HC_WebView : 0,
		"msg_sub", IsSet(_HC_MsgSub) ? _HC_MsgSub : 0,
		"session", _HC_Session, "epoch", _HC_WindowEpoch, "reset", _HC_ResetDone,
		"key", _HC_ReuseKey, "probes", _HC_ProbeRun,
		"opening", _HC_Opening, "close_request", _HC_CloseDuringOpen)
	G := Gui()
	G.Show("Hide w220 h140")
	C := _UIWH_Controller()
	Run := {Cancelled: false, Requests: []}
	_HC_Gui := G, _HC_Controller := C, _HC_WebView := {}, _HC_MsgSub := {}
	_HC_Session := Map("epoch", 51), _HC_WindowEpoch := 51
	_HC_ResetDone := false, _HC_ReuseKey := "fixture", _HC_ProbeRun := Run
	try {
		_HealthCheck_CloseGui({})
		AssertEqual(51, _HC_WindowEpoch, "a stale GUI cannot retire the live singleton")
		_HC_Opening := true
		_HC_CloseDuringOpen := false
		_HC_PendingMode := "report"
		_HC_PendingSerial := _HC_RequestSerial
		QueuedSerial := _HC_RequestSerial
		AssertEqual(1, _HealthCheck_CloseGui(G))
		AssertTrue(_HC_CloseDuringOpen, "closing during native creation retains the user's intent")
		AssertFalse(IsSet(_HC_PendingMode), "a user close cancels an earlier queued open")
		_HC_ResumePending("report", QueuedSerial)
		AssertFalse(IsSet(_HC_PendingMode), "an already scheduled stale open cannot reopen the window")
		_HC_Opening := false
		AssertTrue(_HC_WindowEpoch > 51)
		AssertEqual(0, _HC_Session)
		AssertTrue(Run.Cancelled)
		AssertFalse(IsSet(_HC_MsgSub))
		AssertEqual(0, C.Closed)
		AssertFalse(DllCall("IsWindowVisible", "Ptr", G.Hwnd))
		AssertFalse(C.IsVisible)
		AssertTrue(_HC_CanReuse("fixture"))
		AssertFalse(_HC_CanReuse("different-locale"))
		_HC_HandleMessage(51, "ready")
		_HC_PublishProbe(51, "old", Map(), Map())
		AssertEqual(0, _HC_Session, "retired messages and probe answers stay inert")
		_HC_Close()
		_HC_Close()
		AssertEqual(1, C.Closed)
		AssertFalse(IsSet(_HC_Gui))
		AssertEqual("", _HC_ReuseKey)
	} finally {
		_HC_Close()
		_HC_Gui := Saved["gui"] ? Saved["gui"] : unset
		_HC_Controller := Saved["controller"] ? Saved["controller"] : unset
		_HC_WebView := Saved["webview"] ? Saved["webview"] : unset
		_HC_MsgSub := Saved["msg_sub"] ? Saved["msg_sub"] : unset
		_HC_Session := Saved["session"], _HC_WindowEpoch := Saved["epoch"]
		_HC_ResetDone := Saved["reset"], _HC_ReuseKey := Saved["key"], _HC_ProbeRun := Saved["probes"]
		_HC_Opening := Saved["opening"], _HC_CloseDuringOpen := Saved["close_request"]
		_HC_RequestSerial := SavedSerial, _HC_PendingSerial := SavedPendingSerial
		_HC_PendingMode := HadPending ? SavedPending : unset
	}
}
Test("diagnostics: retained singleton cancels probes and releases on shutdown (ui-warm-reopen)",
	_UIWH_DiagnosticsRetention)

_UIWH_DocumentFence() {
	Entry := Map("epoch", 73, "navigation_url", "https://private.test/?epoch=73")
	Payload := JsonParse(KLWV_PageMessage(Entry, '{"type":"range_terminal","request_id":9}'))
	AssertEqual(73, Payload["host_epoch"])
	AssertEqual(9, Payload["request_id"])
	Script := KLWV_PageScript(Entry, "window.received=true;")
	AssertContains(Script, "location.href===")
	AssertContains(Script, "?epoch=73")
	AssertContains(Script, "window.received=true;")
}
Test("metrics: native scripts and envelopes own their document (ui-warm-reopen)", _UIWH_DocumentFence)

_UIWH_OpeningDuringRetirement() {
	global _HC_Retiring, _HC_PendingMode, _HC_RequestSerial, _HC_PendingSerial
	SavedSerial := _HC_RequestSerial
	SavedPendingSerial := _HC_PendingSerial
	SavedRetiring := KLWV.retiring
	SavedHcRetiring := _HC_Retiring
	HadPending := IsSet(_HC_PendingMode)
	SavedPending := HadPending ? _HC_PendingMode : ""
	Pending := Map()
	try {
		KLWV.retiring := Map("typing", Pending)
		AssertTrue(KLWV_Open("typing", "new-store"))
		AssertEqual("new-store", Pending["metrics_dir"], "opening cannot borrow a half-retired host")
		_HC_Retiring := true
		HealthCheck_ShowWindow("report")
		AssertEqual("report", _HC_PendingMode, "diagnostics retain the latest mode until retirement ends")
		OldSerial := _HC_PendingSerial
		HealthCheck_ShowWindow("newer-mode")
		_HC_ResumePending("report", OldSerial)
		AssertEqual("newer-mode", _HC_PendingMode, "a scheduled predecessor cannot overwrite a newer request")
	} finally {
		KLWV.retiring := SavedRetiring
		_HC_Retiring := SavedHcRetiring
		_HC_PendingMode := HadPending ? SavedPending : unset
		_HC_RequestSerial := SavedSerial, _HC_PendingSerial := SavedPendingSerial
	}
}
Test("UI: opening during retirement retains its request without native creation (ui-warm-reopen)",
	_UIWH_OpeningDuringRetirement)

class _UIWH_CachePromise {
	__New(Calls, Refuse := false) {
		this.Calls := Calls
		this.Refuse := Refuse
	}
	await(Timeout) {
		this.Calls.Push(Timeout)
		if this.Refuse
			throw TimeoutError("Private cache refusal")
		return "{}"
	}
}

_UIWH_CacheInvalidation() {
	global WEBVIEW_DOCUMENT_CACHE_TIMEOUT_MS
	Calls := []
	View := {CallDevToolsProtocolMethodAsync: (Self, Method, Payload) =>
		(Calls.Push(Method), Calls.Push(Payload), _UIWH_CachePromise(Calls))}
	WebView_ClearDocumentCache(View)
	AssertEqual("Network.clearBrowserCache", Calls[1])
	AssertEqual("{}", Calls[2])
	AssertEqual(WEBVIEW_DOCUMENT_CACHE_TIMEOUT_MS, Calls[3], "cache invalidation has one bounded owner")
	Failure := {CallDevToolsProtocolMethodAsync: (*) => _UIWH_CachePromise([], true)}
	AssertThrows(() => WebView_ClearDocumentCache(Failure), "an invalidation refusal cannot bless stale assets")
}
Test("UI: document cache invalidation is bounded and propagates refusal (ui-warm-reopen)",
	_UIWH_CacheInvalidation)

_UIWH_BrowserCaption() {
	SavedHidden := A_DetectHiddenWindows
	Host := WMBrowserWarmHost()
	try {
		DetectHiddenWindows(true)
		Parent := DllCall("GetParent", "Ptr", Host.Hwnd, "Ptr")
		Assert(Parent > 0, "the retained controller belongs to a real native host")
		AssertEqual(WindowTitle(""), WinGetTitle("ahk_id " . Parent), "the warm host uses the shared product title")
		AssertEqual(0xC00000, WinGetStyle("ahk_id " . Parent) & 0xC00000, "controller geometry retains the native caption")
		AssertFalse(DllCall("IsWindowVisible", "Ptr", Parent))
	} finally {
		Host.Destroy.Call()
		DetectHiddenWindows(SavedHidden)
	}
}
Test("UI: hidden browser host retains its caption and shared title (ui-warm-browser-title)", _UIWH_BrowserCaption)
