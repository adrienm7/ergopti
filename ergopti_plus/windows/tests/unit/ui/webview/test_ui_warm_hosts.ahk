; tests/unit/ui/webview/test_ui_warm_hosts.ahk

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
	global _HC_RequestSerial, _HC_PendingSerial, _HC_PendingOpen
	SavedSerial := _HC_RequestSerial
	SavedPendingSerial := _HC_PendingSerial
	SavedPending := _HC_PendingOpen
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
		_HC_PendingOpen := true
		_HC_PendingSerial := _HC_RequestSerial
		QueuedSerial := _HC_RequestSerial
		AssertEqual(1, _HealthCheck_CloseGui(G))
		AssertTrue(_HC_CloseDuringOpen, "closing during native creation retains the user's intent")
		AssertFalse(_HC_PendingOpen, "a user close cancels an earlier queued open")
		_HC_ResumePending(QueuedSerial)
		AssertFalse(_HC_PendingOpen, "an already scheduled stale open cannot reopen the window")
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
		_HC_PendingOpen := SavedPending
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
	global _HC_Retiring, _HC_PendingOpen, _HC_RequestSerial, _HC_PendingSerial
	SavedSerial := _HC_RequestSerial
	SavedPendingSerial := _HC_PendingSerial
	SavedRetiring := KLWV.retiring
	SavedHcRetiring := _HC_Retiring
	SavedPending := _HC_PendingOpen
	Pending := Map()
	try {
		KLWV.retiring := Map("typing", Pending)
		AssertTrue(KLWV_Open("typing", "new-store"))
		AssertEqual("new-store", Pending["metrics_dir"], "opening cannot borrow a half-retired host")
		_HC_Retiring := true
		HealthCheck_ShowWindow()
		AssertTrue(_HC_PendingOpen, "diagnostics retain the latest request until retirement ends")
		OldSerial := _HC_PendingSerial
		HealthCheck_ShowWindow()
		NewSerial := _HC_PendingSerial
		AssertTrue(NewSerial > OldSerial, "the newer request owns the pending serial")
		_HC_ResumePending(OldSerial)
		AssertTrue(_HC_PendingOpen, "a scheduled predecessor cannot consume a newer request")
		AssertEqual(NewSerial, _HC_PendingSerial, "a scheduled predecessor cannot overwrite a newer request")
	} finally {
		KLWV.retiring := SavedRetiring
		_HC_Retiring := SavedHcRetiring
		_HC_PendingOpen := SavedPending
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

_UIWH_SingletonCloseOwnership() {
	Saved := WebViewHost._Instances
	Live := WebViewHost()
	Other := WebViewHost()
	Live.AppId := "private-singleton"
	Other.AppId := Live.AppId
	WebViewHost._Instances := Map(Live.AppId, Live)
	try {
		Other.Close()
		AssertTrue(WebViewHost._Instances.Has(Live.AppId),
			"closing an AllowMultiple host must retain the registered singleton")
		AssertTrue(WebViewHost._Instances[Live.AppId] == Live)
		Live.Close()
		AssertFalse(WebViewHost._Instances.Has(Live.AppId), "the registered owner removes itself")
		Replacement := WebViewHost()
		Replacement.AppId := Live.AppId
		WebViewHost._Instances[Live.AppId] := Replacement
		Live.Close()
		AssertTrue(WebViewHost._Instances.Has(Live.AppId),
			"a repeated close cannot unregister the replacement singleton")
		AssertTrue(WebViewHost._Instances[Live.AppId] == Replacement)
		Replacement.Close()
		AssertEqual(0, WebViewHost._Instances.Count)
	} finally WebViewHost._Instances := Saved
}
Test("WebView host: close removes only its registered singleton (webview-singleton-close-owner)",
	_UIWH_SingletonCloseOwnership)

_UIWH_FailingCallback(Calls, Failure, Params*) {
	Calls.Push(Params.Length)
	throw Failure
}

_UIWH_DispatchFailure(IsReady) {
	Calls := []
	Failure := Error("Private bridge callback failure")
	Host := WebViewHost()
	Host.Opts := Map("OnReady", _UIWH_FailingCallback.Bind(Calls, Failure),
		"OnMessage", _UIWH_FailingCallback.Bind(Calls, Failure))
	Caught := 0
	try {
		if IsReady
			Host._DispatchReady(Host.Epoch)
		else
			Host._DispatchMessage(Host.Epoch, Map("action", "save"))
	} catch Any as Err {
		Caught := Err
	}
	AssertEqual(1, Calls.Length, "the admitted callback executes exactly once")
	AssertEqual(IsReady ? 1 : 2, Calls[1], "the callback receives its complete contract")
	AssertTrue(Caught == Failure, "the original failure must reach the timer's global error owner")
	Host._Reset()
	if IsReady
		Host._DispatchReady(Host.Epoch - 1)
	else
		Host._DispatchMessage(Host.Epoch - 1, Map())
	AssertEqual(1, Calls.Length, "a retired callback stays inert")
}
Test("WebView host: message callback failures reach the error owner (webview-callback-error)",
	_UIWH_DispatchFailure.Bind(false))
Test("WebView host: ready callback failures reach the error owner (webview-callback-error)",
	_UIWH_DispatchFailure.Bind(true))

; A cancelled native timer releases its callback, but the host's own field still
; retains a BoundFunc back to the host unless teardown breaks that cycle too.
class _UIWH_TimerLifetimeHost extends WebViewHost {
	__New(Receipt) {
		this.Receipt := Receipt
	}
	_SafetyFlush() {
		this.Receipt["fired"] += 1
	}
	__Delete() {
		this.Receipt["released"] += 1
	}
}

_UIWH_TimerLifetime(AlreadyFired) {
	Receipt := Map("fired", 0, "released", 0)
	Host := _UIWH_TimerLifetimeHost(Receipt)
	Host.SafetyTimer := Host._SafetyFlush.Bind(Host)
	SetTimer(Host.SafetyTimer, AlreadyFired ? -1 : -60000)
	if AlreadyFired {
		Started := A_TickCount
		while Receipt["fired"] == 0 && A_TickCount - Started < 2000
			Sleep(1)
	}
	Host.Close()
	Host := 0
	AssertEqual(AlreadyFired ? 1 : 0, Receipt["fired"], "close cancels only the retained timer")
	AssertEqual(1, Receipt["released"], "a closed host must be reclaimable before interpreter shutdown")
}
Test("WebView host: closing releases a pending timer's host (webview-timer-release)",
	_UIWH_TimerLifetime.Bind(false))
Test("WebView host: closing releases an expired timer's host (webview-timer-release)",
	_UIWH_TimerLifetime.Bind(true))

; Exercise native WM_CLOSE against a private real HWND while controller creation
; yields. Only Chromium acquisition is replaced; GUI close/hide/destroy are real.
_UIWH_RecordBuildClose(State, *) {
	State["close_observed"] := true
}

_UIWH_BuildCancel(State, Phase) {
	if State["phase"] != Phase
		return
	AssertTrue(DllCall("PostMessageW", "Ptr", State["hwnd"], "UInt", 0x10,
		"Ptr", 0, "Ptr", 0, "Int"), "the private native parent receives WM_CLOSE")
	Started := A_TickCount
	while !State["close_observed"] && A_TickCount - Started < 2000
		Sleep(1)
	State["alive_during_await"] := WMHandleExists(State["hwnd"])
	State["hidden_during_await"] := !DllCall("IsWindowVisible", "Ptr", State["hwnd"], "Int")
	Host := State["host"]
	; Even callbacks arriving with the post-cancel epoch must remain inert while
	; the native parent still exists and ResetDone has intentionally not fired.
	Host._DispatchMessage(Host.Epoch, Map())
	Host._DispatchReady(Host.Epoch)
	Host._OnNavigationCompleted(0, 0)
	Host._OnWebMessage(0, {TryGetWebMessageAsString: (*) => "ready"})
	Host.Eval("privateFixture();")
	State["ready_during_cancel"] := Host.Ready
	State["queued_during_cancel"] := Host.Queue.Length
}

_UIWH_BuildShow(State, Host, Window, Options) {
	State["host"] := Host
	State["window"] := Window
	Window.Show("Hide w220 h140")
	State["hwnd"] := Window.Hwnd
	Window.OnEvent("Close", _UIWH_RecordBuildClose.Bind(State), -1)
	_UIWH_BuildCancel(State, "show")
}

_UIWH_BuildCreate(State, Host, PlaceholderHwnd, Loader) {
	State["creates"] += 1
	_UIWH_BuildCancel(State, State["phase"] == "create-error" ? "create-error" : "create")
	if State["phase"] == "create-error"
		throw Error("Private cancelled controller acquisition failure.")
	return State["controller"]
}

class _UIWH_BuildController {
	__New(State) {
		this.State := State
	}
	CoreWebView2 {
		get {
			this.State["core_reads"] += 1
			_UIWH_BuildCancel(this.State, "core")
			return _UIWH_BuildView(this.State)
		}
	}
	Fill() {
		this.State["fills"] += 1
		_UIWH_BuildCancel(this.State, "fill")
	}
	Close() {
		this.State["closes"] += 1
		this.State["parent_alive_at_dispose"] := WMHandleExists(this.State["hwnd"])
	}
}

class _UIWH_BuildView {
	Settings := {}
	__New(State) {
		this.State := State
	}
	WebMessageReceived(Callback) {
		return {}
	}
	NavigationCompleted(Callback) {
		return {}
	}
	SetVirtualHostNameToFolderMapping(*) {
	}
	Navigate(Url) {
		this.State["navigates"] += 1
		_UIWH_BuildCancel(this.State, "navigate")
	}
}

_UIWH_BuildCallback(State, *) {
	State["callbacks"] += 1
}

_UIWH_CloseDuringBuild(Phase) {
	global WebView2
	HadWebView2 := IsSet(WebView2)
	SavedShow := WebViewHost.Prototype.GetOwnPropDesc("_ShowWindow")
	SavedCreate := WebViewHost.Prototype.GetOwnPropDesc("_CreateController")
	SavedInstances := WebViewHost._Instances
	SavedManifest := WebViewHost._ManifestCache
	SavedSuspended := A_IsSuspended
	SavedCritical := A_IsCritical
	State := Map("phase", Phase, "close_observed", false, "creates", 0, "core_reads", 0,
		"closes", 0, "fills", 0, "navigates", 0, "callbacks", 0, "host", 0, "window", 0)
	State["controller"] := _UIWH_BuildController(State)
	WebViewHost.Prototype.DefineProp("_ShowWindow", {Call: _UIWH_BuildShow.Bind(State)})
	WebViewHost.Prototype.DefineProp("_CreateController", {Call: _UIWH_BuildCreate.Bind(State)})
	WebViewHost._Instances := Map()
	WebViewHost._ManifestCache := Map()
	try {
		; The headless runner omits the Chromium wrapper. Admit only this
		; fixture's controlled acquisition port, then restore true absence.
		if !HadWebView2
			WebView2 := {}
		Suspend(false)
		Critical("Off")
		Host := WebViewHost.TryOpen("private-build-close", Map("Title", "Private build fixture",
			"SkipI18nSeed", true, "OnMessage", _UIWH_BuildCallback.Bind(State),
			"OnReady", _UIWH_BuildCallback.Bind(State)))
		AssertEqual(Phase == "show" ? 0 : 1, State["creates"],
			"the real build must reach the controlled controller acquisition boundary")
		if Phase == "live" {
			AssertTrue(IsObject(Host), "the live acquisition still succeeds")
			AssertTrue(WebViewHost._Instances[Host.AppId] == Host)
			AssertFalse(Host.ResetDone)
			AssertEqual(1, State["core_reads"])
			AssertEqual(1, State["navigates"])
			AssertEqual(1, State["fills"])
			Host.Close()
		} else {
			AssertTrue(State["close_observed"], "the real native Close event must run")
			AssertTrue(State["alive_during_await"], "close cannot destroy the parent of an in-flight native creation")
			AssertTrue(State["hidden_during_await"], "cancelled UI disappears while native acquisition finishes")
			AssertTrue(IsObject(Host), "user cancellation handles the request without opening a fallback")
			AssertTrue(Host.ResetDone, "a late native result cannot resurrect a cancelled host")
			AssertFalse(Host.BuildActive)
			AssertFalse(State["ready_during_cancel"])
			AssertEqual(0, State["queued_during_cancel"])
			AssertEqual(0, State["callbacks"], "cancelled messages and readiness cannot publish")
			AssertEqual(Phase == "show" || Phase == "create" || Phase == "create-error" ? 0 : 1,
				State["core_reads"], "a cancelled controller cannot publish a CoreWebView2")
			AssertEqual(Phase == "navigate" || Phase == "fill" ? 1 : 0, State["navigates"])
			AssertEqual(Phase == "fill" ? 1 : 0, State["fills"])
		}
		ExpectedCloses := Phase == "show" || Phase == "create-error" ? 0 : 1
		AssertEqual(ExpectedCloses, State["closes"], "every acquired late controller is closed exactly once")
		if ExpectedCloses
			AssertTrue(State["parent_alive_at_dispose"], "controller teardown precedes native parent destruction")
		AssertFalse(WMHandleExists(State["hwnd"]))
		AssertEqual(0, Host.Gui)
		AssertEqual(0, WebViewHost._Instances.Count, "a cancelled request cannot publish a singleton")
		Host.Close()
		AssertEqual(ExpectedCloses, State["closes"], "repeated close is idempotent")
	} finally {
		if IsObject(State["host"])
			State["host"].Close()
		if IsObject(State["window"])
			try State["window"].Destroy()
		State["host"] := 0
		State["window"] := 0
		State["controller"] := 0
		WebViewHost.Prototype.DefineProp("_ShowWindow", SavedShow)
		WebViewHost.Prototype.DefineProp("_CreateController", SavedCreate)
		if !HadWebView2
			WebView2 := unset
		WebViewHost._Instances := SavedInstances
		WebViewHost._ManifestCache := SavedManifest
		Suspend(SavedSuspended)
		Critical(SavedCritical)
	}
}
for _UIWH_BuildPhase in ["show", "create", "core", "navigate", "fill", "create-error", "live"]
	Test("WebView host: native parent survives close during " . _UIWH_BuildPhase
		. " acquisition (webview-build-close-ownership)", _UIWH_CloseDuringBuild.Bind(_UIWH_BuildPhase))
