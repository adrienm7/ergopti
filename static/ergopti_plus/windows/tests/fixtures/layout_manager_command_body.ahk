; tests/fixtures/layout_manager_command_body.ahk

; ==============================================================================
; MODULE: Layout Manager Queued Command Child
; DESCRIPTION:
; Genuine SDK registrations deliver messages to the complete real host. Its
; native timers are transparently observed, including exact cancellation. Only
; browser COM is passive; native Gui, Suspend, catalogue files and resume stay
; real. Held scheduling and direct production Close are explicit controls.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMCS_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

t(Key) => Key
WindowTitle(Label := "") => Label

Gui_Create(Options := "", Title := "") {
	global _LMCS
	Window := Gui(Options, Title)
	_LMCS.Windows.Push(Window)
	return Window
}

class WebView2 {
	static CreateEnvironmentAsync(BrowserFolder, UserDataFolder, Options, Loader) {
		global _LMCS, WEBVIEW_SHARED_UDIR
		_LMCS_Require(BrowserFolder == 0 && UserDataFolder == WEBVIEW_SHARED_UDIR
			&& UserDataFolder == A_Args[2] . "\profile" && Options == ""
			&& Loader == A_Args[2] . "\64bit\WebView2Loader.dll",
			"Only the exact private passive environment may be acquired.")
		_LMCS.Environments += 1
		Resolved := Promise.withResolvers()
		Resolved.resolve.Call({Passive: true})
		return Resolved.promise
	}
	static create(Hwnd, Callback?, Environment := 0) {
		global _LMCS
		_LMCS_Require(!IsSet(Callback) && Environment.Passive
			&& DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
			"The browser port requires the actual native placeholder.")
		Controller := _LMCS_Controller()
		_LMCS.Controllers.Push(Controller)
		return Controller
	}
}

class _LMCS_Settled {
	onSettled(Success, Failure) => Success.Call("")
}

class _LMCS_Subscription {
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

class _LMCS_View {
	__New() {
		this.Settings := {}, this.Callbacks := Map(), this.Active := 0
		this.Scripts := [], this.Init := [], this.States := [], this.Navigations := 0
	}
	WebMessageReceived(Callback) => _LMCS_Subscription(this, "message", Callback)
	NavigationCompleted(Callback) => _LMCS_Subscription(this, "navigation", Callback)
	SetVirtualHostNameToFolderMapping(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
	ExecuteScriptAsync(Js) {
		this.Scripts.Push(Js)
		for Name in ["initData", "updateState"] {
			Prefix := "if(window." . Name . ")window." . Name . "("
			if SubStr(Js, 1, StrLen(Prefix)) != Prefix
				continue
			_LMCS_Require(SubStr(Js, -1) == ")", "The genuine page projection requires its complete JSON envelope.")
			Data := JsonParse(SubStr(Js, StrLen(Prefix) + 1, StrLen(Js) - StrLen(Prefix) - 1))
			_LMCS_Require(Data is Map, "The actual layout page projection must be a JSON object.")
			if Name == "initData"
				this.Init.Push(Data)
			else
				this.States.Push(Data)
		}
		return _LMCS_Settled()
	}
}

class _LMCS_Controller {
	__New() {
		this.CoreWebView2 := _LMCS_View(), this.Closed := 0, this.Fills := 0, this.ActiveAtClose := -1
	}
	Close() {
		this.Closed += 1
		this.ActiveAtClose := this.CoreWebView2.Active
	}
	Fill() {
		this.Fills += 1
	}
}

class _LMCS_Message {
	__New(Text) {
		this.Text := Text, this.Reads := 0
	}
	TryGetWebMessageAsString() {
		this.Reads += 1
		return this.Text
	}
}

; Only actual builtin SetTimer tokens in the complete authenticated host are
; overlaid. Both arm and cancel use the same wrapper for the exact callback.
; Neither callback shape nor its bound arguments are inspected or changed.
_LMCS_SetTimer(Callback, Period?, Priority?) {
	global _LMCS
	if !_LMCS.Timers.Has(Callback) {
		Record := {Callback: Callback, Phase: _LMCS.Phase, Calls: 0, Settled: 0,
			InFlight: false, Paused: false, Cancels: 0, Arms: 0, Operations: []}
		Record.Wrapper := _LMCS_Deliver.Bind(Record)
		_LMCS.Timers[Callback] := Record
	}
	Record := _LMCS.Timers[Callback]
	Operation := {HasPeriod: IsSet(Period), HasPriority: IsSet(Priority)}
	if IsSet(Period)
		Operation.Period := Period
	if IsSet(Priority)
		Operation.Priority := Priority
	if !IsSet(Priority)
		SetTimer(Record.Wrapper, Period?)
	else
		SetTimer(Record.Wrapper, Period?, Priority)
	Record.Operations.Push(Operation)
	if IsSet(Period) && Period == 0
		Record.Cancels += 1
	else
		Record.Arms += 1
}

_LMCS_Deliver(Record) {
	global _LMCS
	Record.Calls += 1, Record.InFlight := true, Record.Paused := A_IsSuspended
	try Record.Callback.Call()
	catch as Failure {
		if !IsObject(_LMCS.Failure)
			_LMCS.Failure := Failure
		throw
	} finally {
		Record.InFlight := false
		Record.Settled += 1
	}
}

_LMCS_Open() {
	global _LMCS, _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_WebView, _LayMgrWeb_SessionEpoch
	_LMCS_Require(LayoutManager_Open(), "The genuine public layout manager must open.")
	Record := {Window: _LayMgrWeb_Gui, Controller: _LayMgrWeb_Controller,
		View: _LayMgrWeb_WebView, Epoch: _LayMgrWeb_SessionEpoch}
	_LMCS_Require(Record.Window == _LMCS.Windows[_LMCS.Windows.Length]
		&& Record.Controller == _LMCS.Controllers[_LMCS.Controllers.Length]
		&& Record.View == Record.Controller.CoreWebView2 && Record.View.Active == 2
		&& Record.View.Navigations == 1 && Record.Controller.Fills > 0,
		"The real public constructor must publish its exact native and SDK owner.")
	_LMCS.Records.Push(Record)
	return Record
}

_LMCS_Send(Record, Action) {
	global _LMCS
	_LMCS_Require(Record.View.Callbacks.Has("message"), "Only a genuine registered SDK callback may produce commands.")
	Args := _LMCS_Message(_LayMgrWeb_Json(Map("action", Action, "id", _LMCS.Id)))
	Record.View.Callbacks["message"].Call(Record.View, Args)
	_LMCS_Require(Args.Reads == 1, "The real SDK producer must read and parse the actual JSON message once.")
}

_LMCS_CommandRecord() {
	global _LMCS
	Found := []
	for Callback, Record in _LMCS.Timers
		if Record.Phase == "command"
			Found.Push(Record)
	_LMCS_Require(Found.Length == 1 && Found[1].Arms == 1 && Found[1].Operations.Length > 0,
		"The genuine unpaused SDK command must arm exactly one native callback.")
	First := Found[1].Operations[1]
	_LMCS_Require(First.HasPeriod && First.Period == -1 && !First.HasPriority,
		"The concrete producer must retain its actual one-shot period and omitted priority.")
	return Found[1]
}

_LMCS_Pump(Command) {
	global _LMCS
	Started := A_TickCount
	while !IsObject(_LMCS.Failure) && Command.Settled == 0 && Command.Cancels == 0 && TickElapsed(Started) < 3000
		Sleep(5)
	if IsObject(_LMCS.Failure)
		throw _LMCS.Failure
	_LMCS_Require((Command.Cancels > 0 || Command.Calls > 0)
		&& Command.Settled == Command.Calls && !Command.InFlight,
		"Before cleanup the actual command timer must have returned or been genuinely cancelled.")
}

_LMCS_Pulse(Record) {
	Record.Calls += 1
}

_LMCS_Opportunity() {
	global _LMCS
	Record := {Calls: 0}, Pulse := _LMCS_Pulse.Bind(Record), Started := A_TickCount
	try {
		SetTimer(Pulse, -1)
		while (Record.Calls == 0 || TickElapsed(Started) < 100) && TickElapsed(Started) < 1000
			Sleep(5)
		_LMCS_Require(Record.Calls == 1, "A real native timer opportunity must precede the no-replay oracle.")
		if IsObject(_LMCS.Failure)
			throw _LMCS.Failure
	} finally SetTimer(Pulse, 0)
}

_LMCS_Resume() {
	global _LMCS, _LifecycleLatestTransition, _LLM_MenuBuildCoordinator
	Suspend(false)
	_LMCS_Require(Ergopti_OnSuspendResume(), "The genuine resume reactor must finish.")
	_LMCS.Resumes += 1
	_LMCS_Require(_LifecycleLatestTransition.phase == "resume" && _LifecycleLatestTransition.finished
		&& _LifecycleLatestTransition.debt.Length == 0 && _LLM_MenuBuildCoordinator is LLMMenuBuildCoordinator,
		"The actual resume/menu service graph must be present, finished and debt-free.")
}

_LMCS_Ready(Record) {
	global _LMCS, LAYOUT_CATALOGUE_SOURCE_BUNDLED
	_LMCS.Phase := "ready"
	_LMCS_Send(Record, "ready")
	Started := A_TickCount
	while !IsObject(_LMCS.Failure) && (Record.View.Init.Length != 1 || Record.View.States.Length == 0)
		&& TickElapsed(Started) < 3000
		Sleep(5)
	if IsObject(_LMCS.Failure)
		throw _LMCS.Failure
	_LMCS_Require(Record.View.Init.Length == 1 && Record.View.States.Length > 0
		&& Record.View.Init[1]["state"]["installed"].Has(_LMCS.Id)
		&& Record.View.Init[1]["state"]["platform"] == "windows"
		&& Record.View.Init[1]["state"]["active"] == ""
		&& LayoutCatalogue_Last()["source"] == LAYOUT_CATALOGUE_SOURCE_BUNDLED,
		"Actual ready remains allowed while paused and must project the genuine private installed record and local catalogue.")
}

_LMCS_Snapshot() {
	global _LMCS
	return {Exists: !!FileExist(_LMCS.LayoutPath), Installed: LayoutCatalogue_ReadInstalled(_LMCS.LocalDir).Has(_LMCS.Id),
		Layout: FileExist(_LMCS.LayoutPath) ? FSReadStrict(_LMCS.LayoutPath) : "",
		Record: FSReadStrict(_LMCS.InstalledPath)}
}

_LMCS_Log(Line) {
	global _LMCS
	if InStr(Line, "[ERROR]") && !IsObject(_LMCS.Failure)
		_LMCS.Failure := Error("The actual SDK/catalogue/resume path emitted an error before its business oracle.")
}

_LMCS_OnError(Failure, Mode) {
	global _LMCS
	if !IsObject(_LMCS.Failure)
		_LMCS.Failure := Failure is Error ? Failure : Error("An asynchronous layout command failed.")
	try FileAppend("DIAG layout-manager-command async type=" . Type(Failure) . " mode=" . Mode . "`n", "*", "UTF-8")
	return true
}

_LMCS_Report(Command) {
	global _LMCS, _LayMgrWeb_SessionEpoch, _LayMgrWeb_Gui
	Snapshot := _LMCS_Snapshot()
	FileAppend("RECEIPT layout-manager-command mode=" . _LMCS.Mode . " delivery=" . Command.Calls
		. " settled=" . Command.Settled . " paused=" . Command.Paused . " cancel=" . Command.Cancels
		. " ready_while_paused=" . _LMCS.ReadyWhilePaused
		. " before_resume_exists=" . (HasProp(_LMCS, "BeforeResume") ? _LMCS.BeforeResume.Exists : -1)
		. " before_resume_installed=" . (HasProp(_LMCS, "BeforeResume") ? _LMCS.BeforeResume.Installed : -1)
		. " arms=" . Command.Arms . " resumes=" . _LMCS.Resumes . " file_exists=" . Snapshot.Exists
		. " installed=" . Snapshot.Installed . " layout_raw_equal=" . (Snapshot.Layout == _LMCS.Before.Layout)
		. " record_raw_equal=" . (Snapshot.Record == _LMCS.Before.Record)
		. " epoch=" . _LayMgrWeb_SessionEpoch . " windows=" . _LMCS.Windows.Length
		. " controllers=" . _LMCS.Controllers.Length . " boundary_failure=" . IsObject(_LMCS.Failure)
		. " native_suspended=" . A_IsSuspended . "`n", "*", "UTF-8")
}

_LMCS_Main() {
	global _LMCS, _VendorDir, _SharedDir, _StaticDir, _ConfigDir, WEBVIEW_SHARED_UDIR, _DriverDir
	global Features, CategoryEnabled, TapHold, _HotstringExtensionPacks, _LLM_Menu
	global _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_WebView, _LayMgrWeb_SessionEpoch
	global _LayMgrWeb_RuntimeRefresh, _LayMgrWeb_Result
	if A_Args.Length != 3
		ExitApp(2)
	Persistent(true)
	_LMCS := {Mode: A_Args[1], Windows: [], Controllers: [], Records: [], Timers: Map(), Phase: "setup",
		Failure: 0, Environments: 0, Resumes: 0, ReadyWhilePaused: false, Id: "ergol"}
	OnError(_FeatureStateSmokeFatal, 0)
	OnError(_LMCS_OnError)
	LoggerSetTestSink(_LMCS_Log)
	_VendorDir := A_Args[2], WEBVIEW_SHARED_UDIR := A_Args[2] . "\profile"
	_SharedDir := A_Args[3], _ConfigDir := A_Args[2] . "\config\", _StaticDir := _DriverDir . "\..\.."
	Features := Map("layout", Map("ergopti_base", false, "emulated_layout", "", "direct_access_digits", "native",
		"number_row_reorder_edges", false, "emulate_number_row", false,
		"emulate_top_row", false, "emulate_home_row", false, "emulate_bottom_row", false))
	CategoryEnabled := Map("Layout", false), TapHold := Map("keys", Map()), _HotstringExtensionPacks := []
	Primary := 0, Command := 0, Observed := false, InheritedCritical := A_IsCritical
	try {
		_LMCS_Require(!A_IsCompiled && Updater_IsLocalSource(), "The genuine refresh must take its source-mode local branch.")
		_LMCS.LocalDir := LayoutRegistry_LocalDir(_ConfigDir)
		DirCreate(_LMCS.LocalDir)
		Bundled := LayoutRegistry_ReadBundled(_LMCS.Id, LayoutRegistry_BundledDir())
		_LMCS.LayoutPath := _LMCS.LocalDir . _LMCS.Id . ".keylayout"
		_LMCS.InstalledPath := _LMCS.LocalDir . LayoutRegistry_Settings()["installed_file"]
		_LMCS_Require(KeylayoutEmulation_SelectedId() == ""
			&& _HotstringExtensionPacks.Length == 0,
			"Only a real unselected layout without loaded extension packs can take the genuine no-reload after branch.")
		_LMCS_Require(FSWriteCreateDurable(_LMCS.LayoutPath, Bundled["Text"]) == 1,
			"The verified bundled layout must be exclusively created inside the private root.")
		LayoutCatalogue_WriteInstalled(_LMCS.LocalDir, Map(_LMCS.Id, _LayoutCatalogueRecordEntry(Bundled["Entry"])))
		_LMCS.Before := _LMCS_Snapshot()
		_LMCS_Require(_LMCS.Before.Exists && _LMCS.Before.Installed && !_LLM_Menu["enabled"] && !_LLM_Menu["bootstrap_pending"],
			"Real installed publication and the neutral real menu must precede every command.")
		Record := _LMCS_Open()
		; Ready is intentionally admissible under pause. It is a signal, not an
		; authorization to replay any user command after a later resume.
		Suspend(true)
		_LMCS_Ready(Record)
		_LMCS.ReadyWhilePaused := A_IsSuspended && Record.View.Init.Length == 1
		_LMCS_Resume()
		HeldCritical := Critical("On")
		try {
			_LMCS.Phase := "command"
			_LMCS_Send(Record, "uninstall")
			Command := _LMCS_CommandRecord()
			_LMCS_Require(Command.Calls == 0 && Command.Cancels == 0,
				"The actual unpaused SDK producer must queue before held native delivery.")
			if _LMCS.Mode == "queued-pause"
				Suspend(true)
			if _LMCS.Mode == "retired-epoch" {
				; This is an explicit real production retirement control, not a
				; claim that a WM_CLOSE can interrupt an arbitrary Critical span.
				OldHwnd := Record.Window.Hwnd
				_LayMgrWeb_Close()
				_LMCS_Require(_LayMgrWeb_SessionEpoch != Record.Epoch && Record.Controller.Closed == 1
					&& !DllCall("User32\IsWindow", "Ptr", OldHwnd, "Int"),
					"The real original owner must retire before public successor construction.")
				Successor := _LMCS_Open()
			}
		} finally Critical(HeldCritical)
		_LMCS_Pump(Command)
		PausedSnapshot := _LMCS_Snapshot()
		_LMCS.BeforeResume := PausedSnapshot
		if _LMCS.Mode == "queued-pause" {
			_LMCS_Require(Command.Cancels > 0 || Command.Paused,
				"The command must actually settle under pause or have an observed SUT cancellation.")
			Count := _LMCS.Timers.Count
			_LMCS_Send(Record, "uninstall")
			_LMCS_Require(_LMCS.Timers.Count == Count, "A command arriving already paused must be terminally refused at the real producer.")
			_LMCS_Resume()
			_LMCS_Opportunity()
		}
		if _LMCS.Mode == "retired-epoch"
			_LMCS_Ready(Successor)
		_LMCS_Report(Command), Observed := true
		if IsObject(_LMCS.Failure)
			throw _LMCS.Failure
		After := _LMCS_Snapshot()
		if _LMCS.Mode == "current-uninstall" {
			_LMCS_Require(Command.Calls == 1 && Command.Settled == 1 && !Command.Paused
				&& !After.Exists && !After.Installed && _LayMgrWeb_RuntimeRefresh == 0
				&& _LayMgrWeb_Result is Map && _LayMgrWeb_Result["ok"] == 1,
				"The actual current command must delete the private file and record through the genuine no-reload completion.")
		} else {
			_LMCS_Require(PausedSnapshot.Exists && PausedSnapshot.Installed
				&& PausedSnapshot.Layout == _LMCS.Before.Layout && PausedSnapshot.Record == _LMCS.Before.Record
				&& After.Exists && After.Installed && After.Layout == _LMCS.Before.Layout && After.Record == _LMCS.Before.Record,
				"A queued suspended or retired command must not delete, rewrite or later replay against the private layout owner.")
			if _LMCS.Mode == "retired-epoch"
				_LMCS_Require(_LayMgrWeb_Gui == Successor.Window && _LayMgrWeb_Controller == Successor.Controller
					&& _LayMgrWeb_WebView == Successor.View && _LayMgrWeb_SessionEpoch == Successor.Epoch
					&& Successor.View.Init.Length == 1 && Successor.Controller.Closed == 0,
					"The stale epoch must preserve the exact live initialized public successor.")
		}
	} catch as Failure {
		Primary := IsObject(_LMCS.Failure) ? _LMCS.Failure : Failure
	} finally {
		if !Observed && IsObject(Command) {
			try _LMCS_Report(Command)
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		Critical("On")
		try {
			; Cleanup uses the native builtin directly. Its cancellations cannot
			; count as SUT refusal or satisfy any earlier command oracle.
			for Callback, Timer in _LMCS.Timers {
				SetTimer(Timer.Wrapper, 0)
				_LMCS_Require(!Timer.InFlight, "A callback cannot be released while still in flight.")
			}
			_LayMgrWeb_Close()
			for Window in _LMCS.Windows
				Window.Destroy()
			for Item in _LMCS.Records
				_LMCS_Require(Item.Controller.Closed == 1 && Item.Controller.ActiveAtClose == 0,
					"Each exact controller must close once after its own subscriptions retire.")
			for Callback, Timer in _LMCS.Timers {
				Timer.Wrapper := 0
				Timer.Callback := 0
			}
			_LMCS.Timers.Clear()
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			Suspend(false)
			LoggerClearTestSink()
			OnError(_LMCS_OnError, 0)
			Critical(InheritedCritical)
		}
	}
	if !IsObject(Primary) && IsObject(_LMCS.Failure)
		Primary := _LMCS.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS layout-manager-command " . _LMCS.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_LMCS_Main()
