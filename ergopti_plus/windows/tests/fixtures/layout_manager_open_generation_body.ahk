; tests/fixtures/layout_manager_open_generation_body.ahk

; The real native window, host, SDK create and Promise await run unchanged.
; Only browser COM environment/controller effects use passive ports.

_LMOC_Require(Condition, Message := "") {
	if !Condition
		throw Error(Message)
}
_LMOC_Refuse(Condition, Message := "") {
	_LMOC_Require(!Condition, Message)
}
_LMOC_Equal(Expected, Actual, Message := "") {
	if Expected != Actual
		throw Error(Message . ((IsObject(Expected) || IsObject(Actual)) ? " (object identity mismatch)"
			: " (expected " . String(Expected) . ", actual " . String(Actual) . ")"))
}
_LMOC_Phase(Phase) {
	FileAppend("DIAG layout-opening " . Phase . "`n", "*", "UTF-8")
}
_LMOC_BootError(Failure, Mode) {
	FileAppend("FAIL layout-opening " . Failure.Message . " at " . Failure.File . ":" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}


; Only the asynchronous COM environment/controller effects are ports. The
; window, host, shared environment owner, SDK create and Promise await are real.
class _LMOC_Core {
	__New() {
		this.Settings := {}
	}
	WebMessageReceived(Callback) => {Callback: Callback}
	NavigationCompleted(Callback) => {Callback: Callback}
	SetVirtualHostNameToFolderMapping(*) => 0
	Navigate(Url) => 0
}
class _LMOC_Controller {
	__New(Hwnd) {
		_LMOC_Require(DllCall("IsWindow", "ptr", Hwnd, "int"), "the actual SDK call must name a genuine native control")
		this.CoreWebView2 := _LMOC_Core(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}
class _LMOC_Environment {
	__New(Mode) {
		this.Mode := Mode, this.Controllers := [], this.Calls := 0, this.ActorDone := false, this.Reopened := false
	}
	CreateCoreWebView2ControllerAsync(Hwnd) {
		this.Calls += 1
		Ctrl := _LMOC_Controller(Hwnd)
		this.Controllers.Push(Ctrl)
		if this.Calls > 1
			return Promise.resolve(Ctrl)
		if this.Mode == "cold-success"
			return Promise.resolve(Ctrl)
		Pending := Promise((Resolve, Reject) => SetTimer(this.Act.Bind(this, Resolve, Reject, Ctrl), -1))
		; The effect port observes its terminal outcome; await still receives the
		; unchanged rejected promise, as in the other native COM fixtures.
		Pending.onSettled((*) => 0, (*) => 0)
		return Pending
	}
	Act(Resolve, Reject, Ctrl) {
		global _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_SessionEpoch
		if this.Mode != "cold-refusal" {
			_LayMgrWeb_Close()
			if InStr(this.Mode, "reopen") {
				this.Reopened := LayoutManager_Open()
				_LMOC_Require(this.Reopened, "a second public open must finish while the first SDK await pumps")
				this.SuccessorGui := _LayMgrWeb_Gui
				this.SuccessorController := _LayMgrWeb_Controller
				this.SuccessorEpoch := _LayMgrWeb_SessionEpoch
				_LMOC_Require(DllCall("IsWindow", "ptr", this.SuccessorGui.Hwnd, "int"))
			}
		}
		this.ActorDone := true
		if InStr(this.Mode, "refusal")
			Reject.Call(Error("Explicit native browser creation refusal effect."))
		else
			Resolve.Call(Ctrl)
	}
}
_LMOC_OpenGeneration(Mode) {
	global _WebView_SharedEnv, _WebView_SharedEnvRetired, _LayMgrWeb_Gui, _LayMgrWeb_Controller
	global _LayMgrWeb_WebView, _LayMgrWeb_ResetDone, _LayMgrWeb_SessionEpoch
	_LMOC_Refuse(!!_LayMgrWeb_Gui, "this private entry starts without any active layout window")
	PreviousEnv := _WebView_SharedEnv, PreviousRetired := _WebView_SharedEnvRetired
	PreviousCritical := Critical("Off")
	Environment := _LMOC_Environment(Mode)
	try {
		_WebView_SharedEnv := Environment, _WebView_SharedEnvRetired := false
		_LMOC_Require(_LayMgrWeb_Available(), "the genuine vendored SDK loader must be present")
		Thread("Interrupt", 0)
		Started := LayoutManager_Open()
		if Mode == "cold-success" {
			_LMOC_Require(_LayMgrWeb_Gui is Gui)
			_LMOC_Equal(Environment.Controllers[1], _LayMgrWeb_Controller)
			_LMOC_Equal(0, Environment.Controllers[1].Closed)
		} else {
			_LMOC_Require(Environment.ActorDone, "the real Promise await must pump the native timer")
			if InStr(Mode, "reopen") {
				_LMOC_Equal(Environment.SuccessorEpoch, _LayMgrWeb_SessionEpoch, "a stale catch must not reset its replacement session")
				_LMOC_Equal(Environment.SuccessorGui, _LayMgrWeb_Gui)
				_LMOC_Equal(Environment.SuccessorController, _LayMgrWeb_Controller)
				_LMOC_Require(DllCall("IsWindow", "ptr", Environment.SuccessorGui.Hwnd, "int"))
				_LMOC_Equal(0, Environment.SuccessorController.Closed)
			} else {
				_LMOC_Refuse(!!_LayMgrWeb_Gui)
				_LMOC_Refuse(IsSet(_LayMgrWeb_Controller))
				_LMOC_Refuse(IsSet(_LayMgrWeb_WebView))
			}
			if !InStr(Mode, "refusal")
				_LMOC_Equal(1, Environment.Controllers[1].Closed, "the exact late-created controller must retire once")
		}
		_LMOC_Equal(Mode == "cold-success", !!Started, "a stale open cannot claim a successful active window")
	} finally {
		_LayMgrWeb_Close()
		for Controller in Environment.Controllers
			if !Controller.Closed
				Controller.Close()
		_WebView_SharedEnv := PreviousEnv, _WebView_SharedEnvRetired := PreviousRetired
		Critical(PreviousCritical)
	}
}

if A_Args.Length != 2 || A_Args[2] != _LMOC_Root
	ExitApp(2)
try {
	Features := ManifestBuildFeaturesMap()
	_LMOC_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The isolated UI role must remain genuinely outside primary configuration admission.")
	LoggerInit()
	_LMOC_OpenGeneration(A_Args[1])
	_LMOC_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The UI component must preserve the absent constructor role.")
	FileAppend("PASS layout-open-generation " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL layout-opening " . Failure.Message . " at " . Failure.File . ":" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
