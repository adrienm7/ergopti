; tests/fixtures/model_browser_startup_owner_body.ahk

; ==============================================================================
; MODULE: Native Model Browser Startup Ownership Child
; DESCRIPTION:
; Runs the real public constructor and native Close event with exact callback
; forwarding. Browser interfaces are passive acquisition boundaries, not fake
; lifecycle decisions. No controller is installed by the fixture.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MBSW := {Mode: A_Args[1], Windows: [], Created: 0, CloseEvents: 0, NativeClose: 0, PublicReturned: false, EpochAfter: 0, Environments: 0, Fired: false, Closed: 0, Subscriptions: 0, Navigated: 0, Filled: 0, CloseWhileSubscribed: false, EarlyClose: false, ClosePosted: false, TeardownReopened: false}
global _VendorDir := A_Args[2]
global _SharedDir := A_Args[3]
global _I18nLocale := "fr"
; A passive selected-model projection does not grant backend/config currency.
global _LLM_Menu := Map("model", "")
t(Key) => Key
LoggerError(*) => 0
LoggerWarn(*) => 0
WebView_ShouldUseNativeFallback() => false
WebView_SharedEnvironment(Loader) {
	global _MBSW
	_MBSW.Environments += 1
	_MBSW_Withdraw("environment")
	return {_MBSW_Passive: true}
}
_MBSW_Withdraw(Boundary) {
	global _MBSW
	if _MBSW.Mode != Boundary || _MBSW.Fired
		return
	_MBSW.Fired := true
	DllCall("User32\PostMessageW", "Ptr", _MBSW.Windows[1].Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int")
	Started := A_TickCount
	while _MBSW.CloseEvents == 0 && A_TickCount - Started < 1000
		Sleep(1)
	if _MBSW.CloseEvents != 1
		throw Error("Unqualified: boundary must pump genuine native Close")
}

Gui_Create(Options := "", Title := "") {
	global _MBSW
	local Window := Gui(Options, Title)
	_MBSW.Windows.Push(Window)
	if _MBSW.Windows.Length > (_MBSW.Mode == "reopen" || _MBSW.Mode == "teardown-reopen" ? 2 : 1)
		throw Error("A retired browser opening must not create an unrequested native fallback")
	if _MBSW.Windows.Length == 1
		_MBSW.Hwnd := Window.Hwnd
	Register := Gui.Prototype.OnEvent.Bind(Window)
	Window.DefineProp("OnEvent", {Call: _MBSW_RegisterEvent.Bind(Register)})
	return Window
}
_MBSW_RegisterEvent(Register, Window, Name, Callback, Options*) {
	if Name == "Close"
		return Register.Call(Name, _MBSW_ObserveClose.Bind(Callback), Options*)
	return Register.Call(Name, Callback, Options*)
}
_MBSW_ObserveClose(Callback, Params*) {
	global _MBSW, _LLM_MBW_SessionEpoch
	Critical("On")
	_MBSW.CloseEvents += 1
	_MBSW.EarlyClose := !_MBSW.PublicReturned && _MBSW.Created == 0 && _MBSW.Environments == 0
	local Result := Callback.Call(Params*)
	_MBSW.EpochAfter := _LLM_MBW_SessionEpoch
	_MBSW.ExistsAfter := DllCall("User32\IsWindow", "Ptr", _MBSW.Hwnd, "Int")
	if _MBSW.Mode == "reopen" {
		_MBSW.Successor := LLM_ModelBrowser_Show()
		_MBSW.SuccessorEpoch := _LLM_MBW_SessionEpoch
	}
	return Result
}
_MBSW_ShowMessage(WParam, LParam, Message, Hwnd) {
	global _MBSW
	if (_MBSW.Mode == "close" || _MBSW.Mode == "reopen") && WParam && _MBSW.Windows.Length && Hwnd == _MBSW.Hwnd && !_MBSW.ClosePosted {
		_MBSW.ClosePosted := true
		DllCall("User32\PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int")
	}
}
_MBSW_CloseMessage(WParam, LParam, Message, Hwnd) {
	global _MBSW
	if _MBSW.Windows.Length && Hwnd == _MBSW.Hwnd
		_MBSW.NativeClose += 1
}
class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		global _MBSW
		_MBSW.Created += 1
		_MBSW_Withdraw("factory")
		return _MBSW_PassiveController()
	}
}
class _MBSW_PassiveController {
	__New() {
		this.View := _MBSW_PassiveView()
	}
	CoreWebView2 {
		get {
			_MBSW_Withdraw("view")
			return this.View
		}
	}
	Fill() {
		global _MBSW
		_MBSW.Filled += 1
		_MBSW_Withdraw("fill")
	}
	Close() {
		global _MBSW
		_MBSW.Closed += 1
		if _MBSW.Subscriptions {
			_MBSW.CloseWhileSubscribed := true
			throw Error("The actual subscription must retire before its controller closes")
		}
		if _MBSW.Mode == "teardown-reopen" && !_MBSW.TeardownReopened {
			_MBSW.TeardownReopened := true
			_MBSW.Successor := LLM_ModelBrowser_Show()
			_MBSW.SuccessorEpoch := _LLM_MBW_SessionEpoch
		}
	}
}
class _MBSW_PassiveView {
	Settings {
		get {
			_MBSW_Withdraw("settings")
			return {}
		}
	}
	WebMessageReceived(Callback) {
		Subscription := _MBSW_PassiveSubscription()
		_MBSW_Withdraw("subscription")
		return Subscription
	}
	SetVirtualHostNameToFolderMapping(*) => _MBSW_Withdraw("mapping")
	AddScriptToExecuteOnDocumentCreated(*) => _MBSW_Withdraw("seed")
	Navigate(*) {
		global _MBSW
		_MBSW.Navigated += 1
		_MBSW_Withdraw("navigation")
	}
}
class _MBSW_PassiveSubscription {
	__New() {
		global _MBSW
		_MBSW.Subscriptions += 1
	}
	__Delete() {
		global _MBSW
		_MBSW.Subscriptions -= 1
	}
}
OnMessage(0x18, _MBSW_ShowMessage)
OnMessage(0x10, _MBSW_CloseMessage)
try {
	PublicResult := LLM_ModelBrowser_Show()
	if _MBSW.Mode == "reuse" {
		Reused := LLM_ModelBrowser_Show()
		if Reused != PublicResult || _MBSW.Windows.Length != 1 || _MBSW.Created != 1
			throw Error("A repeated public opening must retain its exact native/controller owners")
	}
	_MBSW.PublicReturned := true
	Exists := DllCall("User32\IsWindow", "Ptr", _MBSW.Hwnd, "Int")
	FileAppend("receipt mode=" . _MBSW.Mode . " native_close=" . _MBSW.NativeClose . " close_events=" . _MBSW.CloseEvents . " constructors=" . _MBSW.Created . " exists=" . Exists . " visible=" . DllCall("User32\IsWindowVisible", "Ptr", _MBSW.Hwnd, "Int") . " epoch=" . _LLM_MBW_SessionEpoch . "`n", "*", "UTF-8")
	if (_MBSW.Mode == "close" || _MBSW.Mode == "reopen") && !_MBSW.EarlyClose
		throw Error("Unqualified: the native Show close must precede every browser callout/public return")
	if _MBSW.Mode == "teardown-reopen" {
		_MBSW_Withdraw("teardown-reopen")
		FileAppend("after-teardown native_close=" . _MBSW.NativeClose . " close_events=" . _MBSW.CloseEvents . " windows=" . _MBSW.Windows.Length . " constructors=" . _MBSW.Created . " closed=" . _MBSW.Closed . " subscriptions=" . _MBSW.Subscriptions . " epoch=" . _LLM_MBW_SessionEpoch . "`n", "*", "UTF-8")
		if _MBSW.Windows.Length != 2 || _MBSW.Created != 2 || _MBSW.Closed != 1 || _MBSW.Subscriptions != 1
			|| _MBSW.CloseWhileSubscribed || _LLM_MBW_Gui != _MBSW.Successor || _LLM_MBW_SessionEpoch != _MBSW.SuccessorEpoch
			throw Error("Retiring native/controller owners must preserve their exact public successor")
	} else if _MBSW.Mode == "reopen" {
		if _MBSW.Windows.Length != 2 || _MBSW.Created != 1 || _LLM_MBW_Gui != _MBSW.Successor || _LLM_MBW_SessionEpoch != _MBSW.SuccessorEpoch
			throw Error("Old native opening must preserve its exact reentrant successor")
	} else if _MBSW.Mode != "current" && _MBSW.Mode != "reuse" {
		if _MBSW.NativeClose != 1 || _MBSW.CloseEvents != 1
			throw Error("Unqualified: actual native Close must execute once")
		if Exists || _MBSW.Created != (_MBSW.Mode == "close" || _MBSW.Mode == "environment" ? 0 : 1)
			throw Error("The native Close must retire its exact host before browser construction resumes")
		if IsSet(_LLM_MBW_Gui) || IsSet(_LLM_MBW_Controller) || IsSet(_LLM_MBW_WebView) || IsSet(_LLM_MBW_MsgSub)
			|| _LLM_MBW_Queue.Length != 0 || _LLM_MBW_Ready || !_LLM_MBW_ResetDone
			throw Error("A retired public opening must retain no global browser resource")
		if _MBSW.Closed != _MBSW.Created || _MBSW.Subscriptions != 0 || _MBSW.CloseWhileSubscribed
			throw Error("Every retired controller closes once after releasing its subscription")
	} else {
		if !Exists || _MBSW.Created != 1 || _MBSW.Subscriptions != 1 || _MBSW.Navigated != 1 || _MBSW.Filled != 1
			throw Error("An admitted public opening must create one live host/controller")
		_MBSW_Withdraw(_MBSW.Mode)
		if IsSet(_LLM_MBW_Gui) || _MBSW.Closed != 1 || _MBSW.Subscriptions != 0 || _MBSW.CloseWhileSubscribed
			throw Error("A complete admitted browser must close its exact native/controller owners")
	}
	FileAppend("PASS model-show " . _MBSW.Mode . "`n", "*", "UTF-8")
	ExitCode := 0
} catch Any as Failure {
	FileAppend(Type(Failure) . ": " . Failure.Message . "`n", "*", "UTF-8")
	ExitCode := 1
} finally {
	for CleanupWindow in _MBSW.Windows
		try CleanupWindow.Destroy()
}

ExitApp(ExitCode)
