; tests/fixtures/updater/update_check_startup_owner_body.ahk

; ==============================================================================
; MODULE: Update Check Startup Owner Child
; DESCRIPTION:
; The genuine public update window and GUI close event run with the shipped
; Promise. Browser construction is passive and returns after native WM_CLOSE;
; no Edge runtime, update download or installer is exercised.
; ==============================================================================

#Requires AutoHotkey v2.0

global _UCSO := {Mode: A_Args[1], Windows: [], Controllers: [], Pending: 0,
	Boundary: 0, Failure: 0, RequestB: 0, EpochB: 0, Events: []}
global _VendorDir := A_Args[2], _I18nLocale := "en"
; The real environment getter and fallback policy take their warm-cache path.
global _WebView_SharedEnv := {Passive: true}

t(Key) => Key
_Updater_ActivateCachedRelease(*) => false

_UCSO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		global _UCSO, _UC_Gui
		_UCSO_Require(!IsSet(Callback) && Environment.Passive, "the real constructor contract must be preserved")
		Window := {gui: _UC_Gui, hwnd: _UC_Gui.Hwnd}
		_UCSO_Require(DllCall("User32\IsWindowVisible", "Ptr", Window.hwnd, "Int"),
			"the exact genuine host must be published before the browser wait")
		_UCSO_Require(DllCall("User32\GetAncestor", "Ptr", Hwnd, "UInt", 2, "Ptr") == Window.hwnd,
			"the factory placeholder must belong to the exact published GUI")
		_UCSO.Windows.Push(Window)
		Controller := _UCSO_Controller(Window.hwnd)
		_UCSO.Controllers.Push(Controller)
		if _UCSO.Mode == "startup-current-reject"
			throw Error("controlled current browser construction refusal")
		if _UCSO.Mode == "startup-current" || _UCSO.Mode == "startup-current-partial-refusal" || _UCSO.Controllers.Length > 1
			return Controller
		_UCSO.Pending := Promise.withResolvers()
		_UCSO.Pending.promise.onSettled((*) => 0, (*) => 0)
		_UCSO.Boundary := _UCSO_CloseDuringCreate
		SetTimer(_UCSO.Boundary, -1)
		return _UCSO.Pending.promise.await(3000)
	}
}

class _UCSO_Subscription {
	__New(View) {
		this.View := View
	}
	__Delete() {
		global _UCSO
		this.View.Active -= 1
		_UCSO.Events.Push("unsubscribe")
	}
}

class _UCSO_View {
	__New() {
		this.Settings := {}, this.Navigations := 0, this.Subscriptions := 0, this.Active := 0
	}
	WebMessageReceived(Callback) {
		this.Subscriptions += 1
		this.Active += 1
		return _UCSO_Subscription(this)
	}
	AddScriptToExecuteOnDocumentCreated(*) => 0
	SetVirtualHostNameToFolderMapping(*) => 0
	Navigate(*) {
		this.Navigations += 1
	}
}

class _UCSO_Controller {
	__New(Hwnd) {
		this.Hwnd := Hwnd, this._View := _UCSO_View(), this.GetterFailed := false, this.Closed := 0, this.Fills := 0, this.Attempts := 0
	}
	CoreWebView2 {
		get {
			global _UCSO
			if _UCSO.Mode == "startup-current-partial-refusal" && !this.GetterFailed {
				this.GetterFailed := true
				throw Error("controlled acquired controller view refusal")
			}
			return this._View
		}
	}
	Close() {
		global _UCSO
		_UCSO_Require(DllCall("User32\IsWindow", "Ptr", this.Hwnd, "Int"),
			"the controller must close while its genuine parent HWND still exists")
		_UCSO_Require(this.CoreWebView2.Active == 0, "subscriptions must be released before controller closure")
		this.Attempts += 1
		if (_UCSO.Mode == "startup-close-retire-refusal" || _UCSO.Mode == "startup-current-partial-refusal") && this.Attempts == 1
			throw Error("controlled first controller close refusal")
		_UCSO.Events.Push("close")
		this.Closed += 1
		_UCSO_Require(this.Closed == 1, "each returned controller closes exactly once")
	}
	Fill() {
		this.Fills += 1
	}
}

_UCSO_CloseDuringCreate() {
	global _UCSO, _UC_WindowEpoch, _UC_ResetDone
	try {
		Window := _UCSO.Windows[1], OldEpoch := _UC_WindowEpoch
		DllCall("User32\SendMessageW", "Ptr", Window.hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while _UC_WindowEpoch == OldEpoch && TickElapsed(Started) < 1000
			Sleep(10)
		_UCSO_Require(_UC_WindowEpoch > OldEpoch && _UC_ResetDone,
			"the genuine close event must revoke the old public request")
		_UCSO_Require(DllCall("User32\IsWindow", "Ptr", Window.hwnd, "Int")
			&& !DllCall("User32\IsWindowVisible", "Ptr", Window.hwnd, "Int"),
			"the pending factory keeps its old HWND alive and hidden")
		if InStr(_UCSO.Mode, "reopen") {
			_UCSO.RequestB := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
			_UCSO_Require(UpdateCheck_Begin(_UCSO.RequestB, "v1.0.0"), "the genuine public API must open B")
			_UCSO.EpochB := _UC_WindowEpoch
		}
		if InStr(_UCSO.Mode, "reject")
			_UCSO.Pending.reject.Call(Error("controlled old browser construction refusal"))
		else
			_UCSO.Pending.resolve.Call(_UCSO.Controllers[1])
	} catch Any as Failure {
		_UCSO.Failure := Failure
		_UCSO.Pending.reject.Call(Failure)
	}
}

_UCSO_OnError(Failure, *) {
	global _UCSO
	_UCSO.Failure := Failure
	return true
}

_UCSO_Main() {
	global _UCSO, _UC_Gui, _UC_Controller, _UC_WebView, _UC_MsgSub
	global _UC_ResetDone, _UC_WindowEpoch, _UC_RequestId, _UC_RetiredHosts, _UC_PendingHost, _UC_Native
	Persistent(true)
	Thread("Interrupt", 0)
	OnError(_UCSO_OnError)
	Primary := 0
	try {
		RequestA := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
		Accepted := UpdateCheck_Begin(RequestA, "v1.0.0")
		if IsObject(_UCSO.Failure)
			throw _UCSO.Failure
		if _UCSO.Mode == "startup-close-retire-refusal" || _UCSO.Mode == "startup-current-partial-refusal" {
			_UCSO_Require(!Accepted && _UC_RetiredHosts.Length == 1
				&& _UCSO.Controllers[1].Closed == 0
				&& DllCall("User32\IsWindow", "Ptr", _UCSO.Windows[1].hwnd, "Int"),
				"a refused late controller close must retain its exact HWND and cleanup record")
			_UCSO_Require(!IsSet(_UC_Gui) && !IsSet(_UC_Controller) && !IsSet(_UC_WebView)
				&& !IsSet(_UC_MsgSub) && !_UC_Native
				&& !DllCall("User32\IsWindowVisible", "Ptr", _UCSO.Windows[1].hwnd, "Int"),
				"a cleanup debt must retain no live global alias or visible fallback")
			_UCSO_Require(_UpdateCheck_CloseWindow(), "a later close must retry the retained controller")
		}
		if _UCSO.Mode == "startup-current-reject" {
			_UCSO_Require(Accepted && _UC_Native && !_UC_ResetDone && IsSet(_UC_Gui)
				&& !IsSet(_UC_Controller) && !DllCall("User32\IsWindow", "Ptr", _UCSO.Windows[1].hwnd, "Int"),
				"a current factory refusal must retire its host before constructing the native fallback")
		} else if _UCSO.Mode == "startup-current" {
			_UCSO_Require(Accepted && _UC_Controller == _UCSO.Controllers[1]
				&& _UC_WebView == _UCSO.Controllers[1].CoreWebView2 && IsSet(_UC_MsgSub),
				"a current factory must publish its exact complete resource set")
		} else {
			_UCSO_Require(!Accepted && !DllCall("User32\IsWindow", "Ptr", _UCSO.Windows[1].hwnd, "Int"),
				"late construction must refuse A and retire its exact original HWND")
			_UCSO_Require(_UCSO.Controllers[1].Closed == (InStr(_UCSO.Mode, "reject") ? 0 : 1)
				&& _UCSO.Controllers[1].CoreWebView2.Subscriptions == 0
				&& _UCSO.Controllers[1].CoreWebView2.Navigations == 0,
				"A may retire its late returned controller but cannot subscribe or navigate")
			if InStr(_UCSO.Mode, "reopen") {
				_UCSO_Require(_UC_Controller == _UCSO.Controllers[2]
					&& _UC_Gui == _UCSO.Windows[2].gui && _UC_WindowEpoch == _UCSO.EpochB
					&& _UC_RequestId == _UCSO.RequestB.RequestId && !_UC_ResetDone
					&& _UCSO.Controllers[2].Closed == 0
					&& _UCSO.Controllers[2].CoreWebView2.Subscriptions == 1
					&& _UCSO.Controllers[2].CoreWebView2.Navigations == 1,
					"late completion A must preserve every live resource and request of B")
			} else
				_UCSO_Require(_UC_ResetDone && !IsSet(_UC_Gui) && !IsSet(_UC_Controller),
					"closed A must not resurrect a native fallback or a browser")
		}
		_UCSO_Require(_UC_RetiredHosts.Length == 0 && !IsObject(_UC_PendingHost),
			"all finished constructors must discharge exact pending and retirement owners")
	} catch Any as Failure
		Primary := Failure
	finally {
		if HasMethod(_UCSO.Boundary, "Call")
			SetTimer(_UCSO.Boundary, 0)
		try {
			_UpdateCheck_CloseWindow()
			_UCSO_Require(_UC_RetiredHosts.Length == 0, "cleanup must discharge every exact retired host")
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		OnError(_UCSO_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_UCSO.Failure)
		Primary := _UCSO.Failure
	if IsObject(Primary) {
		FileAppend("FAIL update startup " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS update-check-native-consent " . _UCSO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_UCSO_Main()
