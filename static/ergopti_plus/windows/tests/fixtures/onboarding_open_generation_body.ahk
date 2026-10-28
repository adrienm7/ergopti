; tests/fixtures/onboarding_open_generation_body.ahk

; The real native window, host, SDK create and Promise await run unchanged.
; Only browser COM environment/controller effects use passive ports.

_OWOC_Require(Condition, Message := "") {
	if !Condition
		throw Error(Message)
}
_OWOC_Refuse(Condition, Message := "") {
	_OWOC_Require(!Condition, Message)
}
_OWOC_Equal(Expected, Actual, Message := "") {
	if Expected != Actual
		throw Error(Message . ((IsObject(Expected) || IsObject(Actual)) ? " (object identity mismatch)"
			: " (expected " . String(Expected) . ", actual " . String(Actual) . ")"))
}
_OWOC_Phase(Phase) {
	FileAppend("DIAG onboarding-opening " . Phase . "`n", "*", "UTF-8")
}
_OWOC_BootError(Failure, Mode) {
	FileAppend("FAIL onboarding-opening " . Failure.Message . " at " . Failure.File . ":" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}


; Only the asynchronous COM environment/controller effects are ports. The
; window, host, shared environment owner, SDK create and Promise await are real.
class _OWOC_Core {
	__New() {
		this.Settings := {}
	}
	WebMessageReceived(Callback) => {Callback: Callback}
	NavigationCompleted(Callback) => {Callback: Callback}
	SetVirtualHostNameToFolderMapping(*) => 0
	Navigate(Url) => 0
}
class _OWOC_Controller {
	__New(Hwnd) {
		_OWOC_Require(DllCall("IsWindow", "ptr", Hwnd, "int"), "the actual SDK call must name a genuine native control")
		this.CoreWebView2 := _OWOC_Core(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}
class _OWOC_Environment {
	__New(Mode) {
		this.Mode := Mode, this.Controllers := [], this.Calls := 0, this.ActorDone := false, this.Reopened := false
	}
	CreateCoreWebView2ControllerAsync(Hwnd) {
		this.Calls += 1
		Ctrl := _OWOC_Controller(Hwnd)
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
		global _ob_gui, _OnbWeb_Controller, _OnbWeb_SessionEpoch
		if this.Mode != "cold-refusal" {
			_OnbWeb_OnClose()
			if InStr(this.Mode, "reopen") {
				this.Reopened := _Onboarding_TryWeb()
				_OWOC_Require(this.Reopened, "a second public open must finish while the first SDK await pumps")
				this.SuccessorGui := _ob_gui
				this.SuccessorController := _OnbWeb_Controller
				this.SuccessorEpoch := _OnbWeb_SessionEpoch
				_OWOC_Require(DllCall("IsWindow", "ptr", this.SuccessorGui.Hwnd, "int"))
			}
		}
		this.ActorDone := true
		if InStr(this.Mode, "refusal")
			Reject.Call(Error("Explicit native browser creation refusal effect."))
		else
			Resolve.Call(Ctrl)
	}
}
_OWOC_OpenGeneration(Mode) {
	global _WebView_SharedEnv, _WebView_SharedEnvRetired, _ob_gui, _OnbWeb_Controller
	global _OnbWeb_WebView, _OnbWeb_ResetDone, _OnbWeb_SessionEpoch
	_OWOC_Refuse(!!_ob_gui, "this private entry starts without any active onboarding window")
	PreviousEnv := _WebView_SharedEnv, PreviousRetired := _WebView_SharedEnvRetired
	PreviousCritical := Critical("Off")
	Environment := _OWOC_Environment(Mode)
	try {
		_WebView_SharedEnv := Environment, _WebView_SharedEnvRetired := false
		_OWOC_Require(_OnbWeb_Available(), "the genuine vendored SDK loader must be present")
		Thread("Interrupt", 0)
		Started := _Onboarding_TryWeb()
		if Mode == "cold-success" {
			_OWOC_Require(_ob_gui is Gui)
			_OWOC_Equal(Environment.Controllers[1], _OnbWeb_Controller)
			_OWOC_Equal(0, Environment.Controllers[1].Closed)
		} else {
			_OWOC_Require(Environment.ActorDone, "the real Promise await must pump the native timer")
			if InStr(Mode, "reopen") {
				_OWOC_Equal(Environment.SuccessorEpoch, _OnbWeb_SessionEpoch, "a stale catch must not reset its replacement session")
				_OWOC_Equal(Environment.SuccessorGui, _ob_gui)
				_OWOC_Equal(Environment.SuccessorController, _OnbWeb_Controller)
				_OWOC_Require(DllCall("IsWindow", "ptr", Environment.SuccessorGui.Hwnd, "int"))
				_OWOC_Equal(0, Environment.SuccessorController.Closed)
			} else {
				_OWOC_Refuse(!!_ob_gui)
				_OWOC_Refuse(IsSet(_OnbWeb_Controller))
				_OWOC_Refuse(IsSet(_OnbWeb_WebView))
			}
			if !InStr(Mode, "refusal")
				_OWOC_Equal(1, Environment.Controllers[1].Closed, "the exact late-created controller must retire once")
		}
		_OWOC_Equal(Mode == "cold-success", !!Started, "a stale open cannot claim a successful active window")
	} finally {
		_OnbWeb_OnClose()
		for Controller in Environment.Controllers
			if !Controller.Closed
				Controller.Close()
		_WebView_SharedEnv := PreviousEnv, _WebView_SharedEnvRetired := PreviousRetired
		Critical(PreviousCritical)
	}
}

if A_Args.Length != 2 || A_Args[2] != _OWOC_Root
	ExitApp(2)
try {
	Features := ManifestBuildFeaturesMap()
	_OWOC_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The isolated UI role must remain genuinely outside primary configuration admission.")
	LoggerInit()
	_OWOC_OpenGeneration(A_Args[1])
	_OWOC_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The UI component must preserve the absent constructor role.")
	FileAppend("PASS onboarding-open-generation " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL onboarding-opening " . Failure.Message . " at " . Failure.File . ":" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
