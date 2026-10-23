; tests/fixtures/layer_editor_navigation_pause_body.ahk

; ==============================================================================
; MODULE: Layer Editor Navigation Pause Child
; DESCRIPTION:
; The real registered navigation callback and original native safety timer run
; while suspended. A safety timeout alone never authorizes initialization.
; Passive SDK ports observe actual init submissions, not browser DOM readiness.
; ==============================================================================

#Requires AutoHotkey v2.0

; Observe only this native child's factory boundary. The real constructor still
; runs once; its later safety Bind and SetTimer remain entirely production-owned.
_LRNS_CreateController(Host, PlaceholderHwnd, Loader) {
	global _LRNS
	_LRDS_Require(!Host.HasOwnProp("_SafetyFlush"), "The safety observer cannot replace an existing instance owner.")
	Safety := {Host: Host, Epoch: Host.Epoch, Calls: 0, Settled: 0, InFlight: false, PausedCalls: 0}
	Safety.Observer := _LRNS_Safety.Bind(Safety)
	_LRNS.SafetyRecords.Push(Safety)
	Host.DefineProp("_SafetyFlush", {Call: Safety.Observer})
	return _LRNS.Factory.Call(Host, PlaceholderHwnd, Loader)
}

_LRNS_Safety(Safety, Host, Params*) {
	global _LRNS, _LRDS
	Safety.Calls += 1, Safety.InFlight := true
	try {
		_LRDS_Require(Host == Safety.Host && Params.Length == 0,
			"Only the original SUT safety timer may deliver this exact host callback.")
		if A_IsSuspended
			Safety.PausedCalls += 1
		_LRNS.Safety.Call(Host)
	} catch as Failure {
		if !IsObject(_LRDS.Failure)
			_LRDS.Failure := Failure
		throw
	} finally {
		Safety.InFlight := false
		Safety.Settled += 1
	}
}

; These passive fields mirror the shipped SDK NavigationCompletedEventArgs.
; The event is a controlled valid lifecycle signal, not observed DOM readiness.
_LRNS_Navigation(Record) {
	global _LRDS
	_LRDS_Require(Record.View.Callbacks.Has("navigation"), "The exact SDK navigation registration must still be live.")
	Callback := Record.View.Callbacks["navigation"]
	_LRDS.NavigationEvents += 1, Record.EventSent := true
	Args := {IsSuccess: true, WebErrorStatus: 0, NavigationId: 1, HttpStatusCode: 200}
	Callback.Call(Record.View, Args)
}

_LRNS_FindSafety(Host) {
	global _LRNS
	for Safety in _LRNS.SafetyRecords
		if Safety.Host == Host
			return Safety
	throw Error("Every public native host must acquire its actual observed safety timer.")
}

_LRNS_WaitSafety(Safety) {
	global _LRDS
	Started := A_TickCount
	while Safety.Settled == 0 && !IsObject(_LRDS.Failure) && TickElapsed(Started) < 5000
		Sleep(5)
	if IsObject(_LRDS.Failure)
		throw _LRDS.Failure
	_LRDS_Require(Safety.Calls > 0 && Safety.Settled == Safety.Calls && !Safety.InFlight
		&& Safety.PausedCalls == Safety.Calls && Safety.Host.Epoch == Safety.Epoch,
		"The original native safety callback must actually finish under pause against its live epoch.")
}

_LRNS_Pulse(Receipt) {
	Receipt.Calls += 1
}

; Observe a real native timer opportunity before any late navigation. An init
; queued blindly by resume cannot hide behind an immediate no-script snapshot.
_LRNS_ObserveWithoutNavigation(Record) {
	global _LRDS, _LRNS
	_LRDS_Require(!A_IsSuspended && !A_IsCritical,
		"The real resumed thread must permit native timer delivery before the late signal.")
	Receipt := {Calls: 0}, Callback := _LRNS_Pulse.Bind(Receipt), Primary := 0
	Started := A_TickCount
	try {
		SetTimer(Callback, -1)
		while (Receipt.Calls == 0 || TickElapsed(Started) < 100)
			&& !IsObject(_LRDS.Failure) && TickElapsed(Started) < 1000
			Sleep(5)
		if IsObject(_LRDS.Failure)
			throw _LRDS.Failure
		_LRDS_Require(Receipt.Calls == 1 && TickElapsed(Started) >= 100,
			"The no-navigation observation must include an actual settled native pulse and bounded timer pump.")
		_LRDS_Require(Record.View.Init.Length == 0 && Record.View.Scripts.Length == 0,
			"Safety expiry and actual resumed timer delivery must not invent a navigation/readiness signal.")
	} catch as Failure {
		Primary := IsObject(_LRDS.Failure) ? _LRDS.Failure : Failure
	} finally {
		_LRNS.QuietCalls := Receipt.Calls, _LRNS.QuietElapsed := TickElapsed(Started)
		_LRNS.InitBeforeLate := Record.View.Init.Length
		try SetTimer(Callback, 0)
		catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
	}
	if IsObject(Primary)
		throw Primary
}

_LRNS_Report(Record, Safety) {
	global _LRDS, _LRNS
	FileAppend("RECEIPT layer-navigation-pause mode=" . _LRDS.Mode
		. " navigation_events=" . _LRDS.NavigationEvents . " resumes=" . _LRDS.Resumes
		. " safety_calls=" . Safety.Calls . " safety_settled=" . Safety.Settled
		. " safety_paused=" . Safety.PausedCalls . " safety_inflight=" . Safety.InFlight
		. " ready=" . Record.Host.Ready . " ready_fired=" . Record.Host.ReadyFired
		. " dispatch_calls=" . Record.Calls . " dispatch_settled=" . Record.Settled
		. " init_scripts=" . Record.View.Init.Length . " closed=" . Record.Controller.Closed
		. " native_suspended=" . A_IsSuspended . " public_calls=" . _LRDS.PublicCalls
		. " quiet_pulses=" . _LRNS.QuietCalls . " quiet_elapsed=" . _LRNS.QuietElapsed
		. " init_before_late=" . _LRNS.InitBeforeLate
		. " host_records=" . _LRDS.Records.Length . " latest_init_scripts=" . _LRDS.Records[_LRDS.Records.Length].View.Init.Length
		. " boundary_failure=" . IsObject(_LRDS.Failure) . "`n", "*", "UTF-8")
}

_LRNS_Main() {
	global _LRDS, _LRNS, _VendorDir, _SharedDir, _ConfigDir, WEBVIEW_SHARED_UDIR
	global Features, CategoryEnabled, TapHold, _LayerEditorOsProbe, _LLM_Menu
	if A_Args.Length != 3
		ExitApp(2)
	Persistent(true)
	_LRDS := {Mode: A_Args[1], Windows: [], Controllers: [], Records: [], Failure: 0,
		Environments: 0, PublicCalls: 0, NavigationEvents: 0, Resumes: 0, LayerText: "", LayerPath: ""}
	_LRNS := {SafetyRecords: [], Factory: WebViewHost.Prototype._CreateController,
		Safety: WebViewHost.Prototype._SafetyFlush, QuietCalls: 0, QuietElapsed: 0, InitBeforeLate: -1}
	OnError(_FeatureStateSmokeFatal, 0)
	OnError(_LRDS_OnError)
	LoggerSetTestSink(_LRDS_Log)
	_VendorDir := A_Args[2], WEBVIEW_SHARED_UDIR := A_Args[2] . "\profile"
	_SharedDir := A_Args[3], _ConfigDir := A_Args[2] . "\config\"
	Features := Map("layout", Map("ergopti_base", false, "direct_access_digits", "native",
		"number_row_reorder_edges", false, "emulate_number_row", false,
		"emulate_top_row", false, "emulate_home_row", false, "emulate_bottom_row", false))
	CategoryEnabled := Map("Layout", false), TapHold := Map("keys", Map())
	_LayerEditorOsProbe := {Hkl: (*) => 0, ScToVk: (*) => 0, ToUnicode: (*) => {Count: 0, Text: ""}}
	Primary := 0, Observed := false, FactoryInstalled := false, InheritedCritical := A_IsCritical
	try {
		DirCreate(_ConfigDir)
		Ctx := KeymapLayers_LoadContext(_SharedDir)
		_LRDS.LayerPath := KeymapLayers_UserFilePath(Ctx, _ConfigDir)
		_LRDS.LayerText := FSReadStrict(_SharedDir . "\tests\corpus\layer_editor\edited_layers.toml")
		_LRDS_Require(FSWriteCreateDurable(_LRDS.LayerPath, _LRDS.LayerText) == 1,
			"Only an exclusively created private layer file can be the init source.")
		_LRDS_Require(!_LLM_Menu["enabled"] && !_LLM_Menu["bootstrap_pending"],
			"The actual resume graph must start without fabricated pending bootstrap work.")
		WebViewHost.Prototype.DefineProp("_CreateController", {Call: _LRNS_CreateController})
		FactoryInstalled := true
		HeldCritical := Critical("On")
		try {
			Record := _LRDS_Open()
			Safety := _LRNS_FindSafety(Record.Host)
			_LRDS_Require(IsObject(Record.Host.SafetyTimer) && Safety.Calls == 0
				&& Record.View.Init.Length == 0,
				"The real safety callback must be armed but not delivered before the pause boundary.")
			Suspend(true)
		} finally Critical(HeldCritical)
		_LRNS_WaitSafety(Safety)
		_LRDS_Require(A_IsSuspended && Record.View.Scripts.Length == 0 && !Record.Host.ResetDone,
			"The live paused host must remain free of browser submissions through actual safety expiry.")
		if _LRDS.Mode != "late-navigation" {
			_LRNS_Navigation(Record)
			_LRDS_Require(Record.View.Scripts.Length == 0,
				"A paused registered navigation callback cannot submit initialization inline.")
		}
		if _LRDS.Mode == "retired-navigation" {
			Record.Host.Close()
			_LRDS_Require(Record.Host.ResetDone && Record.Controller.Closed == 1,
				"The old host must truly retire before resume can service any retained signal.")
		}
		_LRDS_Resume()
		if _LRDS.Mode == "late-navigation" {
			_LRNS_ObserveWithoutNavigation(Record)
			_LRNS_Navigation(Record)
		}
		if _LRDS.Mode == "retired-navigation" {
			Successor := _LRDS_Open()
			_LRDS_Require(Successor.Host != Record.Host && Successor.Window != Record.Window,
				"Only the genuine new public host may own the later readiness signal.")
			_LRNS_Navigation(Successor)
			_LRDS_Pump(Successor, 0, 1)
		} else {
			_LRDS_Require(_LRDS_Open() == Record && _LRDS.Windows.Length == 1,
				"A public reopen must retain the same live singleton without manufacturing a new browser.")
			_LRDS_Pump(Record, 0, 1)
		}
		_LRNS_Report(Record, Safety), Observed := true
		if IsObject(_LRDS.Failure)
			throw _LRDS.Failure
		if _LRDS.Mode == "retired-navigation"
			_LRDS_Require(Record.View.Init.Length == 0 && Record.Controller.Closed == 1
				&& Successor.View.Init.Length == 1 && Successor.Settled == Successor.Calls,
				"A retired host must stay inert while only its genuine successor initializes once.")
		else
			_LRDS_Require(Record.View.Init.Length == 1 && Record.Controller.Closed == 0
				&& Record.Settled == Record.Calls,
				"A valid navigation signal must eventually initialize the same live host once after resume.")
	} catch as Failure {
		Primary := IsObject(_LRDS.Failure) ? _LRDS.Failure : Failure
	} finally {
		if !Observed && IsSet(Record) && IsSet(Safety) {
			try _LRNS_Report(Record, Safety)
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		Suspend(false)
		Critical("Off")
		try {
			for Item in _LRNS.SafetyRecords
				Item.Host.Close()
			for Window in _LRDS.Windows
				Window.Destroy()
			for Item in _LRDS.Records {
				Started := A_TickCount
				while Item.InFlight && TickElapsed(Started) < 1000
					Sleep(5)
				_LRDS_Require(!Item.InFlight && Item.Settled == Item.Calls
					&& Item.Controller.Closed == 1 && Item.Controller.ActiveAtClose == 0
					&& Item.Host.ResetDone && !Item.Host.BuildActive,
					"Every real host must retire its callbacks and own subscriptions before observer release.")
				Item.Host.DeleteProp("_DispatchReady")
				Item.Dispatch := 0
			}
			for Item in _LRNS.SafetyRecords {
				_LRDS_Require(!Item.InFlight && Item.Settled == Item.Calls && !Item.Host.SafetyTimer,
					"The genuine host teardown must cancel its exact remaining safety callback.")
				Item.Host.DeleteProp("_SafetyFlush")
				Item.Observer := 0
			}
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if FactoryInstalled {
				try WebViewHost.Prototype.DefineProp("_CreateController", {Call: _LRNS.Factory})
				catch as Failure {
					if !IsObject(Primary)
						Primary := Failure
				}
			}
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
	FileAppend("PASS layer-navigation-pause " . _LRDS.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_LRNS_Main()
