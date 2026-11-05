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
SendKeysVocabularyJson() => "[]"
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
		global _APSO
		this.Subscriptions += 1
		if InStr(_APSO.Mode, "subscription-") == 1
			return _APSO_Subscribe(Callback)
		return { Callback: Callback }
	}
	NavigationCompleted(Callback) {
		global _APSO
		this.Subscriptions += 1
		if InStr(_APSO.Mode, "subscription-") == 1
			return _APSO_Subscription(Callback)
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
		global _APSO
		if InStr(_APSO.Mode, "subscription-") == 1 {
			_APSO.CloseCalls += 1
			_APSO.ActiveAtClose := _APSO.ActiveSubscriptions
			_APSO.AliveAtClose := !!DllCall("IsWindow", "Ptr", _APSO.Hwnds[1], "Int")
		}
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
	if _APSO.Controllers.Length > 1 || _APSO.Mode == "current" || InStr(_APSO.Mode, "subscription-") == 1
		return Controller
	_APSO.Pending := Promise.withResolvers()
	; The timer port has an independent settlement consumer so Promise.task does
	; not report an unobserved rejection before the suspended await resumes.
	; These callbacks never change its state or replace the rejecting await.
	_APSO.Pending.promise.onSettled((*) => 0, (*) => 0)
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

; An asynchronous exception cannot cross the suspended Main try/catch. Suppress
; its modal only after retaining it as a mandatory failure, never as success.
_APSO_OnError(Failure, Mode) {
	global _APSO
	OwnerFile := "UNKNOWN", OwnerLine := 0
	if Failure is Error {
		SplitPath(Failure.File, &OwnerFile)
		OwnerLine := Failure.Line
	}
	if !IsObject(_APSO.Failure)
		_APSO.Failure := Failure is Error ? Failure
			: Error("An asynchronous child failure was observed: " . Type(Failure))
	try FileAppend("DIAG action-picker-startup async type=" . Type(Failure)
		. " file=" . OwnerFile . " line=" . OwnerLine . " mode=" . Mode . "`n", "*", "UTF-8")
	Stack := Error("Observer frame").Stack
	for Line in StrSplit(SubStr(Stack, 1, 2048), "`n", "`r")
		try FileAppend("DIAG action-picker-startup observer-stack " . Line . "`n", "*", "UTF-8")
	return true
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
	if InStr(_APSO.Mode, "subscription-") == 1 {
		_APSO_CheckSubscription()
		return
	}
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
		Boundary: 0, Failure: 0, CloseSent: 0, OldEpoch: 0, OldConfirmed: 0, NextConfirmed: 0,
		SubscriptionCalls: 0, InFlight: false, ActiveSubscriptions: 0, CreatedSubscriptions: 0,
		ReleasedSubscriptions: 0, ReleasedInFlight: false, CloseObserved: false,
		AliveAtReturn: false, AliveAtClose: false, ActiveAtClose: -1, CloseCalls: 0 }
	global _VendorDir := A_Args[2], _SharedDir := A_Args[2], _I18nLocale := "en"
	global _LLM_Menu := Map("n_predictions", 3)
	_ActPickWeb_ProgramCapturing := true
	Primary := 0
	OnError(_APSO_OnError)
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
		OnError(_APSO_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_APSO.Failure)
		Primary := _APSO.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS action-picker-startup " . _APSO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}


; The browser port returns a real AHK handle with the same last-reference
; unsubscribe lifetime as the shipped SDK. Native cancellation is unmodified.
class _APSO_Subscription {
	__New(Callback) {
		global _APSO
		this.Callback := Callback
		_APSO.ActiveSubscriptions += 1, _APSO.CreatedSubscriptions += 1
	}
	__Delete() {
		global _APSO
		_APSO.ReleasedInFlight := _APSO.ReleasedInFlight || _APSO.InFlight
		_APSO.ActiveSubscriptions -= 1, _APSO.ReleasedSubscriptions += 1
	}
}

_APSO_SubscriptionClose() {
	global _APSO, _ActPickWeb_SessionEpoch, _ActPickWeb_Gui
	Hwnd := _APSO.Hwnds[1], Epoch := _ActPickWeb_SessionEpoch
	_APSO_Require(Epoch > 0 && _ActPickWeb_Gui == _APSO.Windows[1]
		&& WinGetPID("ahk_id " . Hwnd) == ProcessExist()
		&& DllCall("IsWindowVisible", "Ptr", Hwnd, "Int"),
		"The add-event actor requires its exact current visible native picker")
	_APSO.CloseSent += 1
	_APSO_Require(DllCall("PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int"),
		"The owned picker must admit the genuine WM_CLOSE")
	Started := A_TickCount
	while _ActPickWeb_SessionEpoch == Epoch && A_TickCount - Started < 1000
		Sleep(10)
	_APSO.CloseObserved := _ActPickWeb_SessionEpoch > Epoch && !IsObject(_ActPickWeb_Gui)
	_APSO_Require(_APSO.CloseObserved, "The actual Close must revoke the picker before add-event returns")
}

_APSO_Subscribe(Callback) {
	global _APSO
	_APSO.SubscriptionCalls += 1
	_APSO.InFlight := true
	try {
		if _APSO.Mode == "subscription-close"
			_APSO_SubscriptionClose()
		_APSO.AliveAtReturn := !!DllCall("IsWindow", "Ptr", _APSO.Hwnds[1], "Int")
		return _APSO_Subscription(Callback)
	} finally _APSO.InFlight := false
}

_APSO_CheckSubscription() {
	global _APSO, _ActPickWeb_Gui, _ActPickWeb_Controller, _ActPickWeb_WebView
	global _ActPickWeb_MsgSub, _ActPickWeb_NavSub
	Ready := true
	if _APSO.Mode == "subscription-current" {
		Ready := _APSO.SubscriptionCalls == 1 && _APSO.ActiveSubscriptions == 2
			&& _APSO.Controllers.Length == 1 && _APSO.Windows.Length == 1
			&& _ActPickWeb_Gui == _APSO.Windows[1] && _ActPickWeb_Controller == _APSO.Controllers[1]
			&& _ActPickWeb_WebView == _APSO.Controllers[1].CoreWebView2
			&& IsSet(_ActPickWeb_MsgSub) && IsSet(_ActPickWeb_NavSub)
			&& _APSO.Controllers[1].CoreWebView2.Navigations == 1 && _APSO.Controllers[1].Fills >= 1
		_APSO_SubscriptionClose()
	}
	FileAppend("OBSERVATION action-picker-subscription mode=" . _APSO.Mode
		. " calls=" . _APSO.SubscriptionCalls . " close_sent=" . _APSO.CloseSent
		. " close_observed=" . _APSO.CloseObserved . " native_alive_at_return=" . _APSO.AliveAtReturn
		. " native_alive_at_close=" . _APSO.AliveAtClose . " active_at_close=" . _APSO.ActiveAtClose
		. " created=" . _APSO.CreatedSubscriptions . " released=" . _APSO.ReleasedSubscriptions
		. " released_in_flight=" . _APSO.ReleasedInFlight . " controller_closed=" . _APSO.Controllers[1].Closed
		. " close_calls=" . _APSO.CloseCalls . " ready=" . Ready . "`n", "*", "UTF-8")
	_APSO_Require(Ready && _APSO.Controllers.Length == 1 && _APSO.Windows.Length == 1
		&& _APSO.CloseSent == 1 && _APSO.CloseObserved && _APSO.SubscriptionCalls == 1,
		"One genuine public browser must reach its actual native cancellation")
	if _APSO.Mode == "subscription-close"
		_APSO_Require(_APSO.Controllers[1].CoreWebView2.Subscriptions == 1
			&& _APSO.Controllers[1].CoreWebView2.Navigations == 0 && _APSO.Controllers[1].Fills == 0,
			"A retired add-event must not subscribe again, navigate or Fill")
	_APSO_Require(_APSO.AliveAtReturn && _APSO.AliveAtClose && _APSO.ActiveAtClose == 0
		&& _APSO.ActiveSubscriptions == 0 && _APSO.CreatedSubscriptions == _APSO.ReleasedSubscriptions
		&& !_APSO.ReleasedInFlight && _APSO.Controllers[1].Closed == 1 && _APSO.CloseCalls == 1,
		"The HWND must survive add-event return and unsubscribe before its controller closes once")
	_APSO_Require(!DllCall("IsWindow", "Ptr", _APSO.Hwnds[1], "Int") && !IsObject(_ActPickWeb_Gui)
		&& !IsSet(_ActPickWeb_Controller) && !IsSet(_ActPickWeb_WebView)
		&& !IsSet(_ActPickWeb_MsgSub) && !IsSet(_ActPickWeb_NavSub),
		"The exact retired picker must finally release its native and browser resources")
}

_APSO_Main()
