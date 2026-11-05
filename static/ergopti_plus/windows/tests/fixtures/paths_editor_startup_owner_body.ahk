; tests/fixtures/paths_editor_startup_owner_body.ahk

; ==============================================================================
; MODULE: Paths Editor Startup Owner Child
; DESCRIPTION:
; Runs the real public folder editor, its genuine singleton lifecycle and native GUI.
; Browser construction is a passive port that awaits the shipped Promise and
; receives a real WM_CLOSE before returning. No Edge or physical input claim.
; ==============================================================================

#Requires AutoHotkey v2.0

_PWSO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

t(Key) => Key
LoggerSuccess(*) => 0
LoggerError(*) => 0
WebView_SharedEnvironment(Loader) => { Passive: true }

Gui_Create(Options := "", Title := "") {
	global _PWSO
	Window := Gui(Options, Title)
	_PWSO.Windows.Push(Window)
	_PWSO.Hwnds.Push(Window.Hwnd)
	return Window
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		_PWSO_Require(!IsSet(Callback) && Environment.Passive,
			"The production call must use its synchronous constructor contract.")
		return _PWSO_Create(Hwnd)
	}
}

class _PWSO_View {
	__New() {
		this.Settings := {}, this.Subscriptions := 0, this.Navigations := 0
	}
	WebMessageReceived(Callback) {
		global _PWSO
		this.Subscriptions += 1
		if InStr(_PWSO.Mode, "subscription-error-") == 1 && _PWSO.Controllers.Length == 1
			throw _PWSO.SdkFailure
		if InStr(_PWSO.Mode, "subscription-") == 1
			return _PWSO_Subscribe(Callback)
		return { Callback: Callback }
	}
	NavigationCompleted(Callback) {
		global _PWSO
		this.Subscriptions += 1
		if InStr(_PWSO.Mode, "subscription-") == 1
			return _PWSO_Subscription(Callback)
		return { Callback: Callback }
	}
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
}

class _PWSO_Controller {
	__New() {
		this.CoreWebView2 := _PWSO_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		global _PWSO
		if InStr(_PWSO.Mode, "subscription-") == 1 {
			_PWSO.CloseCalls += 1
			_PWSO.ActiveAtClose := _PWSO.ActiveSubscriptions
			_PWSO.AliveAtClose := !!DllCall("IsWindow", "Ptr", _PWSO.Hwnds[1], "Int")
		}
		this.Closed += 1
		if _PWSO.Mode == "subscription-error-reopen" && !_PWSO.ErrorReopen && this == _PWSO.Controllers[1] {
			_PWSO.ErrorReopen := true
			FilePathsEditor()
		}
	}
	Fill() {
		this.Fills += 1
	}
}

_PWSO_Create(Hwnd) {
	global _PWSO, _PathsEdWeb_Gui
	_PWSO_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
		"The controlled browser receives a genuine native placeholder.")
	_PWSO_Require(IsObject(_PathsEdWeb_Gui)
		&& DllCall("User32\IsWindowVisible", "Ptr", _PathsEdWeb_Gui.Hwnd, "Int"),
		"The browser wait begins only after the genuine editor is visible and published.")
	if InStr(_PWSO.Mode, "factory-error-") == 1 && !_PWSO.FactoryFailed {
		_PWSO.FactoryFailed := true
		throw Error("private Paths factory refusal")
	}
	Controller := _PWSO_Controller()
	_PWSO.Controllers.Push(Controller)
	if _PWSO.Controllers.Length > 1 || _PWSO.Mode == "current" || InStr(_PWSO.Mode, "subscription-") == 1 || InStr(_PWSO.Mode, "factory-error-") == 1
		return Controller
	_PWSO.Pending := Promise.withResolvers()
	; The timer port has an independent settlement consumer so Promise.task does
	; not report an unobserved rejection before the suspended await resumes.
	; These callbacks never change its state or replace the rejecting await.
	_PWSO.Pending.promise.onSettled((*) => 0, (*) => 0)
	_PWSO.Boundary := _PWSO_CloseDuringCreate
	SetTimer(_PWSO.Boundary, -1)
	return _PWSO.Pending.promise.await(3000)
}

_PWSO_CloseDuringCreate() {
	global _PWSO, _PathsEdWeb_SessionEpoch
	try {
		_PWSO.OldEpoch := _PathsEdWeb_SessionEpoch
		OldHwnd := _PWSO.Hwnds[1]
		_PWSO_Require(DllCall("User32\IsWindowVisible", "Ptr", OldHwnd, "Int"),
			"The actual Close event must address the visible original editor.")
		_PWSO.CloseSent += 1
		DllCall("User32\SendMessageW", "Ptr", OldHwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
		CloseStarted := A_TickCount
		while (DllCall("User32\IsWindow", "Ptr", OldHwnd, "Int")
				|| _PathsEdWeb_SessionEpoch <= _PWSO.OldEpoch)
				&& ((A_TickCount - CloseStarted) & 0xFFFFFFFF) < 1000
			Sleep(10)
		_PWSO_Require(!DllCall("User32\IsWindow", "Ptr", OldHwnd, "Int"),
			"The production Close handler must actually destroy the original native window.")
		_PWSO_Require(_PathsEdWeb_SessionEpoch > _PWSO.OldEpoch,
			"The actual Close event must revoke the admitted session before construction resumes.")
		if InStr(_PWSO.Mode, "reopen") {
			FilePathsEditor()
			_PWSO_Require(_PWSO.Windows.Length == 2 && _PWSO.Controllers.Length == 2,
				"A replacement must use the same genuine public constructor.")
			_PWSO.SuccessorEpoch := _PathsEdWeb_SessionEpoch
		}
		if InStr(_PWSO.Mode, "reject")
			_PWSO.Pending.reject.Call(Error("Controlled retired paths browser construction refusal"))
		else
			_PWSO.Pending.resolve.Call(_PWSO.Controllers[1])
	} catch as Failure {
		_PWSO.Failure := Failure
		_PWSO.Pending.reject.Call(Failure)
	}
}

; An asynchronous exception cannot cross the suspended Main try/catch. Suppress
; its modal only after retaining it as a mandatory failure, never as success.
_PWSO_OnError(Failure, Mode) {
	global _PWSO
	OwnerFile := "UNKNOWN", OwnerLine := 0
	if Failure is Error {
		SplitPath(Failure.File, &OwnerFile)
		OwnerLine := Failure.Line
	}
	if !IsObject(_PWSO.Failure)
		_PWSO.Failure := Failure is Error ? Failure
			: Error("An asynchronous child failure was observed: " . Type(Failure))
	try FileAppend("DIAG paths-editor-startup async type=" . Type(Failure)
		. " file=" . OwnerFile . " line=" . OwnerLine . " mode=" . Mode . "`n", "*", "UTF-8")
	Stack := Error("Observer frame").Stack
	for Line in StrSplit(SubStr(Stack, 1, 2048), "`n", "`r")
		try FileAppend("DIAG paths-editor-startup observer-stack " . Line . "`n", "*", "UTF-8")
	return true
}

_PWSO_Observe() {
	global _PWSO, _PathsEdWeb_Gui, _PathsEdWeb_ResetDone, _PathsEdWeb_SessionEpoch
	global _PathsEdWeb_Controller, _PathsEdWeb_WebView, _PathsEdWeb_MsgSub, _PathsEdWeb_NavSub
	FileAppend("RECEIPT paths-editor-startup mode=" . _PWSO.Mode
		. " windows=" . _PWSO.Windows.Length . " controllers=" . _PWSO.Controllers.Length
		. " close_sent=" . _PWSO.CloseSent . " old_closed=" . _PWSO.Controllers[1].Closed
		. " old_subscriptions=" . _PWSO.Controllers[1].CoreWebView2.Subscriptions
		. " old_navigations=" . _PWSO.Controllers[1].CoreWebView2.Navigations
		. " reset=" . _PathsEdWeb_ResetDone . " epoch=" . _PathsEdWeb_SessionEpoch
		. " has_controller=" . IsSet(_PathsEdWeb_Controller) . " has_view=" . IsSet(_PathsEdWeb_WebView)
		. " has_message=" . IsSet(_PathsEdWeb_MsgSub) . " has_navigation=" . IsSet(_PathsEdWeb_NavSub)
		. " gui=" . IsObject(_PathsEdWeb_Gui)
		. " successor_epoch=" . _PWSO.SuccessorEpoch . "`n", "*", "UTF-8")
}

_PWSO_Check() {
	global _PWSO, _PathsEdWeb_Gui, _PathsEdWeb_ResetDone, _PathsEdWeb_SessionEpoch
	global _PathsEdWeb_Controller, _PathsEdWeb_WebView, _PathsEdWeb_MsgSub, _PathsEdWeb_NavSub
	if IsObject(_PWSO.Failure)
		throw _PWSO.Failure
	if InStr(_PWSO.Mode, "subscription-error-") == 1 {
		_PWSO_CheckSubscriptionError()
		return
	}
	if _PWSO.Mode == "subscription-reset-retain" {
		_PWSO_CheckResetRetain()
		return
	}
	if InStr(_PWSO.Mode, "subscription-") == 1 {
		_PWSO_CheckSubscription()
		return
	}
	if _PWSO.Mode == "current" {
		_PWSO_Require(_PWSO.Controllers.Length == 1 && _PWSO.Windows.Length == 1,
			"The public current editor must open exactly one browser host without native fallback.")
		_PWSO_Require(_PathsEdWeb_Gui == _PWSO.Windows[1]
			&& _PathsEdWeb_Controller == _PWSO.Controllers[1]
			&& _PathsEdWeb_WebView == _PWSO.Controllers[1].CoreWebView2
			&& IsSet(_PathsEdWeb_MsgSub) && IsSet(_PathsEdWeb_NavSub)
			&& _PWSO.Controllers[1].CoreWebView2.Subscriptions == 2
			&& _PWSO.Controllers[1].CoreWebView2.Navigations == 1
			&& _PWSO.Controllers[1].Fills > 0 && !_PathsEdWeb_ResetDone,
			"A current public editor must subscribe, navigate and fill its exact browser.")
	} else {
		Reopened := InStr(_PWSO.Mode, "reopen") != 0
		_PWSO_Require(_PWSO.CloseSent == 1 && _PWSO.Windows.Length == (Reopened ? 2 : 1),
			"A consumed Close must never reopen the legacy native fallback.")
		_PWSO_Require(!DllCall("User32\IsWindow", "Ptr", _PWSO.Hwnds[1], "Int"),
			"The original closed native host must remain destroyed after the constructor returns.")
		if !InStr(_PWSO.Mode, "reject")
			_PWSO_Require(_PWSO.Controllers[1].Closed == 1,
				"A controller returned after its native host closed must retire exactly once.")
		_PWSO_Require(_PWSO.Controllers[1].CoreWebView2.Subscriptions == 0
			&& _PWSO.Controllers[1].CoreWebView2.Navigations == 0
			&& _PWSO.Controllers[1].Fills == 0,
			"An old constructor must never subscribe, navigate or fill after its owner retired.")
		if Reopened {
			_PWSO_Require(_PathsEdWeb_Gui == _PWSO.Windows[2]
				&& DllCall("User32\IsWindowVisible", "Ptr", _PWSO.Hwnds[2], "Int")
				&& _PathsEdWeb_Controller == _PWSO.Controllers[2]
				&& _PathsEdWeb_WebView == _PWSO.Controllers[2].CoreWebView2
				&& IsSet(_PathsEdWeb_MsgSub) && IsSet(_PathsEdWeb_NavSub)
				&& !_PathsEdWeb_ResetDone && _PWSO.Controllers[2].Closed == 0
				&& _PathsEdWeb_SessionEpoch == _PWSO.SuccessorEpoch
				&& _PWSO.Controllers[2].CoreWebView2.Subscriptions == 2
				&& _PWSO.Controllers[2].CoreWebView2.Navigations == 1,
				"The resumed old constructor must preserve the complete replacement session.")
		} else {
			_PWSO_Require(_PathsEdWeb_Gui == 0 && _PathsEdWeb_ResetDone
				&& !IsSet(_PathsEdWeb_Controller) && !IsSet(_PathsEdWeb_WebView)
				&& !IsSet(_PathsEdWeb_MsgSub) && !IsSet(_PathsEdWeb_NavSub),
				"A canceled constructor must leave no published browser or subscriptions.")
		}
	}
}

; Reset is plumbing-only: the HWND survives until an explicit later Close.
_PWSO_CheckResetRetain() {
	global _PWSO, _PathsEdWeb_Gui
	Ready := _PWSO.ResetRetained && _PWSO.AliveAtReturn && _PWSO.Windows.Length == 1
		&& _PWSO.Controllers.Length == 1 && _PathsEdWeb_Gui == _PWSO.Windows[1]
		&& DllCall("IsWindow", "Ptr", _PWSO.Hwnds[1], "Int")
		&& _PWSO.CloseCalls == 1 && _PWSO.ActiveAtClose == 0 && _PWSO.AliveAtClose
		&& _PWSO.CreatedSubscriptions == 1 && _PWSO.ReleasedSubscriptions == 1 && !_PWSO.ReleasedInFlight
	FileAppend("OBSERVATION paths-subscription-retain ready=" . Ready . " reset=" . _PWSO.ResetRetained
		. " add_alive=" . _PWSO.AliveAtReturn . " closed=" . _PWSO.CloseCalls
		. " active_at_close=" . _PWSO.ActiveAtClose . "`n", "*", "UTF-8")
	_PWSO_Require(Ready, "Reset during add must retain this GUI after the returned handle and controller retire")
	_PathsEdWeb_Close(_PWSO.Windows[1])
	_PWSO_Require(!IsObject(_PathsEdWeb_Gui) && !DllCall("IsWindow", "Ptr", _PWSO.Hwnds[1], "Int")
		&& _PWSO.CloseCalls == 1, "later exact Close must destroy the retained GUI without a second controller close")
}

; The Paths owner propagates a current add_Event exception, unlike its separate
; factory failure path. A newer public opening must survive the old exception.
_PWSO_CheckSubscriptionError() {
	global _PWSO, _PathsEdWeb_Gui, _PathsEdWeb_Controller
	ErrorMatches := IsObject(_PWSO.OpenError) && _PWSO.OpenError == _PWSO.SdkFailure
		&& _PWSO.OpenError.Message == "private Paths SDK refusal"
	OldGone := _PWSO.Hwnds.Length && !DllCall("IsWindow", "Ptr", _PWSO.Hwnds[1], "Int")
	FileAppend("OBSERVATION paths-subscription-error mode=" . _PWSO.Mode . " original_error=" . ErrorMatches
		. " old_gone=" . OldGone . " closed=" . _PWSO.CloseCalls . " reopened=" . _PWSO.ErrorReopen
		. " windows=" . _PWSO.Windows.Length . "`n", "*", "UTF-8")
	_PWSO_Require(ErrorMatches && OldGone && _PWSO.CloseCalls == 1,
		"the original current SDK exception must propagate after the exact old host retires")
	if _PWSO.Mode == "subscription-error-current"
		_PWSO_Require(_PWSO.Windows.Length == 1 && !IsObject(_PathsEdWeb_Gui), "a current failure must not invent a fallback")
	else
		_PWSO_Require(_PWSO.ErrorReopen && _PWSO.Windows.Length == 2 && _PWSO.Controllers.Length == 2
			&& _PathsEdWeb_Gui == _PWSO.Windows[2] && _PathsEdWeb_Controller == _PWSO.Controllers[2]
			&& !_PWSO.Controllers[2].Closed && DllCall("IsWindow", "Ptr", _PWSO.Hwnds[2], "Int"),
			"the successor opened during old cleanup must retain its exact live host")
}

; The injected failure is limited to the existing passive browser factory.
; Destruction still delegates to the real Gui before the public reopen.
_PWSO_FactoryDestroy(Window, Args*) {
	global _PWSO
	if _PWSO.Mode == "factory-error-reopen" && !_PWSO.FactoryReopen && Window == _PWSO.Windows[1] {
		_PWSO.FactoryReopen := true
		Result := _PWSO.FactoryDestroy.Call(Window, Args*)
		FilePathsEditor()
		return Result
	}
	return _PWSO.FactoryDestroy.Call(Window, Args*)
}
_PWSO_CheckFactoryError() {
	global _PWSO, _PathsEdWeb_Gui, _PathsEdWeb_Controller
	OldGone := _PWSO.Hwnds.Length && !DllCall("IsWindow", "Ptr", _PWSO.Hwnds[1], "Int")
	FileAppend("OBSERVATION paths-factory-error mode=" . _PWSO.Mode . " failed=" . _PWSO.FactoryFailed
		. " result=" . _PWSO.FactoryResult . " reopened=" . _PWSO.FactoryReopen
		. " windows=" . _PWSO.Windows.Length . " old_gone=" . OldGone
		. " caught=" . IsObject(_PWSO.OpenError) . "`n", "*", "UTF-8")
	_PWSO_Require(_PWSO.FactoryFailed && !IsObject(_PWSO.OpenError) && OldGone,
		"the real owner must handle its factory failure and destroy the exact original host")
	if _PWSO.Mode == "factory-error-current"
		_PWSO_Require(_PWSO.FactoryResult is Integer && _PWSO.FactoryResult == 0
			&& _PWSO.Windows.Length == 1 && !IsObject(_PathsEdWeb_Gui), "only the current failed opening may admit fallback")
	else
		_PWSO_Require(_PWSO.FactoryResult is Integer && _PWSO.FactoryResult == 1 && _PWSO.FactoryReopen
			&& _PWSO.Windows.Length == 2 && _PWSO.Controllers.Length == 1 && _PathsEdWeb_Gui == _PWSO.Windows[2]
			&& _PathsEdWeb_Controller == _PWSO.Controllers[1] && !_PWSO.Controllers[1].Closed
			&& DllCall("IsWindow", "Ptr", _PWSO.Hwnds[2], "Int"), "a real successor opened during old Destroy forbids the old fallback")
}

_PWSO_Main() {
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _PWSO := { Mode: A_Args[1], Windows: [], Hwnds: [], Controllers: [], Pending: 0,
		Boundary: 0, Failure: 0, CloseSent: 0, OldEpoch: 0, SuccessorEpoch: 0,
		SubscriptionCalls: 0, InFlight: false, ActiveSubscriptions: 0, CreatedSubscriptions: 0,
		ReleasedSubscriptions: 0, ReleasedInFlight: false, CloseObserved: false,
		AliveAtReturn: false, AliveAtClose: false, ActiveAtClose: -1, CloseCalls: 0,
		ResetRetained: false, ErrorReopen: false, OpenError: 0, SdkFailure: Error("private Paths SDK refusal"),
		FactoryFailed: false, FactoryReopen: false, FactoryResult: "unset", FactoryDestroy: 0 }
	global _VendorDir := A_Args[2], _SharedDir := A_Args[2], _I18nLocale := "en"
	global _ConfigDir := A_Args[2] . "\", _PathsFile := A_Args[2] . "\unwritten-paths.toml"
	Primary := 0
	DestroyDescriptor := Gui.Prototype.GetOwnPropDesc("Destroy")
	_PWSO.FactoryDestroy := DestroyDescriptor.Call
	OnError(_PWSO_OnError)
	try {
		if InStr(_PWSO.Mode, "factory-error-") == 1 {
			if _PWSO.Mode == "factory-error-reopen"
				Gui.Prototype.DefineProp("Destroy", {Call: _PWSO_FactoryDestroy})
			try _PWSO.FactoryResult := _PathsEdWeb_TryOpen()
			catch Any as Failure
				_PWSO.OpenError := Failure
			_PWSO_CheckFactoryError()
		} else if InStr(_PWSO.Mode, "subscription-error-") == 1 {
			try FilePathsEditor()
			catch Any as Failure
				_PWSO.OpenError := Failure
		} else
			FilePathsEditor()
		if InStr(_PWSO.Mode, "factory-error-") != 1 {
			_PWSO_Observe()
			_PWSO_Check()
		}
		_PWSO_Require(!FileExist(_PathsFile), "Opening or canceling must not publish a paths file.")
	} catch as Failure {
		Primary := Failure
	} finally {
		Gui.Prototype.DefineProp("Destroy", DestroyDescriptor)
		try {
			if HasMethod(_PWSO.Boundary, "Call")
				SetTimer(_PWSO.Boundary, 0)
			_PathsEdWeb_Close()
			for Controller in _PWSO.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Index, Window in _PWSO.Windows
				if DllCall("User32\IsWindow", "Ptr", _PWSO.Hwnds[Index], "Int")
					Window.Destroy()
			for Hwnd in _PWSO.Hwnds
				_PWSO_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "Every private native window must retire.")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		_PWSO.Pending := 0, _PWSO.Boundary := 0
		OnError(_PWSO_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_PWSO.Failure)
		Primary := _PWSO.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS paths-editor-startup " . _PWSO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

; The browser port returns a real AHK handle with the same last-reference
; unsubscribe lifetime as the shipped SDK. Native cancellation is unmodified.
class _PWSO_Subscription {
	__New(Callback) {
		global _PWSO
		this.Callback := Callback
		_PWSO.ActiveSubscriptions += 1, _PWSO.CreatedSubscriptions += 1
	}
	__Delete() {
		global _PWSO
		_PWSO.ReleasedInFlight := _PWSO.ReleasedInFlight || _PWSO.InFlight
		_PWSO.ActiveSubscriptions -= 1, _PWSO.ReleasedSubscriptions += 1
	}
}

_PWSO_SubscriptionClose() {
	global _PWSO, _PathsEdWeb_SessionEpoch, _PathsEdWeb_Gui
	Hwnd := _PWSO.Hwnds[1], Epoch := _PathsEdWeb_SessionEpoch
	_PWSO_Require(Epoch > 0 && _PathsEdWeb_Gui == _PWSO.Windows[1]
		&& WinGetPID("ahk_id " . Hwnd) == ProcessExist()
		&& DllCall("IsWindowVisible", "Ptr", Hwnd, "Int"),
		"The add-event actor requires its exact current visible native editor")
	_PWSO.CloseSent += 1
	_PWSO_Require(DllCall("PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int"),
		"The owned editor must admit the genuine WM_CLOSE")
	Started := A_TickCount
	while _PathsEdWeb_SessionEpoch == Epoch && A_TickCount - Started < 1000
		Sleep(10)
	_PWSO.CloseObserved := _PathsEdWeb_SessionEpoch > Epoch && !IsObject(_PathsEdWeb_Gui)
	_PWSO_Require(_PWSO.CloseObserved, "The actual Close must revoke the editor before add-event returns")
}

_PWSO_Subscribe(Callback) {
	global _PWSO
	_PWSO.SubscriptionCalls += 1
	_PWSO.InFlight := true
	try {
		if _PWSO.Mode == "subscription-close"
			_PWSO_SubscriptionClose()
		else if _PWSO.Mode == "subscription-reset-retain" {
			global _PathsEdWeb_Gui
			Window := _PWSO.Windows[1]
			_PathsEdWeb_Reset()
			_PWSO.ResetRetained := _PathsEdWeb_Gui == Window
				&& !!DllCall("IsWindow", "Ptr", _PWSO.Hwnds[1], "Int")
		}
		_PWSO.AliveAtReturn := !!DllCall("IsWindow", "Ptr", _PWSO.Hwnds[1], "Int")
		return _PWSO_Subscription(Callback)
	} finally _PWSO.InFlight := false
}

_PWSO_CheckSubscription() {
	global _PWSO, _PathsEdWeb_Gui, _PathsEdWeb_Controller, _PathsEdWeb_WebView
	global _PathsEdWeb_MsgSub, _PathsEdWeb_NavSub
	Ready := true
	if _PWSO.Mode == "subscription-current" {
		Ready := _PWSO.SubscriptionCalls == 1 && _PWSO.ActiveSubscriptions == 2
			&& _PWSO.Controllers.Length == 1 && _PWSO.Windows.Length == 1
			&& _PathsEdWeb_Gui == _PWSO.Windows[1] && _PathsEdWeb_Controller == _PWSO.Controllers[1]
			&& _PathsEdWeb_WebView == _PWSO.Controllers[1].CoreWebView2
			&& IsSet(_PathsEdWeb_MsgSub) && IsSet(_PathsEdWeb_NavSub)
			&& _PWSO.Controllers[1].CoreWebView2.Navigations == 1 && _PWSO.Controllers[1].Fills >= 1
		_PWSO_SubscriptionClose()
	}
	FileAppend("OBSERVATION paths-editor-subscription mode=" . _PWSO.Mode
		. " calls=" . _PWSO.SubscriptionCalls . " close_sent=" . _PWSO.CloseSent
		. " close_observed=" . _PWSO.CloseObserved . " native_alive_at_return=" . _PWSO.AliveAtReturn
		. " native_alive_at_close=" . _PWSO.AliveAtClose . " active_at_close=" . _PWSO.ActiveAtClose
		. " created=" . _PWSO.CreatedSubscriptions . " released=" . _PWSO.ReleasedSubscriptions
		. " released_in_flight=" . _PWSO.ReleasedInFlight . " controller_closed=" . _PWSO.Controllers[1].Closed
		. " close_calls=" . _PWSO.CloseCalls . " ready=" . Ready . "`n", "*", "UTF-8")
	_PWSO_Require(Ready && _PWSO.Controllers.Length == 1 && _PWSO.Windows.Length == 1
		&& _PWSO.CloseSent == 1 && _PWSO.CloseObserved && _PWSO.SubscriptionCalls == 1,
		"One genuine public browser must reach its actual native cancellation")
	if _PWSO.Mode == "subscription-close"
		_PWSO_Require(_PWSO.Controllers[1].CoreWebView2.Subscriptions == 1
			&& _PWSO.Controllers[1].CoreWebView2.Navigations == 0 && _PWSO.Controllers[1].Fills == 0,
			"A retired add-event must not subscribe again, navigate or Fill")
	_PWSO_Require(_PWSO.AliveAtReturn && _PWSO.AliveAtClose && _PWSO.ActiveAtClose == 0
		&& _PWSO.ActiveSubscriptions == 0 && _PWSO.CreatedSubscriptions == _PWSO.ReleasedSubscriptions
		&& !_PWSO.ReleasedInFlight && _PWSO.Controllers[1].Closed == 1 && _PWSO.CloseCalls == 1,
		"The HWND must survive add-event return and unsubscribe before its controller closes once")
	_PWSO_Require(!DllCall("IsWindow", "Ptr", _PWSO.Hwnds[1], "Int") && !IsObject(_PathsEdWeb_Gui)
		&& !IsSet(_PathsEdWeb_Controller) && !IsSet(_PathsEdWeb_WebView)
		&& !IsSet(_PathsEdWeb_MsgSub) && !IsSet(_PathsEdWeb_NavSub),
		"The exact retired editor must finally release its native and browser resources")
}

_PWSO_Main()
