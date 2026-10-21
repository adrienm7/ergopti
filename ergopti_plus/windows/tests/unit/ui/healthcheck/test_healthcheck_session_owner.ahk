; tests/unit/ui/healthcheck/test_healthcheck_session_owner.ahk

; ==============================================================================
; MODULE: Diagnostics Page Session Ownership Tests
; DESCRIPTION:
; Native WM_CLOSE retires a page while a real diagnostics action is on the
; stack. Its successor keeps its snapshot, export revision and local probe run.
; ==============================================================================

#Requires AutoHotkey v2.0

class _HCSO_View {
	__New(State) {
		this.State := State, this.Scripts := []
		this.Pending := []
		State["views"].Push(this)
	}
	ExecuteScriptAsync(Script) {
		this.Scripts.Push(Script)
		if this.State["stage"] == "ready-send" && !this.State["fired"]
			_HCSO_Replace(this.State)
		Pending := Promise((Resolve, Reject) => Resolve("null"))
		this.Pending.Push(Pending)
		return Pending
	}
}

class _HCSO_Request {
	__New(State) {
		this.State := State
	}
	Abort() {
		_HCSO_Replace(this.State)
		return true
	}
}

class _HCSO_TerminalHost {
	__New(State, Owner) {
		this.State := State, this.Failure := {Owner: Owner}
	}
	Close() {
		_HCSO_Replace(this.State)
	}
}

_HCSO_Close(Window, *) {
	return _HealthCheck_CloseGui(Window)
}

_HCSO_Install(State, Revision) {
	global _HC_Gui, _HC_Controller, _HC_WebView, _HC_WindowEpoch, _HC_Session, _HC_ResetDone
	Window := _HC_NewWindow()
	State["windows"].Push(Window)
	Window.OnEvent("Close", _HCSO_Close.Bind(Window))
	Window.Show("Hide w640 h480")
	Snapshot := HealthCheck_Run()
	Snapshot["export_revision"] := Revision
	_HC_WindowEpoch += 1
	_HC_ResetDone := false
	_HC_Gui := Window
	_HC_Controller := {IsVisible: false}
	_HC_WebView := _HCSO_View(State)
	_HC_Session := Map("epoch", _HC_WindowEpoch, "snapshot", Snapshot, "extensive", false,
		"detailed", false, "page_url", "https://diagnostics.invalid/?epoch=" . _HC_WindowEpoch)
	return _HC_Session
}

_HCSO_Replace(State) {
	global _HC_Gui, _HC_WindowEpoch, _HC_Session, _HC_ProbeRun, _HC_WebView, _HC_Controller
	if State["fired"]
		return
	State["fired"] := true
	try {
		Epoch := _HC_WindowEpoch
		AssertTrue(DllCall("User32\PostMessageW", "Ptr", _HC_Gui.Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int"),
			"the native hidden host accepts WM_CLOSE without a window-title lookup")
		Started := A_TickCount
		while _HC_WindowEpoch == Epoch && A_TickCount - Started < 5000
			Sleep(1)
		AssertTrue(_HC_WindowEpoch != Epoch && _HC_Session == 0, "the actual Close handler retires A")
		if !State["reopen"]
			return
		Session := _HCSO_Install(State, 41)
		State["successor"] := Session
		State["view"] := _HC_WebView, State["controller"] := _HC_Controller
		; Use the real asynchronous local probe, with genuinely absent fixture files.
		HealthCheck_StartProbes(_HC_WindowEpoch, HealthCheck_Config()["schema"], _HC_PublishProbe, true,
			Map("path_of", (Id) => State["folder"] . "\" . Id . ".toml"))
		State["run"] := _HC_ProbeRun
		Started := A_TickCount
		while Session["snapshot"]["probes"]["configuration"]["state"] == "pending" && A_TickCount - Started < 5000
			Sleep(1)
		AssertEqual("ok", Session["snapshot"]["probes"]["configuration"]["state"], "B's real local probe completed")
		AssertTrue(State["view"].Scripts.Length > 0, "the real publish path reached B's native-shaped WebView")
		State["scripts"] := State["view"].Scripts.Length
		State["snapshot"] := Session["snapshot"]
		State["image"] := _HC_ValueToJson(Session["snapshot"])
		State["export"] := HealthCheck_ShareDocument(Session["snapshot"], HealthCheck_Config()["schema"])["text"]
	} catch as Err {
		; The logger's test sink contains exceptions, so retain and rethrow below.
		State["error"] := Err
	}
}

_HCSO_Log(State, Line) {
	Match := State["stage"] == "action-log" ? "Diagnostics page action: refresh."
		: State["stage"] == "ready-log" ? "Diagnostics page ready in "
		: State["stage"] == "refresh-collect" ? "Collecting the diagnostics…" : ""
	if Match != "" && InStr(Line, Match) && !State["fired"]
		_HCSO_Replace(State)
}

_HCSO_With(Action) {
	global _HC_Gui, _HC_Controller, _HC_WebView, _HC_MsgSub, _HC_WindowEpoch, _HC_Session, _HC_ResetDone
	global _HC_Opening, _HC_Retiring, _HC_PendingOpen, _HC_CloseDuringOpen, _HC_RequestSerial, _HC_PendingSerial
	global _HC_ProbeRun, _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, _LOGGER_REPEAT_ENABLED
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	global DriverPid
	if _HC_ProbeRun || _HC_Session is Map
		throw Error("A foreign diagnostics session is active.")
	if ManagedNetworkTerminalFailure.Owners.Has("diagnostics") || IsObject(ManagedDownloadFailureWindow.Current)
		throw Error("A foreign managed failure window is active.")
	HadIntent := ManagedNetworkTerminalFailure.Intents.Has("diagnostics")
	SavedIntent := ManagedNetworkTerminalFailure.Intents.Get("diagnostics", 0)
	SavedTerminal := ManagedDownloadFailureWindow.Current
	Saved := Map()
	for Name in ["_HC_Gui", "_HC_Controller", "_HC_WebView", "_HC_MsgSub", "_HC_WindowEpoch", "_HC_Session",
		"_HC_ResetDone", "_HC_Opening", "_HC_Retiring", "_HC_PendingOpen", "_HC_CloseDuringOpen",
		"_HC_RequestSerial", "_HC_PendingSerial", "_LOGGER_TEST_SINK", "_LOGGER_INFO_ENABLED", "_LOGGER_REPEAT_ENABLED",
		"_LOGGER_DEDUP_KEY", "_LOGGER_DEDUP_LEVEL", "_LOGGER_DEDUP_COUNT", "_LastErrTime"]
		Saved[Name] := IsSet(%Name%) ? {Value: %Name%} : 0
	AssertTrue(DriverPid is Integer && DriverPid > 0, "the fixture uses the driver's native process identity")
	PreviousCritical := Critical("Off")
	State := Map("stage", "", "fired", false, "reopen", false, "windows", [], "views", [])
	State["folder"] := A_Temp . "\ergopti-health-owner-" . DriverPid . "-" . A_TickCount
	Failure := 0, CleanupErrors := []
	try {
		DirCreate(State["folder"])
		_HC_Opening := false, _HC_Retiring := false, _HC_PendingOpen := false
		_HC_Controller := unset, _HC_WebView := unset, _HC_MsgSub := unset
		_LOGGER_INFO_ENABLED := true, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_DEDUP_KEY := "", _LOGGER_DEDUP_COUNT := 0
		LoggerSetTestSink(_HCSO_Log.Bind(State))
		Session := _HCSO_Install(State, 7)
		State["original"] := Session, State["original_view"] := _HC_WebView
		Action.Call(State)
		if State.Has("error")
			throw State["error"]
	} catch as Err {
		Failure := Err
	} finally {
		try {
			State["fired"] := true
			try HealthCheck_CancelProbes()
			catch as Err
				CleanupErrors.Push(Err)
			for View in State["views"] {
				for Pending in View.Pending {
					try {
						Started := A_TickCount
						while Pending.HasOwnProp("callbacks") && A_TickCount - Started < 5000
							Sleep(1)
						AssertFalse(Pending.HasOwnProp("callbacks"), "the real Promise completion timer retires before restoration")
					} catch as Err
						CleanupErrors.Push(Err)
				}
				View.State := 0
			}
			for Window in State["windows"] {
				try Window.Destroy()
				catch as Err
					CleanupErrors.Push(Err)
			}
			try {
				if DirExist(State["folder"])
					DirDelete(State["folder"], true)
			} catch as Err
				CleanupErrors.Push(Err)
		} finally {
			; Break the view/state cycle even if a cleanup assertion failed.
			for View in State["views"]
				View.State := 0
			State["views"] := []
			if ManagedNetworkTerminalFailure.Owners.Has("diagnostics")
				ManagedNetworkTerminalFailure.Owners.Delete("diagnostics")
			if HadIntent
				ManagedNetworkTerminalFailure.Intents["diagnostics"] := SavedIntent
			else if ManagedNetworkTerminalFailure.Intents.Has("diagnostics")
				ManagedNetworkTerminalFailure.Intents.Delete("diagnostics")
			ManagedDownloadFailureWindow.Current := SavedTerminal
			for Name, Entry in Saved
				%Name% := IsObject(Entry) ? Entry.Value : unset
			Critical(PreviousCritical)
		}
	}
	if IsObject(Failure) {
		if CleanupErrors.Length
			Failure.CleanupErrors := CleanupErrors
		throw Failure
	}
	if CleanupErrors.Length
		throw CleanupErrors[1]
}

_HCSO_Interrupted(Stage, Reopen, State) {
	global _HC_WindowEpoch, _HC_Session, _HC_ProbeRun
	State["stage"] := Stage, State["reopen"] := Reopen
	Epoch := _HC_WindowEpoch
	Config := HealthCheck_Config()
	Refresh := Map("action", "refresh", "detailed", true, "extensive", false)
	if Stage == "cancel-retire" || Stage == "restart-retire" || Stage == "refresh-retire" {
		; The actual terminal retirement invalidates its owner, then closes its
		; captured host. That native boundary may dispatch the diagnostics close.
		Owner := {CurrentFn: () => true}
		ManagedNetworkTerminalFailure.Owners["diagnostics"] := Owner
		ManagedDownloadFailureWindow.Current := _HCSO_TerminalHost(State, Owner)
		if Stage == "cancel-retire"
			_HC_PerformPageAction(Epoch, Map("action", "cancel"), Config)
		else if Stage == "refresh-retire"
			_HC_PerformPageAction(Epoch, Refresh, Config)
		else
			_HC_RestartProbes(Epoch)
	} else if Stage == "cancel-abort" || Stage == "restart-abort" {
		; The real cancellation API calls the child owner's Abort method.
		_HC_ProbeRun := {Epoch: Epoch, Cancelled: false, Requests: [_HCSO_Request(State)], Publish: _HC_PublishProbe}
		if Stage == "cancel-abort"
			_HC_PerformPageAction(Epoch, Map("action", "cancel"), Config)
		else
			_HC_RestartProbes(Epoch)
	} else if Stage == "action-log" {
		_HC_HandleMessage(Epoch, '{"action":"refresh","detailed":true,"extensive":false}')
	} else if Stage == "refresh-collect" {
		_HC_PerformPageAction(Epoch, Refresh, Config)
	} else {
		_HC_HandleMessage(Epoch, "ready")
	}
	if State.Has("error")
		throw State["error"]
	AssertTrue(State["fired"], "the selected real boundary must execute")
	AssertEqual(Stage == "ready-send" ? 1 : 0, State["original_view"].Scripts.Length,
		"only the submission already in progress may reach the original target")
	if !Reopen {
		AssertEqual(0, _HC_Session, "retired A cannot republish a session")
		AssertEqual(0, _HC_ProbeRun, "retired A cannot restart probes")
		return
	}
	AssertTrue(_HC_Session == State["successor"], "B retains its exact session")
	AssertTrue(_HC_Session["snapshot"] == State["snapshot"], "A cannot replace B's snapshot")
	AssertEqual(State["image"], _HC_ValueToJson(_HC_Session["snapshot"]), "B's rows and revision remain unchanged")
	AssertEqual(State["export"], HealthCheck_ShareDocument(_HC_Session["snapshot"], Config["schema"])["text"],
		"B's actual export remains bound to its own collected image")
	AssertTrue(_HC_ProbeRun == State["run"] && !_HC_ProbeRun.Cancelled, "A cannot cancel or replace B's probe run")
	AssertFalse(_HC_Session["detailed"] || _HC_Session["extensive"], "A's selections cannot change B")
	AssertFalse(State["controller"].IsVisible, "A's ready handler cannot reveal B's controller")
	AssertEqual(State["scripts"], State["view"].Scripts.Length, "A publishes no script into B")
}

for _HCSOStage in ["action-log", "refresh-collect", "ready-log", "ready-send", "cancel-abort", "restart-abort",
	"cancel-retire", "restart-retire", "refresh-retire"] {
	for _HCSOReopen in [false, true]
		Test("HealthCheck: " . _HCSOStage . (_HCSOReopen ? " reopened" : " closed") . " owns its session (healthcheck-session-owner)",
			_HCSO_With.Bind(_HCSO_Interrupted.Bind(_HCSOStage, _HCSOReopen)))
}

_HCSO_Live(Ready, State) {
	global _HC_WindowEpoch, _HC_Session, _HC_Controller, _HC_ProbeRun
	if Ready {
		_HC_HandleMessage(_HC_WindowEpoch, "ready")
		AssertTrue(_HC_Controller.IsVisible, "current ready reveals its own controller")
		AssertContains(State["original_view"].Scripts[1], '"type":"init"')
	} else {
		_HC_PerformPageAction(_HC_WindowEpoch, Map("action", "refresh", "detailed", true, "extensive", false), HealthCheck_Config())
		AssertEqual(8, _HC_Session["snapshot"]["export_revision"])
		AssertTrue(_HC_Session["detailed"])
		AssertContains(State["original_view"].Scripts[1], '"type":"snapshot"')
	}
	AssertTrue(IsObject(_HC_ProbeRun) && _HC_ProbeRun.Epoch == _HC_WindowEpoch && !_HC_ProbeRun.Cancelled,
		"a live current page still starts its real local probes")
}
Test("HealthCheck: live refresh publishes and starts its own probes (healthcheck-session-owner)", _HCSO_With.Bind(_HCSO_Live.Bind(false)))
Test("HealthCheck: live ready publishes and reveals its controller (healthcheck-session-owner)", _HCSO_With.Bind(_HCSO_Live.Bind(true)))

_HCSO_RetiredEntry(ActionId, State) {
	global _HC_WindowEpoch, _HC_Session, _HC_ProbeRun, _HC_Gui
	Image := _HC_ValueToJson(_HC_Session["snapshot"])
	Action := Map("action", ActionId, "detailed", true, "extensive", false, "export_sequence", 1)
	_HC_PerformPageAction(0, Action, HealthCheck_Config())
	AssertTrue(_HC_Session == State["original"], "epoch zero cannot authorize a page action")
	AssertEqual(Image, _HC_ValueToJson(_HC_Session["snapshot"]))
	AssertEqual(0, State["original_view"].Scripts.Length)
	AssertEqual(0, _HC_ProbeRun)
	AssertTrue(DllCall("User32\IsWindow", "Ptr", _HC_Gui.Hwnd, "Int"), "a stale close cannot destroy the live host")
}
for _HCSOAction in ["close", "cancel", "refresh", "export_snapshot"]
	Test("HealthCheck: unowned " . _HCSOAction . " cannot target the current page (healthcheck-session-owner)",
		_HCSO_With.Bind(_HCSO_RetiredEntry.Bind(_HCSOAction)))

class _HCSO_Collection {
	__New() {
		this.Calls := []
	}
	Cancel() {
		this.Calls.Push("collection_cancel")
	}
	Guided() {
		this.Calls.Push("collection_guided")
	}
	SkipGuided() {
		this.Calls.Push("collection_skip")
	}
	OpenFolder() {
		this.Calls.Push("collection_open")
	}
}

_HCSO_NativeCollection(State) {
	global _HC_Collection
	SavedCollection := _HC_Collection
	try {
		_HC_Collection := _HCSO_Collection()
		for Action in ["collection_cancel", "collection_guided", "collection_skip", "collection_open"] {
			AssertTrue(_HC_NativeCollectionAction(Action))
			AssertEqual(Action, _HC_Collection.Calls[-1], "native collection controls retain their independent owner")
		}
		AssertEqual(4, _HC_Collection.Calls.Length)
		AssertEqual(0, State["original_view"].Scripts.Length)
	} finally _HC_Collection := SavedCollection
}
Test("HealthCheck: native collection controls retain epoch-zero authority (healthcheck-session-owner)",
	_HCSO_With.Bind(_HCSO_NativeCollection))
