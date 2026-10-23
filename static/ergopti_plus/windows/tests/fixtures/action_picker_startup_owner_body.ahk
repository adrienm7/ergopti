; tests/fixtures/action_picker_startup_owner_body.ahk

; ==============================================================================
; MODULE: Action Picker Startup Owner Child
; DESCRIPTION:
; Runs the real public picker, its genuine singleton lifecycle and native GUI.
; Browser construction is a passive port that awaits the shipped Promise and
; receives a real WM_CLOSE before returning. No Edge or physical input claim.
; ==============================================================================

#Requires AutoHotkey v2.0

_APSO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; Discovery and rendering data are outside this lifecycle fixture. The actual
; provider owner remains included, with its capture guard already held.
t(Key) => Key
GestureActionPickerItems() => []
GestureActionParameterPrompt(Action) => Action
GestureSendInputErrorText(Kind) => Kind
SendInputVocabularyJson() => "[]"
LLM_Menu_PromptChoices() => []
LLM_Vision_BackendChoices() => []
LLM_Translate_ShippedChoices() => []
GestureClearPickedParameter() => 0
LoggerSuccess(*) => 0
LoggerError(*) => 0
WebView_SharedEnvironment(Loader) => { Passive: true }

Gui_Create(Options := "", Title := "") {
	global _APSO
	Window := Gui(Options, Title)
	_APSO.Windows.Push(Window)
	_APSO.Hwnds.Push(Window.Hwnd)
	return Window
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		_APSO_Require(!IsSet(Callback) && Environment.Passive,
			"The production call must use its synchronous constructor contract.")
		return _APSO_Create(Hwnd)
	}
}

class _APSO_View {
	__New() {
		this.Settings := {}, this.Subscriptions := 0, this.Navigations := 0
	}
	WebMessageReceived(Callback) {
		this.Subscriptions += 1
		return { Callback: Callback }
	}
	NavigationCompleted(Callback) {
		this.Subscriptions += 1
		return { Callback: Callback }
	}
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
}

class _APSO_Controller {
	__New() {
		this.CoreWebView2 := _APSO_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}

_APSO_Create(Hwnd) {
	global _APSO, _ActPickWeb_Gui
	_APSO_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
		"The controlled browser receives a genuine native placeholder.")
	_APSO_Require(IsObject(_ActPickWeb_Gui)
		&& DllCall("User32\IsWindowVisible", "Ptr", _ActPickWeb_Gui.Hwnd, "Int"),
		"The browser wait begins only after the genuine picker is visible and published.")
	Controller := _APSO_Controller()
	_APSO.Controllers.Push(Controller)
	if _APSO.Controllers.Length > 1 || _APSO.Mode == "current"
		return Controller
	_APSO.Pending := Promise.withResolvers()
	_APSO.Boundary := _APSO_CloseDuringCreate
	SetTimer(_APSO.Boundary, -1)
	return _APSO.Pending.promise.await(3000)
}

_APSO_CloseDuringCreate() {
	global _APSO, _ActPickWeb_SessionEpoch
	try {
		_APSO.OldEpoch := _ActPickWeb_SessionEpoch
		OldHwnd := _APSO.Hwnds[1]
		_APSO_Require(DllCall("User32\IsWindowVisible", "Ptr", OldHwnd, "Int"),
			"The actual Close event must address the visible original picker.")
		_APSO.CloseSent += 1
		DllCall("User32\SendMessageW", "Ptr", OldHwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
		CloseStarted := A_TickCount
		while (DllCall("User32\IsWindow", "Ptr", OldHwnd, "Int")
				|| _ActPickWeb_SessionEpoch <= _APSO.OldEpoch)
				&& ((A_TickCount - CloseStarted) & 0xFFFFFFFF) < 1000
			Sleep(10)
		_APSO_Require(!DllCall("User32\IsWindow", "Ptr", OldHwnd, "Int"),
			"The production Close handler must actually destroy the original native window.")
		_APSO_Require(_ActPickWeb_SessionEpoch > _APSO.OldEpoch,
			"The actual Close event must revoke the admitted session before construction resumes.")
		if InStr(_APSO.Mode, "reopen") {
			ShowActionPicker("Private successor picker", "none", _APSO_Confirm.Bind("next"))
			_APSO_Require(_APSO.Windows.Length == 2 && _APSO.Controllers.Length == 2,
				"A replacement must use the same genuine public constructor.")
		}
		if InStr(_APSO.Mode, "reject")
			_APSO.Pending.reject.Call(Error("Controlled retired browser construction refusal"))
		else
			_APSO.Pending.resolve.Call(_APSO.Controllers[1])
	} catch as Failure {
		_APSO.Failure := Failure
		_APSO.Pending.reject.Call(Failure)
	}
}

_APSO_Confirm(Which, Id) {
	global _APSO
	_APSO_Require(Id == "none", "The genuine callback preserves the selected action.")
	if Which == "next"
		_APSO.NextConfirmed += 1
	else
		_APSO.OldConfirmed += 1
}

_APSO_Observe() {
	global _APSO, _ActPickWeb_Gui, _ActPickWeb_ResetDone, _ActPickWeb_SessionEpoch
	global _ActPickWeb_Controller, _ActPickWeb_WebView, _ActPickWeb_MsgSub, _ActPickWeb_NavSub
	FileAppend("RECEIPT action-picker-startup mode=" . _APSO.Mode
		. " windows=" . _APSO.Windows.Length . " controllers=" . _APSO.Controllers.Length
		. " close_sent=" . _APSO.CloseSent . " old_closed=" . _APSO.Controllers[1].Closed
		. " old_subscriptions=" . _APSO.Controllers[1].CoreWebView2.Subscriptions
		. " old_navigations=" . _APSO.Controllers[1].CoreWebView2.Navigations
		. " reset=" . _ActPickWeb_ResetDone . " epoch=" . _ActPickWeb_SessionEpoch
		. " has_controller=" . IsSet(_ActPickWeb_Controller) . " has_view=" . IsSet(_ActPickWeb_WebView)
		. " has_message=" . IsSet(_ActPickWeb_MsgSub) . " has_navigation=" . IsSet(_ActPickWeb_NavSub)
		. " gui=" . IsObject(_ActPickWeb_Gui) . "`n", "*", "UTF-8")
}

_APSO_Check() {
	global _APSO, _ActPickWeb_Gui, _ActPickWeb_ResetDone, _ActPickWeb_OnConfirm
	global _ActPickWeb_Controller, _ActPickWeb_WebView, _ActPickWeb_MsgSub, _ActPickWeb_NavSub
	if IsObject(_APSO.Failure)
		throw _APSO.Failure
	_APSO_Require(_APSO.OldConfirmed == 0 && _APSO.NextConfirmed == 0,
		"Closing during startup must never invoke either confirmation callback.")
	if _APSO.Mode == "current" {
		_APSO_Require(_APSO.Controllers.Length == 1 && _APSO.Windows.Length == 1,
			"The current positive must open exactly one web picker without native fallback.")
		_APSO_Require(_ActPickWeb_Controller == _APSO.Controllers[1]
			&& _ActPickWeb_WebView == _APSO.Controllers[1].CoreWebView2
			&& _APSO.Controllers[1].CoreWebView2.Subscriptions == 2,
			"A current construction must retain its real message and navigation subscriptions.")
		_APSO_Require(_ActPickWeb_Confirm("none") && _APSO.OldConfirmed == 1,
			"The genuine current confirmation remains usable.")
	} else {
		Reopened := InStr(_APSO.Mode, "reopen") != 0
		_APSO_Require(_APSO.CloseSent == 1 && _APSO.Windows.Length == (Reopened ? 2 : 1),
			"A consumed Close must never reopen the legacy native fallback.")
		if !InStr(_APSO.Mode, "reject")
			_APSO_Require(_APSO.Controllers[1].Closed == 1,
				"A controller returned after its native window closed must retire exactly once.")
		_APSO_Require(_APSO.Controllers[1].CoreWebView2.Subscriptions == 0
			&& _APSO.Controllers[1].CoreWebView2.Navigations == 0,
			"An old constructor must never subscribe or navigate after its owner retired.")
		if Reopened {
			_APSO_Require(_ActPickWeb_Gui == _APSO.Windows[2]
				&& DllCall("User32\IsWindowVisible", "Ptr", _APSO.Hwnds[2], "Int")
				&& _ActPickWeb_Controller == _APSO.Controllers[2]
				&& _ActPickWeb_WebView == _APSO.Controllers[2].CoreWebView2
				&& !_ActPickWeb_ResetDone && _APSO.Controllers[2].Closed == 0,
				"The resumed old frame must preserve the entire replacement session.")
			_APSO_Require(_ActPickWeb_Confirm("none") && _APSO.NextConfirmed == 1
				&& _APSO.OldConfirmed == 0, "Only the replacement confirmation remains live.")
		} else {
			_APSO_Require(!IsObject(_ActPickWeb_Gui) && _ActPickWeb_ResetDone
				&& !IsSet(_ActPickWeb_Controller) && !IsSet(_ActPickWeb_WebView)
				&& !IsSet(_ActPickWeb_MsgSub) && !IsSet(_ActPickWeb_NavSub)
				&& _ActPickWeb_OnConfirm == 0,
				"A canceled constructor must leave no published browser, subscriptions or callback.")
		}
	}
}

_APSO_Main() {
	global _ActPickWeb_ProgramCapturing
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _APSO := { Mode: A_Args[1], Windows: [], Hwnds: [], Controllers: [], Pending: 0,
		Boundary: 0, Failure: 0, CloseSent: 0, OldEpoch: 0, OldConfirmed: 0, NextConfirmed: 0 }
	global _VendorDir := A_Args[2], _SharedDir := A_Args[2], _I18nLocale := "en"
	global _LLM_Menu := Map("n_predictions", 3)
	_ActPickWeb_ProgramCapturing := true
	Primary := 0
	try {
		ShowActionPicker("Private original picker", "none", _APSO_Confirm.Bind("old"))
		_APSO_Observe()
		_APSO_Check()
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if HasMethod(_APSO.Boundary, "Call")
				SetTimer(_APSO.Boundary, 0)
			_ActPickWeb_Close()
			for Controller in _APSO.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Index, Window in _APSO.Windows
				if DllCall("User32\IsWindow", "Ptr", _APSO.Hwnds[Index], "Int")
					Window.Destroy()
			for Hwnd in _APSO.Hwnds
				_APSO_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "Every private native window must retire.")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		_APSO.Pending := 0, _APSO.Boundary := 0
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS action-picker-startup " . _APSO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_APSO_Main()
