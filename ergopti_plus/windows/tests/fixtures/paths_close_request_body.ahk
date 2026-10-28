; tests/fixtures/paths_close_request_body.ahk

; ==============================================================================
; MODULE: Paths Editor Request During Native Retirement Child
; DESCRIPTION:
; The actual public editor and its native Close callback run unchanged. A real
; WM_DESTROY observer can issue one public request while Close is in flight;
; verification happens in a continuation after the exact callback returns.
; No interruption waits for the native Close stack it interrupted.
; ==============================================================================

#Requires AutoHotkey v2.0

_PCRS_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

t(Key) => Key
LoggerSuccess(*) => 0
LoggerError(*) => 0
LoggerWarn(*) => 0
LoggerDebug(*) => 0
WebView_SharedEnvironment(Loader) => { Passive: true }

; Only the UI factory is a presentation port. The returned object is an actual
; Gui, and every registration still reaches the canonical native OnEvent method.
Gui_Create(Options := "", Title := "") {
	global _PCRS
	Window := Gui(Options, Title)
	_PCRS.Windows.Push(Window), _PCRS.Hwnds.Push(Window.Hwnd)
	Window.DefineProp("OnEvent", {Call: _PCRS_Register})
	return Window
}

_PCRS_Register(Window, Name, Callback, Options*) {
	global _PCRS
	if Name != "Close"
		return Gui.Prototype.OnEvent.Call(Window, Name, Callback, Options*)
	Record := 0
	for Existing in _PCRS.Records {
		if Existing.Window == Window && Existing.Callback == Callback {
			Record := Existing
			break
		}
	}
	if !IsObject(Record) {
		_PCRS_Require(Options.Length == 0 || Options[1] != 0,
			"An event cannot be removed before its genuine callback registration was observed.")
		Record := {Window: Window, Callback: Callback, Calls: 0, InFlight: false, Returned: false, Wrapper: 0}
		Record.Wrapper := _PCRS_InvokeClose.Bind(Record)
		_PCRS.Records.Push(Record)
	}
	return Gui.Prototype.OnEvent.Call(Window, Name, Record.Wrapper, Options*)
}

_PCRS_InvokeClose(Record, Params*) {
	global _PCRS
	Record.Calls += 1
	Record.InFlight := true
	try {
		_PCRS_Require(_PCRS.Cleanup || Record.Calls == 1,
			"The actual native event callback must be delegated exactly once for this Close.")
		Result := Record.Callback.Call(Params*)
		Record.Returned := true
	} catch as Failure {
		if !IsObject(_PCRS.Failure)
			_PCRS.Failure := Failure
		throw
	} finally {
		Record.InFlight := false
		if !_PCRS.Cleanup && _PCRS.Records.Length && Record == _PCRS.Records[1] {
			_PCRS.AfterArms += 1
			SetTimer(_PCRS_AfterClose, -1)
		}
	}
	if IsSet(Result)
		return Result
}

_PCRS_OnDestroy(WParam, LParam, Message, Hwnd) {
	global _PCRS
	; A numeric HWND can be reused later. Only this exact original callback's
	; active lifetime admits the observation, not a cached HWND match alone.
	if _PCRS.Cleanup || _PCRS.Records.Length == 0 || Hwnd != _PCRS.Hwnds[1]
		return
	Record := _PCRS.Records[1]
	if !Record.InFlight || Record.Returned
		return
	try {
		_PCRS_Require(Message == 0x2 && Record.Window == _PCRS.Windows[1],
			"The actual WM_DESTROY must target the original native editor inside its production Close.")
		_PCRS.DestroySeen += 1
		_PCRS_Require(_PCRS.DestroySeen == 1, "The original window must issue one native destruction notification.")
		if _PCRS.Mode == "during-close" {
			_PCRS.RequestInsideClose := true
			_PCRS.PublicCalls += 1
			FilePathsEditor()
			_PCRS.RequestReturned := true
		}
	} catch as Failure {
		if !IsObject(_PCRS.Failure)
			_PCRS.Failure := Failure
	}
	; An empty result preserves normal Windows destruction processing.
	return
}

_PCRS_AfterClose() {
	global _PCRS
	try {
		_PCRS.AfterCalls += 1
		Record := _PCRS.Records[1]
		_PCRS_Require(_PCRS.AfterCalls == 1 && Record.Returned && !Record.InFlight
			&& Record.Calls == 1 && _PCRS.DestroySeen == 1,
			"This continuation must execute only after the genuine callback returned once.")
		_PCRS_Require(_PCRS_Hwnd(_PCRS.Windows[1]) == 0,
			"The retired Gui object must no longer own a native HWND before the continuation.")
		if _PCRS.Mode == "after-close" {
			_PCRS.PublicCalls += 1
			FilePathsEditor()
			_PCRS.RequestReturned := true
		}
		_PCRS.AfterObserved := true
	} catch as Failure {
		if !IsObject(_PCRS.Failure)
			_PCRS.Failure := Failure
	}
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		global _PCRS
		_PCRS_Require(!IsSet(Callback) && Environment.Passive
			&& DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
			"Only the existing browser constructor is passive, after a genuine native placeholder.")
		Controller := _PCRS_Controller()
		_PCRS.Controllers.Push(Controller)
		return Controller
	}
}

class _PCRS_View {
	__New() {
		this.Settings := {}, this.Subscriptions := 0, this.Active := 0, this.Navigations := 0
	}
	WebMessageReceived(Callback) => _PCRS_Subscription(this, Callback)
	NavigationCompleted(Callback) => _PCRS_Subscription(this, Callback)
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
}

class _PCRS_Subscription {
	__New(View, Callback) {
		this.View := View, this.Callback := Callback
		View.Subscriptions += 1, View.Active += 1
	}
	__Delete() {
		this.View.Active -= 1
	}
}

class _PCRS_Controller {
	__New() {
		this.CoreWebView2 := _PCRS_View(), this.Closed := 0, this.Fills := 0, this.ActiveAtClose := -1
	}
	Close() {
		this.Closed += 1
		this.ActiveAtClose := this.CoreWebView2.Active
	}
	Fill() {
		this.Fills += 1
	}
}

_PCRS_Hwnd(Window) {
	try return Window.Hwnd
	return 0
}

_PCRS_Ready(Index) {
	global _PCRS, _PathsEdWeb_Gui, _PathsEdWeb_Controller, _PathsEdWeb_WebView
	global _PathsEdWeb_MsgSub, _PathsEdWeb_NavSub, _PathsEdWeb_ResetDone
	if _PCRS.Windows.Length < Index || _PCRS.Controllers.Length < Index
		return false
	return _PathsEdWeb_Gui == _PCRS.Windows[Index]
		&& IsSet(_PathsEdWeb_Controller) && _PathsEdWeb_Controller == _PCRS.Controllers[Index]
		&& IsSet(_PathsEdWeb_WebView) && _PathsEdWeb_WebView == _PCRS.Controllers[Index].CoreWebView2
		&& IsSet(_PathsEdWeb_MsgSub) && IsSet(_PathsEdWeb_NavSub) && !_PathsEdWeb_ResetDone
		&& _PCRS.Controllers[Index].CoreWebView2.Active == 2
		&& _PCRS.Controllers[Index].CoreWebView2.Navigations == 1 && _PCRS.Controllers[Index].Fills > 0
		&& DllCall("User32\IsWindowVisible", "Ptr", _PCRS_Hwnd(_PCRS.Windows[Index]), "Int")
}

_PCRS_OnError(Failure, Mode) {
	global _PCRS
	if !IsObject(_PCRS.Failure)
		_PCRS.Failure := Failure is Error ? Failure : Error("An asynchronous paths retirement failure was observed.")
	try FileAppend("DIAG paths-close-request async type=" . Type(Failure) . " mode=" . Mode . "`n", "*", "UTF-8")
	return true
}

_PCRS_Observe() {
	global _PCRS, _PathsEdWeb_SessionEpoch
	FileAppend("RECEIPT paths-close-request mode=" . _PCRS.Mode
		. " public_calls=" . _PCRS.PublicCalls . " destroy_seen=" . _PCRS.DestroySeen
		. " close_calls=" . _PCRS.Records[1].Calls . " close_returned=" . _PCRS.Records[1].Returned
		. " close_inflight=" . _PCRS.Records[1].InFlight . " request_inside=" . _PCRS.RequestInsideClose
		. " request_returned=" . _PCRS.RequestReturned . " after_arms=" . _PCRS.AfterArms
		. " after_calls=" . _PCRS.AfterCalls . " after_observed=" . _PCRS.AfterObserved
		. " windows=" . _PCRS.Windows.Length . " controllers=" . _PCRS.Controllers.Length
		. " successor_ready=" . _PCRS_Ready(2) . " epoch=" . _PathsEdWeb_SessionEpoch
		. " boundary_failure=" . IsObject(_PCRS.Failure) . "`n", "*", "UTF-8")
}

_PCRS_Main() {
	global _PCRS, _VendorDir, _SharedDir, _ConfigDir, _PathsFile, _PathsEdWeb_SessionEpoch
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	_PCRS := {Mode: A_Args[1], Windows: [], Hwnds: [], Controllers: [], Records: [], Failure: 0,
		Cleanup: false, PublicCalls: 0, DestroySeen: 0, AfterArms: 0, AfterCalls: 0, AfterObserved: false,
		RequestInsideClose: false, RequestReturned: false}
	_VendorDir := A_Args[2], _SharedDir := A_Args[2] . "\shared"
	_ConfigDir := A_Args[2] . "\config\", _PathsFile := A_Args[2] . "\paths.toml"
	Primary := 0, Observed := false
	OnError(_PCRS_OnError)
	OnMessage(0x2, _PCRS_OnDestroy, 1)
	try {
		_PCRS.PublicCalls += 1
		FilePathsEditor()
		_PCRS_Require(_PCRS.Windows.Length == 1 && _PCRS.Controllers.Length == 1
			&& _PCRS.Records.Length == 1 && _PCRS_Ready(1),
			"The genuine public seed must create one current native host and its browser publication.")
		Epoch := _PathsEdWeb_SessionEpoch
		Hwnd := _PCRS.Hwnds[1]
		DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		; Main, not an interrupting observer, pumps both the real Close and its
		; later continuation. A deferred legitimate reopen can settle normally.
		while !IsObject(_PCRS.Failure) && (!_PCRS.AfterObserved || !_PCRS_Ready(2))
			&& TickElapsed(Started) < 3000
			Sleep(10)
		_PCRS_Observe(), Observed := true
		if IsObject(_PCRS.Failure)
			throw _PCRS.Failure
		_PCRS_Require(_PCRS.DestroySeen == 1 && _PCRS.Records[1].Returned
			&& !_PCRS.Records[1].InFlight && _PCRS.Records[1].Calls == 1
			&& _PCRS.AfterArms == 1 && _PCRS.AfterCalls == 1 && _PCRS.AfterObserved,
			"A missing native destruction or after-return continuation is a prerequisite failure.")
		_PCRS_Require(_PCRS.PublicCalls == 2 && _PCRS.RequestReturned
			&& _PCRS.RequestInsideClose == (_PCRS.Mode == "during-close"),
			"The two modes must distinguish a real request inside retirement from one after return.")
		_PCRS_Require(_PCRS_Ready(2) && _PCRS.Windows.Length == 2 && _PCRS.Controllers.Length == 2
			&& _PathsEdWeb_SessionEpoch > Epoch,
			"A genuine public request cannot disappear after the actual Close has returned and deferred work has pumped.")
		_PCRS_Require(_PCRS.Controllers[1].Closed == 1 && _PCRS.Controllers[1].ActiveAtClose == 0,
			"The original browser must retire once after unsubscribing its own passive tokens.")
		DllCall("User32\SendMessageW", "Ptr", _PCRS_Hwnd(_PCRS.Windows[2]), "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while !_PCRS.Records[2].Returned && TickElapsed(Started) < 1000
			Sleep(10)
		_PCRS_Require(_PCRS.Records[2].Returned && _PCRS.Records[2].Calls == 1
			&& _PCRS_Hwnd(_PCRS.Windows[2]) == 0 && _PCRS.Controllers[2].Closed == 1,
			"The accepted successor remains independently closable through the same native handler.")
	} catch as Failure {
		Primary := IsObject(_PCRS.Failure) ? _PCRS.Failure : Failure
	} finally {
		if !Observed && _PCRS.Controllers.Length > 0 && _PCRS.Records.Length > 0 {
			try _PCRS_Observe()
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		_PCRS.Cleanup := true
		SetTimer(_PCRS_AfterClose, 0)
		OnMessage(0x2, _PCRS_OnDestroy, 0)
		try {
			_PathsEdWeb_Close()
			for Controller in _PCRS.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Window in _PCRS.Windows
				Window.Destroy()
			for Window in _PCRS.Windows
				_PCRS_Require(_PCRS_Hwnd(Window) == 0, "Every exact owned Gui must retire without relying on an old HWND number.")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		for Record in _PCRS.Records
			Record.Callback := 0, Record.Wrapper := 0, Record.Window := 0
		_PCRS.Records.Length := 0
		OnError(_PCRS_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_PCRS.Failure)
		Primary := _PCRS.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS paths-close-request " . _PCRS.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_PCRS_Main()
