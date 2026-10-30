; tests/fixtures/changelog_open_generation_body.ahk

; The real native window, host, SDK create and Promise await run unchanged.
; Only browser COM environment/controller effects use passive ports.

_CWOC_Require(Condition, Message := "") {
	if !Condition
		throw Error(Message)
}
_CWOC_Refuse(Condition, Message := "") {
	_CWOC_Require(!Condition, Message)
}
_CWOC_Equal(Expected, Actual, Message := "") {
	if Expected != Actual
		throw Error(Message . ((IsObject(Expected) || IsObject(Actual)) ? " (object identity mismatch)"
			: " (expected " . String(Expected) . ", actual " . String(Actual) . ")"))
}
_CWOC_Phase(Phase) {
	FileAppend("DIAG changelog-opening " . Phase . "`n", "*", "UTF-8")
}
_CWOC_BootError(Failure, Mode) {
	FileAppend("FAIL changelog-opening " . Failure.Message . " at " . Failure.File . ":" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}


; Only the asynchronous COM environment/controller effects are ports. The
; window, host, shared environment owner, SDK create and Promise await are real.
class _CWOC_Core {
	__New() {
		this.Settings := {}
	}
	WebMessageReceived(Callback) => {Callback: Callback}
	NavigationCompleted(Callback) => {Callback: Callback}
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) => 0
}
class _CWOC_Controller {
	__New(Hwnd) {
		_CWOC_Require(DllCall("IsWindow", "ptr", Hwnd, "int"), "the actual SDK call must name a genuine native control")
		this.CoreWebView2 := _CWOC_Core(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}
class _CWOC_Environment {
	__New(Mode) {
		this.Mode := Mode, this.Controllers := [], this.Calls := 0, this.ActorDone := false, this.Reopened := false, this.Fallbacks := 0, this.Fetches := 0
	}
	CreateCoreWebView2ControllerAsync(Hwnd) {
		this.Calls += 1
		Ctrl := _CWOC_Controller(Hwnd)
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
		global _CLW_Gui, _CLW_Controller, _CLW_WindowEpoch
		if this.Mode != "cold-refusal" {
			Changelog_Close()
			if InStr(this.Mode, "reopen") {
				_CWOC_PublicOpen()
				this.Reopened := IsSet(_CLW_Gui) && IsSet(_CLW_Controller)
				_CWOC_Require(this.Reopened, "a second public open must finish while the first SDK await pumps")
				this.SuccessorGui := _CLW_Gui
				this.SuccessorController := _CLW_Controller
				this.SuccessorEpoch := _CLW_WindowEpoch
				_CWOC_Require(DllCall("IsWindow", "ptr", this.SuccessorGui.Hwnd, "int"))
			}
		}
		this.ActorDone := true
		if InStr(this.Mode, "refusal")
			Reject.Call(Error("Explicit native browser creation refusal effect."))
		else
			Resolve.Call(Ctrl)
	}
}
_CWOC_OpenGeneration(Mode) {
	global _WebView_SharedEnv, _WebView_SharedEnvRetired, _CLW_Gui, _CLW_Controller
	global _CLW_WebView, _CLW_ResetDone, _CLW_WindowEpoch
	_CWOC_Refuse(IsSet(_CLW_Gui), "this private entry starts without any active changelog window")
	PreviousEnv := _WebView_SharedEnv, PreviousRetired := _WebView_SharedEnvRetired
	PreviousCritical := Critical("Off")
	Environment := _CWOC_Environment(Mode)
	global _CWOC_CurrentEnvironment := Environment
	_CWOC_Require(!_Updater_OpenChangelogWindow.HasOwnProp("Call") && !_CLW_FetchAndInject.HasOwnProp("Call"), "effect guards begin from the real functions")
	_Updater_OpenChangelogWindow.DefineProp("Call", {Call: _CWOC_NativeFallback})
	_CLW_FetchAndInject.DefineProp("Call", {Call: _CWOC_RejectFetch})
	try {
		_WebView_SharedEnv := Environment, _WebView_SharedEnvRetired := false
		_CWOC_Require(_CLW_WebView2Available(), "the genuine vendored SDK loader must be present")
		Thread("Interrupt", 0)
		_CWOC_PublicOpen()
		if Mode == "cold-success" {
			_CWOC_Require(_CLW_Gui is Gui)
			_CWOC_Equal(Environment.Controllers[1], _CLW_Controller)
			_CWOC_Equal(0, Environment.Controllers[1].Closed)
		} else {
			_CWOC_Require(Environment.ActorDone, "the real Promise await must pump the native timer")
			if InStr(Mode, "reopen") {
				_CWOC_Equal(Environment.SuccessorEpoch, _CLW_WindowEpoch, "a stale catch must not reset its replacement session")
				_CWOC_Equal(Environment.SuccessorGui, _CLW_Gui)
				_CWOC_Equal(Environment.SuccessorController, _CLW_Controller)
				_CWOC_Require(DllCall("IsWindow", "ptr", Environment.SuccessorGui.Hwnd, "int"))
				_CWOC_Equal(0, Environment.SuccessorController.Closed)
			} else {
				_CWOC_Refuse(IsSet(_CLW_Gui))
				_CWOC_Refuse(IsSet(_CLW_Controller))
				_CWOC_Refuse(IsSet(_CLW_WebView))
			}
			if !InStr(Mode, "refusal")
				_CWOC_Equal(1, Environment.Controllers[1].Closed, "the exact late-created controller must retire once")
		}
		_CWOC_Equal(Mode == "cold-refusal" ? 1 : 0, Environment.Fallbacks, "only a current initial refusal may open the native fallback")
		_CWOC_Equal(0, Environment.Fetches, "the constructor component must not fetch releases")
	} finally {
		Changelog_Close()
		for Controller in Environment.Controllers
			if !Controller.Closed
				Controller.Close()
		_Updater_OpenChangelogWindow.DeleteProp("Call")
		_CLW_FetchAndInject.DeleteProp("Call")
		_CWOC_CurrentEnvironment := 0
		_WebView_SharedEnv := PreviousEnv, _WebView_SharedEnvRetired := PreviousRetired
		Critical(PreviousCritical)
	}
}

_CWOC_PublicOpen() {
	Changelog_Open(UpdateChannels_Ids()[1])
}
_CWOC_NativeFallback(Self, Channel, Request) {
	global _CWOC_CurrentEnvironment
	_CWOC_Require(Self == _Updater_OpenChangelogWindow && _Updater_RequestMayPublish(Request), "the native fallback retains actual updater provenance")
	_CWOC_CurrentEnvironment.Fallbacks += 1
}
_CWOC_RejectFetch(Self, Args*) {
	global _CWOC_CurrentEnvironment
	_CWOC_CurrentEnvironment.Fetches += 1
	throw Error("Release fetching is outside the constructor component.")
}

if A_Args.Length != 2 || A_Args[2] != _CWOC_Root
	ExitApp(2)
try {
	Features := ManifestBuildFeaturesMap()
	_CWOC_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The isolated UI role must remain genuinely outside primary configuration admission.")
	LoggerInit()
	_CWOC_OpenGeneration(A_Args[1])
	_CWOC_Require(!FileExist(ConfigurationFile) && !ConfigMigrateBoot(ConfigurationFile, "known"),
		"The UI component must preserve the absent constructor role.")
	FileAppend("PASS changelog-open-generation " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL changelog-opening " . Failure.Message . " at " . Failure.File . ":" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
