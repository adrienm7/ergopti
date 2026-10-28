; tests/fixtures/layout_manager_early_show_body.ahk

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
		this.Settings := {}
	}
	WebMessageReceived(Callback) => {Callback: Callback}
	NavigationCompleted(Callback) => {Callback: Callback}
	SetVirtualHostNameToFolderMapping(*) => 0
	Navigate(Url) => 0
}
class _LMSO_Controller {
	__New(Hwnd) {
		_LMSO_Require(DllCall("IsWindow", "ptr", Hwnd, "int"), "the actual SDK call must name a genuine native control")
		this.CoreWebView2 := _LMSO_Core(), this.Closed := 0, this.Fills := 0
	}
	Close() {
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

if A_Args.Length != 2 || A_Args[2] != _LMSO_Root
	ExitApp(2)
try {
	Features := ManifestBuildFeaturesMap()
	_LMSO_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The isolated UI role must remain genuinely outside primary configuration admission.")
	LoggerInit()
	_LMSO_OpenGeneration(A_Args[1])
	_LMSO_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The UI component must preserve the absent constructor role.")
	FileAppend("PASS layout-early-show " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as _LMSO_Fatal {
	FileAppend("FAIL layout-opening " . _LMSO_Fatal.Message . " at " . _LMSO_Fatal.File . ":" . _LMSO_Fatal.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
