; tests/fixtures/layer_editor_ready_delivery_body.ahk

; ==============================================================================
; MODULE: Layer Editor Ready Delivery Child
; DESCRIPTION:
; The real public layer editor registers its real ready callbacks at a passive
; SDK. Their genuine native one-shot dispatch is observed, never called by Main.
; Native Suspend and the genuine resume/menu reactor remain real. No DOM or
; ordinary browser timing is certified by this component.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRDS_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

t(Key) => Key
WindowTitle(Label := "") => Label

Gui_Create(Options := "", Title := "") {
	global _LRDS
	Window := Gui(Options, Title)
	_LRDS.Windows.Push(Window)
	return Window
}

class WebView2 {
	static CreateEnvironmentAsync(BrowserFolder, UserDataFolder, Options, Loader) {
		global _LRDS, WEBVIEW_SHARED_UDIR
		_LRDS_Require(BrowserFolder == 0 && UserDataFolder == WEBVIEW_SHARED_UDIR
			&& UserDataFolder == A_Args[2] . "\profile" && Options == ""
			&& Loader == A_Args[2] . "\64bit\WebView2Loader.dll",
			"The actual shared environment may acquire only this private passive SDK.")
		_LRDS.Environments += 1
		Resolved := Promise.withResolvers()
		Resolved.resolve.Call({Passive: true})
		return Resolved.promise
	}
	static create(Hwnd, Callback?, Environment := 0) {
		global _LRDS
		_LRDS_Require(!IsSet(Callback) && Environment.Passive
			&& DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
			"The passive SDK must receive the genuine native placeholder.")
		Controller := _LRDS_Controller()
		_LRDS.Controllers.Push(Controller)
		return Controller
	}
}

class _LRDS_Settled {
	onSettled(Success, Failure) {
		Success.Call("")
	}
}

class _LRDS_Subscription {
	__New(View, Kind, Callback) {
		this.View := View, this.Kind := Kind
		View.Active += 1
		View.Callbacks[Kind] := Callback
	}
	__Delete() {
		this.View.Active -= 1
		this.View.Callbacks.Delete(this.Kind)
	}
}

class _LRDS_View {
	__New() {
		this.Settings := {}, this.Callbacks := Map(), this.Active := 0
		this.Scripts := [], this.Init := [], this.Navigations := 0
	}
	WebMessageReceived(Callback) => _LRDS_Subscription(this, "message", Callback)
	NavigationCompleted(Callback) => _LRDS_Subscription(this, "navigation", Callback)
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
	ExecuteScriptAsync(Js) {
		global _LRDS
		this.Scripts.Push(Js)
		Prefix := "if(window.init)window.init("
		if SubStr(Js, 1, StrLen(Prefix)) == Prefix {
			_LRDS_Require(SubStr(Js, -1) == ")", "The actual init projection must preserve its JSON envelope.")
			Data := JsonParse(SubStr(Js, StrLen(Prefix) + 1, StrLen(Js) - StrLen(Prefix) - 1))
			_LRDS_Require(Data is Map && Data["os"] == "windows"
				&& Data["path"] == _LRDS.LayerPath && Data["text"] == _LRDS.LayerText
				&& Data["errors"] is Array && Data["errors"].Length == 0,
				"Only the genuine layer projection of the exact private file can qualify as initialization.")
			this.Init.Push(Data)
		}
		return _LRDS_Settled()
	}
}

class _LRDS_Controller {
	__New() {
		this.CoreWebView2 := _LRDS_View(), this.Closed := 0, this.Fills := 0, this.ActiveAtClose := -1
	}
	Close() {
		this.Closed += 1
		this.ActiveAtClose := this.CoreWebView2.Active
	}
	Fill() {
		this.Fills += 1
	}
}

; Observe the actual timer's dynamically bound method while delegating once to
; the genuine production method. Main never invokes a ready dispatch directly.
_LRDS_Dispatch(Record, Host, Params*) {
	global _LRDS
	Record.Calls += 1, Record.InFlight := true
	try {
		_LRDS_Require(Host == Record.Host && Params.Length == 1,
			"The actual SDK-triggered timer must retain its exact host and epoch ABI.")
		Record.LastEpoch := Params[1]
		Record.Paused := A_IsSuspended
		if A_IsSuspended
			Record.PausedCalls += 1
		WebViewHost.Prototype._DispatchReady.Call(Host, Params*)
	} catch as Failure {
		if !IsObject(_LRDS.Failure)
			_LRDS.Failure := Failure
		throw
	} finally {
		Record.InFlight := false
		Record.Settled += 1
	}
}

_LRDS_Open() {
	global _LRDS, LAYER_EDITOR_APP_ID
	_LRDS.PublicCalls += 1
	_LRDS_Require(LayerEditor_Open(), "The genuine public layer editor must open its native host.")
	_LRDS_Require(WebViewHost._Instances.Has(LAYER_EDITOR_APP_ID),
		"A live genuine singleton must be published after public construction.")
	Host := WebViewHost._Instances[LAYER_EDITOR_APP_ID]
	for Record in _LRDS.Records
		if Record.Host == Host
			return Record
	_LRDS_Require(Host.HasOwnProp("Controller") && Host.HasOwnProp("WebView")
		&& Host.Gui == _LRDS.Windows[_LRDS.Windows.Length]
		&& Host.Controller == _LRDS.Controllers[_LRDS.Controllers.Length]
		&& Host.WebView.Active == 2 && Host.WebView.Navigations == 1 && Host.Controller.Fills > 0,
		"The public native host must retain its genuine SDK registrations and browser publication.")
	Record := {Host: Host, View: Host.WebView, Controller: Host.Controller,
		Window: Host.Gui, Epoch: Host.Epoch, Calls: 0, Settled: 0, InFlight: false, LastEpoch: 0, Paused: false, PausedCalls: 0, EventSent: false}
	Record.Dispatch := _LRDS_Dispatch.Bind(Record)
	Host.DefineProp("_DispatchReady", {Call: Record.Dispatch})
	_LRDS.Records.Push(Record)
	return Record
}

_LRDS_ReadyEvent(Record) {
	global _LRDS
	_LRDS_Require(Record.View.Callbacks.Has("navigation"), "The SDK must retain the actual navigation callback.")
	Callback := Record.View.Callbacks["navigation"]
	_LRDS.NavigationEvents += 1
	Record.EventSent := true
	Callback.Call(Record.View, {})
}

_LRDS_Pump(Record, WantedDispatch, WantedInit) {
	global _LRDS
	Started := A_TickCount
	while !IsObject(_LRDS.Failure)
		&& (Record.Settled < WantedDispatch || Record.View.Init.Length < WantedInit)
		&& TickElapsed(Started) < 3000
		Sleep(5)
	if IsObject(_LRDS.Failure)
		throw _LRDS.Failure
}

_LRDS_Resume() {
	global _LRDS, _LifecycleLatestTransition, _LLM_MenuBuildCoordinator
	Suspend(false)
	_LRDS_Require(Ergopti_OnSuspendResume(), "The actual resume reactor must complete without retained owner debt.")
	_LRDS.Resumes += 1
	_LRDS_Require(_LifecycleLatestTransition.phase == "resume" && _LifecycleLatestTransition.finished
		&& _LifecycleLatestTransition.debt.Length == 0
		&& _LLM_MenuBuildCoordinator is LLMMenuBuildCoordinator,
		"The real resume/menu service graph must execute; an absent service cannot create a false stranded init.")
}

_LRDS_Log(Line) {
	global _LRDS
	if InStr(Line, "[ERROR]") && !IsObject(_LRDS.Failure)
		_LRDS.Failure := Error("The actual host/data/resume path emitted an error before its business oracle.")
}

_LRDS_OnError(Failure, Mode) {
	global _LRDS
	if !IsObject(_LRDS.Failure)
		_LRDS.Failure := Failure is Error ? Failure : Error("An asynchronous layer readiness failure was observed.")
	try FileAppend("DIAG layer-ready async type=" . Type(Failure) . " mode=" . Mode . "`n", "*", "UTF-8")
	return true
}

_LRDS_Report(Record) {
	global _LRDS
	FileAppend("RECEIPT layer-ready mode=" . _LRDS.Mode . " public_calls=" . _LRDS.PublicCalls
		. " navigation_events=" . _LRDS.NavigationEvents . " resumes=" . _LRDS.Resumes
		. " ready=" . Record.Host.Ready . " ready_fired=" . Record.Host.ReadyFired
		. " dispatch_calls=" . Record.Calls . " dispatch_settled=" . Record.Settled
		. " dispatch_paused=" . Record.Paused . " paused_calls=" . Record.PausedCalls . " dispatch_epoch=" . Record.LastEpoch
		. " initial_epoch=" . Record.Epoch . " init_scripts=" . Record.View.Init.Length
		. " scripts=" . Record.View.Scripts.Length . " native_suspended=" . A_IsSuspended
		. " closed=" . Record.Controller.Closed . " host_records=" . _LRDS.Records.Length
		. " latest_init_scripts=" . _LRDS.Records[_LRDS.Records.Length].View.Init.Length
		. " boundary_failure=" . IsObject(_LRDS.Failure)
		. "`n", "*", "UTF-8")
}

_LRDS_Main() {
	global _LRDS, _VendorDir, _SharedDir, _ConfigDir, WEBVIEW_SHARED_UDIR
	global Features, CategoryEnabled, TapHold, _LayerEditorOsProbe, _LLM_Menu
	if A_Args.Length != 3
		ExitApp(2)
	Persistent(true)
	_LRDS := {Mode: A_Args[1], Windows: [], Controllers: [], Records: [], Failure: 0,
		Environments: 0, PublicCalls: 0, NavigationEvents: 0, Resumes: 0, LayerText: "", LayerPath: ""}
	OnError(_FeatureStateSmokeFatal, 0)
	OnError(_LRDS_OnError)
	LoggerSetTestSink(_LRDS_Log)
	_VendorDir := A_Args[2], WEBVIEW_SHARED_UDIR := A_Args[2] . "\profile"
	_SharedDir := A_Args[3], _ConfigDir := A_Args[2] . "\config\"
	; Configuration/legend inputs are passive data. No remap/Hotkey initializer
	; or synthetic input action is started by this child.
	Features := Map("layout", Map("ergopti_base", false, "direct_access_digits", "native",
		"number_row_reorder_edges", false, "emulate_number_row", false,
		"emulate_top_row", false, "emulate_home_row", false, "emulate_bottom_row", false))
	CategoryEnabled := Map("Layout", false)
	TapHold := Map("keys", Map())
	_LayerEditorOsProbe := {Hkl: (*) => 0, ScToVk: (*) => 0, ToUnicode: (*) => {Count: 0, Text: ""}}
	Primary := 0, Observed := false, InheritedCritical := A_IsCritical
	try {
		DirCreate(_ConfigDir)
		Ctx := KeymapLayers_LoadContext(_SharedDir)
		_LRDS.LayerPath := KeymapLayers_UserFilePath(Ctx, _ConfigDir)
		_LRDS.LayerText := FSReadStrict(_SharedDir . "\tests\corpus\layer_editor\edited_layers.toml")
		_LRDS_Require(FSWriteCreateDurable(_LRDS.LayerPath, _LRDS.LayerText) == 1,
			"Only an exclusively created private layer file can be the init source.")
		_LRDS_Require(!_LLM_Menu["enabled"] && !_LLM_Menu["bootstrap_pending"],
			"The real menu starts neutral, without an invented pending bootstrap.")
		Record := _LRDS_Open()
		HeldCritical := Critical("On")
		try {
			_LRDS_ReadyEvent(Record)
			_LRDS_Require(Record.Calls == 0 && Record.View.Scripts.Length == 0,
				"The genuine SDK callback must defer delivery until the native SUT timer runs.")
			if _LRDS.Mode == "paused-dispatch"
				Suspend(true)
			if _LRDS.Mode == "retired-epoch" {
				Record.Host.Close()
				_LRDS_Require(Record.Host.ResetDone && Record.Controller.Closed == 1,
					"The original host must genuinely retire before its delayed timer can run.")
				Successor := _LRDS_Open()
				_LRDS_Require(Successor.Host != Record.Host && Successor.Window != Record.Window,
					"A retired host must not masquerade as the actual public successor.")
				_LRDS_ReadyEvent(Successor)
			}
		} finally Critical(HeldCritical)
		_LRDS_Pump(Record, 1, _LRDS.Mode == "current" ? 1 : 0)
		_LRDS_Require(Record.Calls >= 1 && Record.Settled == Record.Calls && !Record.InFlight
			&& Record.LastEpoch == Record.Epoch,
			"The real SUT native timer must be observed through its complete captured epoch dispatch.")
		if _LRDS.Mode == "paused-dispatch" {
			_LRDS_Require(Record.Paused && Record.View.Scripts.Length == 0,
				"Actual suspended delivery must perform no browser submission while paused.")
			_LRDS_Resume()
			; Exercise both actual recovery producers; reopening the singleton must
			; not be confused with constructing a second fresh page.
			_LRDS_ReadyEvent(Record)
			_LRDS_Require(_LRDS_Open() == Record && _LRDS.Windows.Length == 1,
				"Public reopen must observe the same live native singleton.")
			_LRDS_Pump(Record, 1, 1)
		}
		if _LRDS.Mode == "retired-epoch"
			_LRDS_Pump(Successor, 1, 1)
		_LRDS_Report(Record), Observed := true
		if IsObject(_LRDS.Failure)
			throw _LRDS.Failure
		if _LRDS.Mode == "retired-epoch" {
			_LRDS_Require(Record.View.Init.Length == 0 && Record.Controller.Closed == 1
				&& Successor.View.Init.Length == 1 && Successor.Calls >= 1 && Successor.Settled == Successor.Calls,
				"The old epoch must remain inert while only the new public host initializes once.")
		} else
			_LRDS_Require(Record.View.Init.Length == 1 && Record.Controller.Closed == 0,
				"A live current layer editor must eventually receive exactly one actual init projection after readiness delivery and resume.")
	} catch as Failure {
		Primary := IsObject(_LRDS.Failure) ? _LRDS.Failure : Failure
	} finally {
		if !Observed && _LRDS.Records.Length > 0 {
			try _LRDS_Report(_LRDS.Records[1])
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		Suspend(false)
		Critical("Off")
		try {
			for Item in _LRDS.Records
				Item.Host.Close()
			for Window in _LRDS.Windows
				Window.Destroy()
			for Item in _LRDS.Records {
				; A failure before Main pumps must still let the real outstanding
				; SUT callback settle against its retired host before observer release.
				Started := A_TickCount
				while Item.EventSent && Item.Settled == 0 && TickElapsed(Started) < 1000
					Sleep(5)
				_LRDS_Require(!Item.EventSent || Item.Settled > 0,
					"Every observed pending readiness timer must settle before observer cleanup.")
				_LRDS_Require(Item.Controller.Closed == 1 && Item.Controller.ActiveAtClose == 0,
					"Each exact private controller must close once after unsubscribing its own SDK tokens.")
				_LRDS_Require(!Item.Host.BuildActive && Item.Host.ResetDone,
					"Every actual private host must retire before its instance observer is detached.")
				Item.Host.DeleteProp("_DispatchReady")
				Item.Dispatch := 0
			}
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		LoggerClearTestSink()
		OnError(_LRDS_OnError, 0)
		Critical(InheritedCritical)
	}
	if !IsObject(Primary) && IsObject(_LRDS.Failure)
		Primary := _LRDS.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS layer-ready-delivery " . _LRDS.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_LRDS_Main()
