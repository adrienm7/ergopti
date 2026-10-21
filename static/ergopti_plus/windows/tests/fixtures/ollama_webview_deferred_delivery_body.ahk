; tests/fixtures/ollama_webview_deferred_delivery_body.ahk

; ==============================================================================
; MODULE: Ollama Deferred Delivery Child
; DESCRIPTION:
; Native one-shot timers deliver the real public API calls across a pause.
; A private real GUI and bootstrap own the session; COM/process ports stay
; passive. The full suspend teardown and browser DOM execution are not claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

class _ODL_ScriptOutcome {
	__New(View) {
		this.View := View
	}
	onSettled(Success, Failure) {
		this.View.ObserverCalls += 1
		if this.View.RejectObserver {
			this.View.ObserverRefusals += 1
			throw Error("Private observer refused after accepted submission.")
		}
		try Success.Call("null")
		catch as Err {
			this.View.Failure := Err
			throw Err
		}
		this.View.Settled += 1
	}
}

class _ODL_View {
	__New() {
		this.Scripts := []
		this.Settled := 0
		this.Failure := 0
		this.ObserverCalls := 0, this.ObserverRefusals := 0
		this.RejectObserver := false, this.PausedSubmissions := 0
	}
	ExecuteScriptAsync(Script) {
		if A_IsSuspended
			this.PausedSubmissions += 1
		this.Scripts.Push(Script)
		return _ODL_ScriptOutcome(this)
	}
}

class _ODL_Controller {
	Closed := 0
	Close() {
		this.Closed += 1
	}
}

class _ODL_Args {
	Reads := 0
	TryGetWebMessageAsString() {
		this.Reads += 1
		return "ready"
	}
}

class _ODL_Files {
	Owned := false
	Cancelled := 0
	Run(Action, Request, Authority, Done) {
		_ODL_Require(Action == "inspect", "the passive process boundary admits only initial inspection")
		_ODL_Require(Authority["authorize"].Call(Action, Request), "the real bootstrap must admit its inspection")
		this.Owned := true
		return true
	}
	HasOwner() {
		return this.Owned
	}
	Cancel() {
		this.Cancelled += 1
		this.Owned := false
		return true
	}
}

class _ODL_Runtime {
	Stops := 0
	HasOwner() {
		return false
	}
	Stop() {
		this.Stops += 1
		return true
	}
}

_ODL_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_ODL_AsyncError(Failure, Mode) {
	global _ODL_World
	if IsObject(_ODL_World) {
		_ODL_World.AsyncFailure := Failure
		return 1
	}
}

_ODL_DependencyReady(World) {
	World.ReadyChecks += 1
	return false
}

_ODL_DependencyCheck(World, Model, Ready, Failed, ShowUi) {
	global _LLM_Deps_Epoch, _LLM_Deps_Checking
	World.Checks += 1
	_ODL_Require(ShowUi && Model == "", "the real menu bootstrap must request its visible current operation")
	World.Files := _ODL_Files(), World.Runtime := _ODL_Runtime()
	Port := Map("plan", Map("ManagedRoot", A_Args[2], "CataloguePath", A_Args[2] . "\unused.json",
		"CatalogueSha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"AssetId", "windows-amd64", "deadline_ms", 60000),
		"files", World.Files, "runtime", World.Runtime, "clock", () => A_TickCount, "current", (*) => true)
	World.Flow := OllamaManagedBootstrap(Model, _LLM_Deps_Epoch, Ready, Failed, Port)
	_LLM_Deps_Checking := true
	_ODL_Require(World.Flow.Begin(), "the actual bootstrap must retain an admitted inspection")
	; This is the existing dependency port's passive UI boundary. The public
	; Show API still owns the actual queue; _Ui/Create/browser timing is not run.
	OllamaWV_Show("ollama_install", "delivery fixture")
}

_ODL_Ready(World) {
	World.ReadyCalls += 1
	OllamaWV_OnWebMessage(World.View, World.Args)
}

_ODL_Resume(World) {
	global _LLM_Menu, _LifecycleLatestTransition, _LLM_MenuBuildCoordinator
	Suspend(false)
	_ODL_Require(Ergopti_OnSuspendResume(), "the real resume reactor must finish without owner debt")
	World.Resumes += 1
	_ODL_Require(_LifecycleLatestTransition.phase == "resume" && _LifecycleLatestTransition.finished
		&& _LifecycleLatestTransition.debt.Length == 0, "a failed hook cannot masquerade as a completed resume")
	_ODL_Require(!_LLM_Menu["bootstrap_pending"], "resume must observe the state produced by the actual bootstrap")
	_ODL_Require(_LLM_MenuBuildCoordinator is LLMMenuBuildCoordinator,
		"the real menu resume hook must reach its actual build service")
}

_ODL_Pump(World, Expected) {
	Started := A_TickCount
	while World.View.Settled < Expected && TickElapsed(Started) < 1000
		Sleep(5)
	if IsObject(World.AsyncFailure)
		throw World.AsyncFailure
	if IsObject(World.View.Failure)
		throw World.View.Failure
}

_ODL_Current(World) {
	global _OllamaWV_Epoch, _OllamaWV_WebView, _OllamaWV_Gui
	return _OllamaWV_Epoch == World.Epoch && IsSet(_OllamaWV_WebView)
		&& _OllamaWV_WebView == World.View && IsSet(_OllamaWV_Gui)
		&& _OllamaWV_Gui == World.Gui && OllamaWV_IsAlive()
}

_ODL_Report(World, Mode) {
	global _OllamaWV_Ready, _OllamaWV_Queue
	FileAppend("RECEIPT mode=" . Mode . " ready_calls=" . World.ReadyCalls
		. " pauses=" . World.Pauses . " resumes=" . World.Resumes . " pulses=" . World.Pulses
		. " admitted=" . World.Admitted . " scripts_before_resume=" . World.BeforeResume
		. " ready=" . _OllamaWV_Ready . " queued=" . _OllamaWV_Queue.Length
		. " scripts=" . World.View.Scripts.Length . " settled=" . World.View.Settled
		. " observers=" . World.View.ObserverCalls . " observer_refusals=" . World.View.ObserverRefusals
		. " paused_submissions=" . World.View.PausedSubmissions . "`n", "*", "UTF-8")
}

_ODL_Pulse(World) {
	World.Pulses += 1
}

; Observe actual timer dispatch while retaining and physically retiring our own
; sentinel. A native pause does not stop the production one-shot timers.
_ODL_Observe(World) {
	PulsesBefore := World.Pulses
	Pulse := _ODL_Pulse.Bind(World)
	try {
		SetTimer(Pulse, 10)
		Started := A_TickCount
		while TickElapsed(Started) < 100
			Sleep(5)
	} finally SetTimer(Pulse, 0)
	_ODL_Require(World.Pulses - PulsesBefore >= 3, "each observation must actually deliver the independent native timer")
	if IsObject(World.AsyncFailure)
		throw World.AsyncFailure
	if IsObject(World.View.Failure)
		throw World.View.Failure
}

_ODL_Pause(World) {
	_ODL_Require(!A_IsSuspended, "each pause must start from the actual active state")
	Suspend(true)
	World.Pauses += 1
	_ODL_Require(A_IsSuspended, "the production delivery guard must see native Suspend")
}

_ODL_CheckScripts(View, Expected) {
	_ODL_Require(View.Scripts.Length == Expected.Length, "every admitted script must be delivered exactly once")
	for Index, Script in Expected
		_ODL_Require(View.Scripts[Index] == Script, "locale, public state and append-only log calls must retain FIFO order")
	_ODL_Require(View.PausedSubmissions == 0, "no native submission may occur while suspended")
}

_ODL_NewPage(World) {
	global _OllamaWV_Gui, _OllamaWV_WebView, _OllamaWV_Controller, _OllamaWV_Epoch
	World.Gui := Gui("+ToolWindow", "Private Ollama deferred delivery component")
	World.Gui.Show("NA w80 h40 x-32000 y-32000")
	World.GuiHwnd := World.Gui.Hwnd
	World.View := _ODL_View(), World.Controller := _ODL_Controller()
	_OllamaWV_Gui := World.Gui, _OllamaWV_WebView := World.View, _OllamaWV_Controller := World.Controller
	_OllamaWV_Epoch += 1, World.Epoch := _OllamaWV_Epoch
}

_ODL_Run(World, Mode) {
	global _LLM_Menu, _OllamaWV_Ready, _OllamaWV_Queue
	_ODL_Require(World.Checks == 1 && World.ReadyChecks == 1 && !World.Flow.Cancelled,
		"the actual current menu bootstrap must dispatch exactly one retained operation")
	_ODL_Require(!_LLM_Menu["bootstrap_pending"] && !_OllamaWV_Ready
		&& _ODL_Current(World) && _OllamaWV_Queue.Length == 1,
		"the actual menu bootstrap must retain its public Show command without a pending resume request")
	Locale := 'window._i18n_strings={"fixture":"retained"};if(typeof window.i18n_apply===' . "'function'"
		. ')window.i18n_apply(window._i18n_strings);'
	Base := [Locale, 'setKind("ollama_install","","delivery fixture")']
	Expected := Base.Clone()
	if Mode == "paused-ready" || Mode == "observer-error" {
		_ODL_Ready(World)
		_ODL_Pump(World, Base.Length)
		_ODL_CheckScripts(World.View, Base)
	}
	Barrier := Critical("On")
	try {
		if Mode == "observer-error" {
			World.View.RejectObserver := true
			OllamaWV_AddLog("accepted once")
			Expected.Push('addLog("accepted once")')
		} else {
			OllamaWV_SetStep("delivery phase")
			OllamaWV_AddLog("delivery once")
			Expected.Push('setStep("delivery phase")', 'addLog("delivery once")')
		}
		if Mode != "paused-ready" && Mode != "observer-error"
			_ODL_Ready(World)
		_ODL_Require(_OllamaWV_Ready && _ODL_Current(World),
			"readiness must be admitted before this deferred-delivery boundary")
		World.Admitted := true
		if Mode == "early-resume" || Mode == "paused-flush" || Mode == "paused-ready" || Mode == "successor" {
			_ODL_Pause(World)
			if Mode == "early-resume" {
				World.BeforeResume := World.View.Scripts.Length
				_ODL_Require(World.BeforeResume == 0, "early resume must precede every native script submission")
				_ODL_Resume(World)
			}
		}
	} finally Critical(Barrier)
	if Mode == "paused-flush" || Mode == "paused-ready" || Mode == "successor" {
		_ODL_Observe(World)
		_ODL_Require(A_IsSuspended, "the real deferred timers must be pumped while native Suspend remains active")
		World.BeforeResume := World.View.Scripts.Length
		_ODL_Require(World.BeforeResume == (Mode == "paused-ready" ? Base.Length : 0),
			"paused script timers must not submit their retained public commands")
		if Mode == "successor" {
			RetiredView := World.View, RetiredController := World.Controller
			OllamaWV_Close()
			_ODL_Require(RetiredController.Closed == 1, "the exact retired controller must close once")
			_ODL_NewPage(World)
			_ODL_Resume(World)
			OllamaWV_Show("ollama_install", "replacement fixture")
			_ODL_Ready(World)
			Expected := [Locale, 'setKind("ollama_install","","replacement fixture")']
		} else _ODL_Resume(World)
	}
	if Mode == "observer-error" {
		_ODL_Observe(World)
		_ODL_Require(World.View.ObserverRefusals == 1 && World.View.ObserverCalls == Expected.Length,
			"the real native helper must encounter an observer refusal after exactly one accepted append")
		World.View.RejectObserver := false
	} else _ODL_Pump(World, Expected.Length)
	if Mode == "settled-before-pause" || Mode == "observer-error" {
		_ODL_CheckScripts(World.View, Expected)
		_ODL_Pause(World)
		_ODL_Observe(World)
		World.BeforeResume := World.View.Scripts.Length
		_ODL_Resume(World)
	}
	_ODL_Observe(World)
	_ODL_Report(World, Mode)
	_ODL_Require(_ODL_Current(World), "delivery must retain the exact originating live session")
	_ODL_CheckScripts(World.View, Expected)
	if Mode == "successor"
		_ODL_Require(RetiredView.Scripts.Length == 0, "resume must never send the retired page's detached scripts")
}

_ODL_Main() {
	global _SharedDir, _I18nLocale, _LLM_Menu, _ODL_World
	global _OllamaWV_Gui, _OllamaWV_WebView, _OllamaWV_Controller, _OllamaWV_Epoch
	Mode := A_Args[1]
	World := {View: _ODL_View(), Args: _ODL_Args(), Controller: _ODL_Controller(),
		Checks: 0, ReadyChecks: 0, ReadyCalls: 0, Resumes: 0, Pauses: 0, Pulses: 0, Flow: 0, AsyncFailure: 0,
		Admitted: false, BeforeResume: -1}
	_ODL_World := World
	Primary := 0, CleanupError := 0
	try {
		_SharedDir := A_Args[2] . "\shared", _I18nLocale := "fixture"
		DirCreate(_SharedDir . "\data\locales")
		FileAppend('{"fixture":"retained"}', _SharedDir . "\data\locales\fixture.json", "UTF-8-RAW")
		World.Gui := Gui("+ToolWindow", "Private Ollama deferred delivery component")
		World.Gui.Show("NA w80 h40 x-32000 y-32000")
		World.GuiHwnd := World.Gui.Hwnd
		_OllamaWV_Gui := World.Gui, _OllamaWV_WebView := World.View, _OllamaWV_Controller := World.Controller
		_OllamaWV_Epoch += 1, World.Epoch := _OllamaWV_Epoch
		_ODL_Require(LLM_Ollama_SetPort(11434), "the actual endpoint must be initialized through its real validator")
		_LLM_Menu["enabled"] := true
		Ports := Map("deps_ready", _ODL_DependencyReady.Bind(World), "deps_check", _ODL_DependencyCheck.Bind(World))
		_ODL_Require(LLM_Menu_BootstrapOllama(true, Ports), "the actual menu bootstrap must admit its public dependency boundary")
		_ODL_Run(World, Mode)
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			Suspend(false)
			if IsObject(World.Flow)
				_ODL_Require(World.Flow.Cancel(), "the exact passive bootstrap owner must retire")
			OllamaWV_Close()
			_ODL_Require(World.Controller.Closed == 1, "the exact private controller must close once")
			_ODL_Require(!IsSet(_OllamaWV_Gui) && !IsSet(_OllamaWV_WebView), "the private page must be detached")
			_ODL_Observe(World)
		} catch as Failure {
			CleanupError := Failure
		}
		if World.HasOwnProp("GuiHwnd") && DllCall("IsWindow", "Ptr", World.GuiHwnd, "Int")
			try World.Gui.Destroy()
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
		if IsObject(World.Flow)
			World.Flow.Timer := 0, World.Flow.Port := 0, World.Flow.OnReady := 0, World.Flow.OnFailed := 0
		OnError(_ODL_AsyncError, 0)
		_ODL_World := 0
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
	FileAppend("PASS ollama-deferred-delivery " . Mode . "`n", "*", "UTF-8")
}

Persistent(true)
global _ODL_World := 0
OnError(_ODL_AsyncError)
try {
	_ODL_Main()
	ExitApp(0)
} catch as Failure {
	FileAppend("FAIL ollama-deferred-delivery: " . Failure.Message . "`n" . Failure.Stack . "`n", "*", "UTF-8")
	ExitApp(1)
}
