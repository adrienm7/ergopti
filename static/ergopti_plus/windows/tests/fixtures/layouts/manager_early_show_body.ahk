; tests/fixtures/layouts/manager_early_show_body.ahk

; The real native window, host, SDK create and Promise await run unchanged.
; Only browser COM environment/controller effects use passive ports.

_LMSO_Require(Condition, Message := "") {
	if !Condition
		throw Error(Message)
}
_LMSO_Refuse(Condition, Message := "") {
	_LMSO_Require(!Condition, Message)
}
_LMSO_Equal(Expected, Actual, Message := "") {
	if Expected != Actual
		throw Error(Message . ((IsObject(Expected) || IsObject(Actual)) ? " (object identity mismatch)"
			: " (expected " . String(Expected) . ", actual " . String(Actual) . ")"))
}
_LMSO_Phase(Phase) {
	FileAppend("DIAG layout-opening " . Phase . "`n", "*", "UTF-8")
}
_LMSO_BootError(Failure, Mode) {
	FileAppend("FAIL layout-opening " . Failure.Message . " at " . Failure.File . ":" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}


; Only the asynchronous COM environment/controller effects are ports. The
; window, host, shared environment owner, SDK create and Promise await are real.
class _LMSO_Core {
	__New() {
		this.SettingsValue := {}
	}
	Settings {
		get {
			global _LMSO, _LayMgrWeb_Gui, _LayMgrWeb_SessionEpoch
			global _LayMgrWeb_Controller, _LayMgrWeb_WebView, _LayMgrWeb_MsgSub, _LayMgrWeb_NavSub
			if HasProp(_LMSO, "SettingsMode") {
				_LMSO.SettingsCalls += 1
				Window := _LayMgrWeb_Gui
				if _LMSO.SettingsCalls == 1
					_LMSO.Window := Window, _LMSO.Hwnd := Window.Hwnd
				_LMSO_Require(DllCall("IsWindow", "Ptr", Window.Hwnd, "Int")
					&& WinGetPID("ahk_id " . Window.Hwnd) == ProcessExist(),
					"The browser settings port must still name the exact owned native window")
				if (_LMSO.SettingsMode == "settings-close" || _LMSO.SettingsMode == "settings-reopen") && !_LMSO.ClosePosted {
					_LMSO_Require(!_LMSO.ClosePosted, "The COM boundary may post exactly one native Close")
					_LMSO.ClosePosted := true
					Before := _LayMgrWeb_SessionEpoch
					_LMSO_Require(DllCall("PostMessageW", "Ptr", _LMSO.Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int"),
						"The existing settings effect boundary must accept exact native WM_CLOSE")
					Started := A_TickCount
					while _LayMgrWeb_SessionEpoch == Before && A_TickCount - Started < 1000
						Sleep(1)
					_LMSO.CloseObserved := _LayMgrWeb_SessionEpoch != Before
						&& !DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int")
					if _LMSO.SettingsMode == "settings-reopen" {
						_LMSO_Require(_LMSO.CloseObserved, "The original GUI must retire before public reopening")
						_LMSO_Require(LayoutManager_Open(), "The public constructor must admit the real successor")
						_LMSO.SuccessorGui := _LayMgrWeb_Gui, _LMSO.SuccessorController := _LayMgrWeb_Controller
						_LMSO.SuccessorView := _LayMgrWeb_WebView, _LMSO.SuccessorEpoch := _LayMgrWeb_SessionEpoch
						_LMSO.SuccessorMsg := _LayMgrWeb_MsgSub, _LMSO.SuccessorNav := _LayMgrWeb_NavSub
					}

				}
			}
			return this.SettingsValue
		}
	}
	WebMessageReceived(Callback) {
		global _LMSO, _LayMgrWeb_Controller
		if HasProp(_LMSO, "SettingsMode") && InStr(_LMSO.SettingsMode, "navigation-") == 1 {
			_LMSO.MessageCalls += 1
			return _LMSO_Subscription(Callback, _LayMgrWeb_Controller)
		}
		if !HasProp(_LMSO, "SettingsMode") || !InStr(_LMSO.SettingsMode, "subscription-")
			return {Callback: Callback}
		Controller := _LayMgrWeb_Controller
		_LMSO.PrimaryController := Controller
		_LMSO_SubscriptionBoundary()
		return _LMSO_Subscription(Callback, Controller)
	}
	NavigationCompleted(Callback) {
		global _LMSO, _LayMgrWeb_Controller
		if !HasProp(_LMSO, "SettingsMode") || InStr(_LMSO.SettingsMode, "navigation-") != 1
			return {Callback: Callback}
		Controller := _LayMgrWeb_Controller
		_LMSO_NavigationBoundary()
		return _LMSO_Subscription(Callback, Controller)
	}
	SetVirtualHostNameToFolderMapping(*) => 0
	Navigate(Url) => 0
}

; Passive subscription deletion observes the same unsubscribe-before-Close
; contract as the SDK handle. It does not invoke or simulate a native COM call.
class _LMSO_Subscription {
	__New(Callback, Controller) {
		this.Callback := Callback, this.Controller := Controller
	}
	__Delete() {
		global _LMSO
		_LMSO.Unsubscribed += 1
		if this.Controller.Closed
			_LMSO.UnsubscribedAfterClose += 1
	}
}
_LMSO_SubscriptionBoundary() {
	global _LMSO, _LayMgrWeb_SessionEpoch
	_LMSO.SubscriptionCalls += 1
	if _LMSO.SettingsMode == "subscription-current" || _LMSO.ClosePosted
		return
	_LMSO_Require(_LMSO.SubscriptionCalls == 1 && !_LMSO.ClosePosted,
		"The one subscription effect may post exactly one native Close")
	_LMSO_Require(DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int")
		&& WinGetPID("ahk_id " . _LMSO.Hwnd) == ProcessExist(),
		"The subscription cutpoint must still name its exact owned native GUI")
	_LMSO.ClosePosted := true
	Before := _LayMgrWeb_SessionEpoch
	_LMSO_Require(DllCall("PostMessageW", "Ptr", _LMSO.Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int"),
		"The real GUI must accept native WM_CLOSE while its subscription call is pending")
	Started := A_TickCount
	while _LayMgrWeb_SessionEpoch == Before && A_TickCount - Started < 1000
		Sleep(1)
	; Logical retirement is required here; physical Close/Destroy may correctly
	; wait for the subscription to return before its exact unsubscribe.
	_LMSO.CloseObserved := _LayMgrWeb_SessionEpoch != Before
	_LMSO.AliveAtSubscriptionReturn := !!DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int")
}

class _LMSO_Controller {
	__New(Hwnd) {
		_LMSO_Require(DllCall("IsWindow", "ptr", Hwnd, "int"), "the actual SDK call must name a genuine native control")
		this.CoreWebView2 := _LMSO_Core(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		global _LMSO
		this.CloseAttempts := this.HasOwnProp("CloseAttempts") ? this.CloseAttempts + 1 : 1
		if HasProp(_LMSO, "SettingsMode") && _LMSO.SettingsMode == "subscription-refuse-close"
				&& HasProp(_LMSO, "PrimaryController") && _LMSO.PrimaryController == this && !_LMSO.AllowRetry {
			_LMSO.RefusedCloses += 1
			throw Error("Explicit passive controller Close refusal before its effect")
		}
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}
; The environment only supplies passive browser effects. Native Show/Close and
; the exact registered production Close handler remain genuine.
class _LMSO_Environment {
	__New() {
		this.Controllers := []
	}
	CreateCoreWebView2ControllerAsync(Hwnd) {
		Controller := _LMSO_Controller(Hwnd)
		this.Controllers.Push(Controller)
		return Promise.resolve(Controller)
	}
}

_LMSO_RegisterEvent(Window, Name, Callback, Options*) {
	global _LMSO
	if Name != "Close" || _LMSO.Window != 0
		return _LMSO.Register.Call(Window, Name, Callback, Options*)
	_LMSO.Window := Window, _LMSO.Hwnd := Window.Hwnd
	_LMSO_Require(Options.Length == 0, "The production Close registration must keep its original options.")
	return _LMSO.Register.Call(Window, Name, _LMSO_CloseRelay.Bind(Callback), Options*)
}

_LMSO_CloseRelay(Callback, Params*) {
	; Only genuine native event dispatch invokes this relay; the exact original
	; production handler runs unchanged and retains its genuine return value.
	Result := Callback.Call(Params*)
	_LMSO_CloseAfter(Params*)
	return Result
}

_LMSO_ShowMessage(WParam, LParam, Message, Hwnd) {
	global _LMSO
	if !WParam || Hwnd != _LMSO.Hwnd || _LMSO.ShowSeen
		return
	try {
		_LMSO.ShowSeen := true
		if _LMSO.Mode != "current" {
			_LMSO_Require(!_LMSO.Returned && _LMSO.Environment.Controllers.Length == 0,
				"Native Show must precede public return and all browser construction.")
			_LMSO_Require(DllCall("User32\PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int"),
				"The exact native window must accept genuine WM_CLOSE.")
		}
	} catch Any as Failure {
		_LMSO.Failure := Failure
	}
}

_LMSO_CloseAfter(Window) {
	global _LMSO, _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_SessionEpoch
	if Window != _LMSO.Window || _LMSO.Returned
		return
	try {
		Critical("On")
		_LMSO.CloseSeen += 1
		_LMSO_Require(_LMSO.ShowSeen && _LMSO.Environment.Controllers.Length == 0,
			"The original production Close callback must finish during native Show, before SDK creation.")
		_LMSO.AfterCloseEpoch := _LayMgrWeb_SessionEpoch
		_LMSO.OldExistsAfterClose := DllCall("User32\IsWindow", "Ptr", _LMSO.Hwnd, "Int")
		if _LMSO.Mode == "reopen" {
			_LMSO_Require(LayoutManager_Open(), "The same public entry must open a successor during native Close.")
			_LMSO.SuccessorGui := _LayMgrWeb_Gui
			_LMSO.SuccessorController := _LayMgrWeb_Controller
			_LMSO.SuccessorEpoch := _LayMgrWeb_SessionEpoch
		}
	} catch Any as Failure {
		_LMSO.Failure := Failure
	}
}

_LMSO_OpenGeneration(Mode) {
	global _LMSO, _WebView_SharedEnv, _WebView_SharedEnvRetired
	global _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_WebView, _LayMgrWeb_SessionEpoch
	_LMSO_Refuse(!!_LayMgrWeb_Gui, "This private entry starts without an active layout window.")
	PreviousEnv := _WebView_SharedEnv, PreviousRetired := _WebView_SharedEnvRetired
	PreviousCritical := Critical("Off")
	PreviousRegister := Gui.Prototype.GetOwnPropDesc("OnEvent")
	Environment := _LMSO_Environment()
	_LMSO := {Mode: Mode, Window: 0, Hwnd: 0, Returned: false, CloseSeen: 0, ShowSeen: false,
		Environment: Environment, Failure: 0, Register: PreviousRegister.Call}
	try {
		_WebView_SharedEnv := Environment, _WebView_SharedEnvRetired := false
		_LMSO_Require(_LayMgrWeb_Available(), "The genuine vendored SDK loader must be present.")
		Gui.Prototype.DefineProp("OnEvent", {Call: _LMSO_RegisterEvent})
		OnMessage(0x18, _LMSO_ShowMessage)
		Thread("Interrupt", 0)
		Started := LayoutManager_Open()
		_LMSO.Returned := true
		if IsObject(_LMSO.Failure)
			throw _LMSO.Failure
		_LMSO_Require(_LMSO.ShowSeen, "The exact real native Show must be observed.")
		if Mode == "current" {
			_LMSO_Require(Started && _LayMgrWeb_Gui == _LMSO.Window)
			_LMSO_Equal(1, Environment.Controllers.Length)
			_LMSO_Equal(Environment.Controllers[1], _LayMgrWeb_Controller)
			_LMSO_Equal(0, Environment.Controllers[1].Closed)
		} else {
			_LMSO_Equal(1, _LMSO.CloseSeen, "The exact original Close callback must finish before public return.")
			_LMSO_Refuse(_LMSO.OldExistsAfterClose,
				"Native Close during Show must destroy the exact original window before its frame resumes.")
			_LMSO_Refuse(DllCall("User32\IsWindow", "Ptr", _LMSO.Hwnd, "Int"))
			_LMSO_Refuse(!!Started, "A retired public opening must not claim an active window.")
			if Mode == "reopen" {
				_LMSO_Equal(_LMSO.SuccessorGui, _LayMgrWeb_Gui)
				_LMSO_Equal(_LMSO.SuccessorController, _LayMgrWeb_Controller)
				_LMSO_Equal(_LMSO.SuccessorEpoch, _LayMgrWeb_SessionEpoch)
				_LMSO_Equal(1, Environment.Controllers.Length,
					"Only the genuine successor may construct a browser.")
			} else {
				_LMSO_Refuse(!!_LayMgrWeb_Gui)
				_LMSO_Refuse(IsSet(_LayMgrWeb_Controller))
				_LMSO_Refuse(IsSet(_LayMgrWeb_WebView))
				_LMSO_Equal(0, Environment.Controllers.Length,
					"A closed native Show must not start browser construction.")
			}
		}
	} finally {
		OnMessage(0x18, _LMSO_ShowMessage, 0)
		Gui.Prototype.DefineProp("OnEvent", PreviousRegister)
		_LayMgrWeb_Close()
		if IsObject(_LMSO.Window)
			try _LMSO.Window.Destroy()
		if HasProp(_LMSO, "SuccessorGui")
			try _LMSO.SuccessorGui.Destroy()
		for Controller in Environment.Controllers
			if !Controller.Closed
				Controller.Close()
		_WebView_SharedEnv := PreviousEnv, _WebView_SharedEnvRetired := PreviousRetired
		Critical(PreviousCritical)
	}
}



_LMSO_DestroyAfterNative(Window, Args*) {
	global _LMSO
	Target := IsObject(_LMSO.Window) && Window == _LMSO.Window
	if Target
		_LMSO.DestroyAttempts += 1
	_LMSO.DestroyReal.Call(Window, Args*)
	if Target && !_LMSO.DestroyThrew {
		_LMSO.DestroyGoneBeforeThrow := !DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int")
		_LMSO.DestroyThrew := true
		throw Error("Explicit port exception after genuine native Gui.Destroy completed")
	}
	if Target
		_LMSO.DestroyRetryReturned := true
}
_LMSO_PendingOriginal() {
	global _LMSO, _LayMgrWeb_RetiredHosts
	Count := 0
	for Host in _LayMgrWeb_RetiredHosts
		if Host.gui == _LMSO.Window
			Count += 1
	return Count
}
_LMSO_RetirementCheck(Environment, Mode, Started, OpeningFailure) {
	global _LMSO, _LayMgrWeb_Gui, _LayMgrWeb_Controller
	_LMSO_Require(_LMSO.SubscriptionCalls == 1 && _LMSO.ClosePosted && _LMSO.CloseObserved
		&& _LMSO.Unsubscribed == 1 && _LMSO.UnsubscribedAfterClose == 0,
		"The real native Close must be acknowledged and its returned handle retired before the failure port")
	_LMSO_Require(!IsObject(OpeningFailure) && !Started && !_LayMgrWeb_Gui,
		"The withdrawn opening must return cancellation without republishing its host")
	_LMSO_Equal(1, Environment.Controllers.Length)
	OldController := Environment.Controllers[1]
	if Mode == "subscription-refuse-close" {
		_LMSO_Require(_LMSO.RefusedCloses == 1 && OldController.Closed == 0
			&& DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int"),
			"A refused passive Close must keep the exact native HWND and controller available for retry")
	} else {
		_LMSO_Require(_LMSO.DestroyThrew && _LMSO.DestroyGoneBeforeThrow && OldController.Closed == 1,
			"The injected exception must follow genuine native destruction and the one acknowledged controller Close")
	}
	_LMSO_Equal(1, _LMSO_PendingOriginal(), "Only the exact unsettled host must remain pending")
	_LMSO.AllowRetry := true
	_LMSO_Require(LayoutManager_Open(), "The public opening must retry retirement then admit a real successor")
	FileAppend("OBSERVATION layout-retirement mode=" . Mode . " close_attempts=" . OldController.CloseAttempts
		. " controller_closed=" . OldController.Closed . " destroy_attempts=" . _LMSO.DestroyAttempts
		. " native_gone_before_throw=" . _LMSO.DestroyGoneBeforeThrow . " retry_destroy_returned=" . _LMSO.DestroyRetryReturned
		. " pending_original=" . _LMSO_PendingOriginal() . " controllers=" . Environment.Controllers.Length . "`n", "*")
	_LMSO_Equal(0, _LMSO_PendingOriginal(), "The exact old host must settle; an already destroyed native GUI cannot retain eternal debt")
	_LMSO_Equal(1, OldController.Closed, "A retry after acknowledged Close cannot close the old controller twice")
	_LMSO_Equal(Mode == "subscription-refuse-close" ? 2 : 1, OldController.CloseAttempts)
	if Mode == "subscription-destroy-throw"
		_LMSO_Require(_LMSO.DestroyRetryReturned, "The genuine native Destroy retry must return, rather than inferring idempotence")
	_LMSO_Require(Environment.Controllers.Length == 2 && _LayMgrWeb_Controller == Environment.Controllers[2]
		&& _LayMgrWeb_Gui != _LMSO.Window && DllCall("IsWindow", "Ptr", _LayMgrWeb_Gui.Hwnd, "Int")
		&& Environment.Controllers[2].Closed == 0, "The current successor must retain its independent live owner")
}

; The browser property is an existing COM-effect port; only its delivery of a
; genuine WM_CLOSE is controlled. No actual WebView2 RPC pump is claimed here.
_LMSO_SettingsGeneration(Mode) {
	global _LMSO, _WebView_SharedEnv, _WebView_SharedEnvRetired
	global _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_WebView, _LayMgrWeb_SessionEpoch
	global _LayMgrWeb_MsgSub, _LayMgrWeb_NavSub
	_LMSO_Refuse(!!_LayMgrWeb_Gui, "A settings opening starts without a foreign native host")
	PreviousEnv := _WebView_SharedEnv, PreviousRetired := _WebView_SharedEnvRetired
	PreviousCritical := Critical("Off"), Environment := _LMSO_Environment()
	_LMSO := {SettingsMode: Mode, SettingsCalls: 0, Window: 0, Hwnd: 0, ClosePosted: false, CloseObserved: false,
		SubscriptionCalls: 0, Unsubscribed: 0, UnsubscribedAfterClose: 0, AliveAtSubscriptionReturn: false,
		AllowRetry: false, RefusedCloses: 0, DestroyAttempts: 0, DestroyThrew: false, DestroyGoneBeforeThrow: false, DestroyRetryReturned: false}
	Started := false, OpeningFailure := 0
	DestroyDescriptor := Gui.Prototype.GetOwnPropDesc("Destroy")
	_LMSO.DestroyReal := DestroyDescriptor.Call
	try {
		if Mode == "subscription-destroy-throw"
			Gui.Prototype.DefineProp("Destroy", {Call: _LMSO_DestroyAfterNative})
		_WebView_SharedEnv := Environment, _WebView_SharedEnvRetired := false
		_LMSO_Require(_LayMgrWeb_Available(), "The genuine vendored SDK loader must be present")
		Thread("Interrupt", 0)
		try Started := LayoutManager_Open()
		catch Any as Failure
			OpeningFailure := Failure
		if Mode == "subscription-refuse-close" || Mode == "subscription-destroy-throw" {
			_LMSO_RetirementCheck(Environment, Mode, Started, OpeningFailure)
			return
		}
		FileAppend("OBSERVATION layout-settings mode=" . Mode . " settings_calls=" . _LMSO.SettingsCalls
			. " close_posted=" . _LMSO.ClosePosted . " close_observed=" . _LMSO.CloseObserved
			. " controllers=" . Environment.Controllers.Length . " started=" . Started
			. " caught=" . (IsObject(OpeningFailure) ? Type(OpeningFailure) : "none") . "`n", "*")
		if InStr(Mode, "subscription-")
			_LMSO_Equal(1, _LMSO.SubscriptionCalls, "The actual host must reach its real subscription boundary exactly once")
		if Mode == "subscription-close" {
			_LMSO_Require(_LMSO.SubscriptionCalls == 1 && _LMSO.ClosePosted && _LMSO.CloseObserved,
				"The pending real-subscription boundary must observe the original native Close handler")
			StartedRetirement := A_TickCount
			while (DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int") || !Environment.Controllers[1].Closed)
				&& A_TickCount - StartedRetirement < 1000
				Sleep(1)
			FileAppend("OBSERVATION layout-subscription calls=" . _LMSO.SubscriptionCalls
				. " close_observed=" . _LMSO.CloseObserved . " native_alive_at_return=" . _LMSO.AliveAtSubscriptionReturn
				. " unsubscribed=" . _LMSO.Unsubscribed . " unsubscribe_after_close=" . _LMSO.UnsubscribedAfterClose
				. " controller_closed=" . Environment.Controllers[1].Closed . "`n", "*")
			_LMSO_Require(_LMSO.Unsubscribed == 1 && _LMSO.UnsubscribedAfterClose == 0,
				"The late returned handle must unsubscribe exactly once while its controller is still live")
		}
		ExpectedControllers := Mode == "settings-reopen" ? 2 : 1
		_LMSO_Equal(ExpectedControllers, _LMSO.SettingsCalls, "Every real host must reach its actual settings property exactly once")
		_LMSO_Equal(ExpectedControllers, Environment.Controllers.Length, "The settings cutpoint requires genuine SDK controller creation")
		if Mode == "settings-reopen" {
			_LMSO_Require(_LMSO.ClosePosted && _LMSO.CloseObserved && HasProp(_LMSO, "SuccessorGui"),
				"The original native Close and genuine successor must finish before the old continuation resumes")
			_LMSO_Equal(1, Environment.Controllers[1].Closed)
			_LMSO_Refuse(IsObject(OpeningFailure) || !!Started, "The retired opening may neither throw nor claim its successor")
			_LMSO_Require(_LayMgrWeb_Gui == _LMSO.SuccessorGui && _LayMgrWeb_Controller == _LMSO.SuccessorController
				&& _LayMgrWeb_WebView == _LMSO.SuccessorView && _LayMgrWeb_SessionEpoch == _LMSO.SuccessorEpoch,
				"The returning old frame must preserve the exact successor GUI/controller/view/epoch")
			_LMSO_Require(_LayMgrWeb_MsgSub == _LMSO.SuccessorMsg && _LayMgrWeb_NavSub == _LMSO.SuccessorNav,
				"The old settings frame cannot replace its successor's real subscription handles")
			_LMSO_Require(DllCall("IsWindow", "Ptr", _LMSO.SuccessorGui.Hwnd, "Int")
				&& _LMSO.SuccessorController.Closed == 0 && _LMSO.SuccessorController.Fills == 1,
				"Only the successor may fill its live controller exactly once")
		} else if Mode == "settings-close" || Mode == "subscription-close" {
			_LMSO_Require(_LMSO.ClosePosted && _LMSO.CloseObserved,
				"A genuine native Close must retire its exact GUI and epoch before judging the older opening")
			_LMSO_Equal(1, Environment.Controllers[1].Closed, "The exact admitted controller must close once")
			_LMSO_Refuse(DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int"), "Physical retirement must finish after pending subscriptions settle")
			_LMSO_Refuse(IsObject(OpeningFailure), "A retired settings continuation must return cancellation rather than dereferencing withdrawn globals")
			_LMSO_Refuse(!!Started || !!_LayMgrWeb_Gui || IsSet(_LayMgrWeb_Controller) || IsSet(_LayMgrWeb_WebView),
				"A genuinely closed host cannot report a live opening or republish its controller")
		} else {
			_LMSO_Refuse(IsObject(OpeningFailure), "The current settings continuation must remain usable")
			_LMSO_Require(Started && _LayMgrWeb_Gui == _LMSO.Window
				&& _LayMgrWeb_Controller == Environment.Controllers[1]
				&& DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int"), "The current opening must retain its exact native owner")
			_LMSO_Equal(0, Environment.Controllers[1].Closed)
		}
	} finally {
		Gui.Prototype.DefineProp("Destroy", DestroyDescriptor)
		_LMSO.AllowRetry := true
		_LayMgrWeb_Close()
		_LayMgrWeb_RetryRetiredHosts()
		if InStr(Mode, "subscription-") && IsSet(_LayMgrWeb_MsgSub)
			_LayMgrWeb_MsgSub := unset
		for Controller in Environment.Controllers
			if !Controller.Closed
				Controller.Close()
		if IsObject(_LMSO.Window)
			try _LMSO.Window.Destroy()
		if HasProp(_LMSO, "SuccessorGui")
			try _LMSO.SuccessorGui.Destroy()
		_WebView_SharedEnv := PreviousEnv, _WebView_SharedEnvRetired := PreviousRetired
		Critical(PreviousCritical)
	}
}


_LMSO_NavigationBoundary() {
	global _LMSO, _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_WebView
	global _LayMgrWeb_SessionEpoch, _LayMgrWeb_MsgSub, _LayMgrWeb_NavSub
	_LMSO.NavigationCalls += 1
	if _LMSO.ClosePosted
		return
	_LMSO_Require(_LMSO.NavigationCalls == 1 && _LMSO.MessageCalls == 1 && IsSet(_LayMgrWeb_MsgSub)
		&& IsObject(_LayMgrWeb_MsgSub), "The first genuine message handle must already be carried before navigation subscribes")
	_LMSO_Require(DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int")
		&& WinGetPID("ahk_id " . _LMSO.Hwnd) == ProcessExist(), "Only the exact owned native window may receive Close")
	_LMSO.ClosePosted := true
	Before := _LayMgrWeb_SessionEpoch
	_LMSO_Require(DllCall("PostMessageW", "Ptr", _LMSO.Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int"),
		"The navigation effect port must deliver genuine native WM_CLOSE")
	Started := A_TickCount
	while _LayMgrWeb_SessionEpoch == Before && A_TickCount - Started < 1000
		Sleep(1)
	_LMSO.CloseObserved := _LayMgrWeb_SessionEpoch != Before
	_LMSO_Require(_LMSO.CloseObserved, "The real Close handler must withdraw its epoch before navigation returns")
	if _LMSO.SettingsMode == "navigation-reopen" {
		_LMSO_Require(LayoutManager_Open(), "The public constructor must admit B while A still owns its pending navigation call")
		_LMSO.SuccessorGui := _LayMgrWeb_Gui, _LMSO.SuccessorController := _LayMgrWeb_Controller
		_LMSO.SuccessorView := _LayMgrWeb_WebView, _LMSO.SuccessorEpoch := _LayMgrWeb_SessionEpoch
		; Identity scalars preserve the oracle without keeping an unsubscribe
		; handle alive past B's own final native Close during fixture cleanup.
		_LMSO.SuccessorMsgPtr := ObjPtr(_LayMgrWeb_MsgSub), _LMSO.SuccessorNavPtr := ObjPtr(_LayMgrWeb_NavSub)
	}
}
_LMSO_NavigationGeneration(Mode) {
	global _LMSO, _WebView_SharedEnv, _WebView_SharedEnvRetired
	global _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_WebView, _LayMgrWeb_SessionEpoch
	global _LayMgrWeb_MsgSub, _LayMgrWeb_NavSub
	_LMSO_Refuse(!!_LayMgrWeb_Gui, "A navigation opening cannot borrow a foreign native host")
	PreviousEnv := _WebView_SharedEnv, PreviousRetired := _WebView_SharedEnvRetired
	PreviousCritical := Critical("Off"), Environment := _LMSO_Environment()
	_LMSO := {SettingsMode: Mode, SettingsCalls: 0, Window: 0, Hwnd: 0, ClosePosted: false, CloseObserved: false,
		MessageCalls: 0, NavigationCalls: 0, Unsubscribed: 0, UnsubscribedAfterClose: 0, AllowRetry: true}
	Started := false, OpeningFailure := 0, Threw := false
	try {
		_WebView_SharedEnv := Environment, _WebView_SharedEnvRetired := false
		_LMSO_Require(_LayMgrWeb_Available(), "The genuine SDK loader must be available")
		Thread("Interrupt", 0)
		try Started := LayoutManager_Open()
		catch Any as Failure {
			OpeningFailure := Failure, Threw := true
		}
		Expected := Mode == "navigation-reopen" ? 2 : 1
		FileAppend("OBSERVATION layout-navigation mode=" . Mode . " messages=" . _LMSO.MessageCalls
			. " navigations=" . _LMSO.NavigationCalls . " close_observed=" . _LMSO.CloseObserved
			. " unsubscribed=" . _LMSO.Unsubscribed . " unsubscribe_after_close=" . _LMSO.UnsubscribedAfterClose
			. " controllers=" . Environment.Controllers.Length . " started=" . Started . " threw=" . Threw . "`n", "*")
		_LMSO_Require(_LMSO.ClosePosted && _LMSO.CloseObserved && _LMSO.MessageCalls == Expected
			&& _LMSO.NavigationCalls == Expected && Environment.Controllers.Length == Expected,
			"The actual carried-message and navigation-subscription paths must reach their exact native Close and optional successor")
		_LMSO_Require(!Threw && !Started && _LMSO.Unsubscribed == 2 && _LMSO.UnsubscribedAfterClose == 0,
			"Both original handles must unsubscribe before old controller Close; its frame must return cancellation")
		_LMSO_Require(Environment.Controllers[1].Closed == 1 && !DllCall("IsWindow", "Ptr", _LMSO.Hwnd, "Int"),
			"The exact original controller and HWND must retire once after navigation returns")
		if Mode == "navigation-reopen" {
			_LMSO_Require(HasProp(_LMSO, "SuccessorGui") && _LayMgrWeb_Gui == _LMSO.SuccessorGui
				&& _LayMgrWeb_Controller == _LMSO.SuccessorController && _LayMgrWeb_WebView == _LMSO.SuccessorView
				&& _LayMgrWeb_SessionEpoch == _LMSO.SuccessorEpoch,
				"The old navigation continuation cannot replace B's exact GUI/controller/view/epoch")
			_LMSO_Require(ObjPtr(_LayMgrWeb_MsgSub) == _LMSO.SuccessorMsgPtr && ObjPtr(_LayMgrWeb_NavSub) == _LMSO.SuccessorNavPtr
				&& DllCall("IsWindow", "Ptr", _LMSO.SuccessorGui.Hwnd, "Int")
				&& _LMSO.SuccessorController.Closed == 0 && _LMSO.SuccessorController.Fills == 1,
				"B must retain both independent handles and its one native fill")
		} else
			_LMSO_Require(!_LayMgrWeb_Gui && !IsSet(_LayMgrWeb_Controller) && !IsSet(_LayMgrWeb_WebView)
				&& !IsSet(_LayMgrWeb_MsgSub) && !IsSet(_LayMgrWeb_NavSub), "A closed A cannot republish either late handle")
	} finally {
		_LayMgrWeb_Close()
		_LayMgrWeb_RetryRetiredHosts()
		_LayMgrWeb_MsgSub := unset, _LayMgrWeb_NavSub := unset
		for Controller in Environment.Controllers
			if !Controller.Closed
				Controller.Close()
		if IsObject(_LMSO.Window)
			try _LMSO.Window.Destroy()
		if HasProp(_LMSO, "SuccessorGui")
			try _LMSO.SuccessorGui.Destroy()
		_WebView_SharedEnv := PreviousEnv, _WebView_SharedEnvRetired := PreviousRetired
		Critical(PreviousCritical)
	}
}

if A_Args.Length != 2 || A_Args[2] != _LMSO_Root
	ExitApp(2)
try {
	Features := ManifestBuildFeaturesMap()
	_LMSO_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The isolated UI role must remain genuinely outside primary configuration admission.")
	LoggerInit()
	if A_Args[1] == "navigation-close" || A_Args[1] == "navigation-reopen"
		_LMSO_NavigationGeneration(A_Args[1])
	else if A_Args[1] == "settings-current" || A_Args[1] == "settings-close" || A_Args[1] == "settings-reopen"
		|| A_Args[1] == "subscription-current" || A_Args[1] == "subscription-close"
		|| A_Args[1] == "subscription-refuse-close" || A_Args[1] == "subscription-destroy-throw"
		_LMSO_SettingsGeneration(A_Args[1])
	else
		_LMSO_OpenGeneration(A_Args[1])
	_LMSO_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The UI component must preserve the absent constructor role.")
	FileAppend("PASS layout-early-show " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as _LMSO_Fatal {
	FileAppend("FAIL layout-opening " . _LMSO_Fatal.Message . " at " . _LMSO_Fatal.File . ":" . _LMSO_Fatal.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
