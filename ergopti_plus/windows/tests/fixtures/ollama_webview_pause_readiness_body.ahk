; tests/fixtures/ollama_webview_pause_readiness_body.ahk

; ==============================================================================
; MODULE: Ollama Paused Readiness Child
; DESCRIPTION:
; A real private GUI retains passive script/process boundaries. The real menu
; bootstrap produces its pending state and the genuine lifecycle resumes it.
; No Create/sweep, browser DOM timing or installation execution is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

class _OPR_ScriptOutcome {
	__New(View) {
		this.View := View
	}
	onSettled(Success, Failure) {
		try Success.Call("null")
		catch as Err {
			this.View.Failure := Err
			throw Err
		}
		this.View.Settled += 1
	}
}

class _OPR_View {
	__New() {
		this.Scripts := []
		this.Settled := 0
		this.Failure := 0
	}
	ExecuteScriptAsync(Script) {
		this.Scripts.Push(Script)
		return _OPR_ScriptOutcome(this)
	}
}

class _OPR_Controller {
	Closed := 0
	Close() {
		this.Closed += 1
	}
}

class _OPR_Args {
	Reads := 0
	TryGetWebMessageAsString() {
		this.Reads += 1
		return "ready"
	}
}

class _OPR_Files {
	Owned := false
	Cancelled := 0
	Run(Action, Request, Authority, Done) {
		_OPR_Require(Action == "inspect", "the passive process boundary admits only initial inspection")
		_OPR_Require(Authority["authorize"].Call(Action, Request), "the real bootstrap must admit its inspection")
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

class _OPR_Runtime {
	Stops := 0
	HasOwner() {
		return false
	}
	Stop() {
		this.Stops += 1
		return true
	}
}

_OPR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_OPR_AsyncError(Failure, Mode) {
	global _OPR_World
	if IsObject(_OPR_World) {
		_OPR_World.AsyncFailure := Failure
		return 1
	}
}

_OPR_DependencyReady(World) {
	World.ReadyChecks += 1
	return false
}

_OPR_DependencyCheck(World, Model, Ready, Failed, ShowUi) {
	global _LLM_Deps_Epoch, _LLM_Deps_Checking
	World.Checks += 1
	_OPR_Require(ShowUi && Model == "", "the real menu bootstrap must request its visible current operation")
	World.Files := _OPR_Files(), World.Runtime := _OPR_Runtime()
	Port := Map("plan", Map("ManagedRoot", A_Args[2], "CataloguePath", A_Args[2] . "\unused.json",
		"CatalogueSha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"AssetId", "windows-amd64", "deadline_ms", 60000),
		"files", World.Files, "runtime", World.Runtime, "clock", () => A_TickCount, "current", (*) => true)
	World.Flow := OllamaManagedBootstrap(Model, _LLM_Deps_Epoch, Ready, Failed, Port)
	_LLM_Deps_Checking := true
	_OPR_Require(World.Flow.Begin(), "the actual bootstrap must retain an admitted inspection")
	; This is the existing dependency port's passive UI boundary. The public
	; Show API still owns the actual queue; _Ui/Create/browser timing is not run.
	OllamaWV_Show("ollama_install", "pause fixture")
}

_OPR_Ready(World) {
	World.ReadyCalls += 1
	OllamaWV_OnWebMessage(World.View, World.Args)
}

_OPR_Safety(World) {
	World.SafetyCalls += 1
	World.Safety.Call()
}

_OPR_Resume(World) {
	global _LLM_Menu, _LifecycleLatestTransition, _LLM_MenuBuildCoordinator
	Suspend(false)
	_OPR_Require(Ergopti_OnSuspendResume(), "the real resume reactor must finish without owner debt")
	World.Resumes += 1
	_OPR_Require(_LifecycleLatestTransition.phase == "resume" && _LifecycleLatestTransition.finished
		&& _LifecycleLatestTransition.debt.Length == 0, "a failed hook cannot masquerade as a completed resume")
	_OPR_Require(!_LLM_Menu["bootstrap_pending"], "resume must observe the state produced by the actual bootstrap")
	_OPR_Require(_LLM_MenuBuildCoordinator is LLMMenuBuildCoordinator,
		"the real menu resume hook must reach its actual build service")
}

_OPR_Pump(World, Expected) {
	Started := A_TickCount
	while World.View.Settled < Expected && TickElapsed(Started) < 1000
		Sleep(5)
	if IsObject(World.AsyncFailure)
		throw World.AsyncFailure
	if IsObject(World.View.Failure)
		throw World.View.Failure
}

_OPR_Current(World) {
	global _OllamaWV_Epoch, _OllamaWV_WebView, _OllamaWV_Gui
	return _OllamaWV_Epoch == World.Epoch && IsSet(_OllamaWV_WebView)
		&& _OllamaWV_WebView == World.View && IsSet(_OllamaWV_Gui)
		&& _OllamaWV_Gui == World.Gui && OllamaWV_IsAlive()
}

_OPR_Report(World, Mode) {
	global _LLM_Menu, _OllamaWV_Ready, _OllamaWV_Queue, _LLM_Deps_Checking
	FileAppend("RECEIPT mode=" . Mode . " ready_calls=" . World.ReadyCalls
		. " payload_reads=" . World.Args.Reads . " safety_calls=" . World.SafetyCalls
		. " resumes=" . World.Resumes . " same_session=" . _OPR_Current(World)
		. " ready=" . _OllamaWV_Ready . " queued=" . _OllamaWV_Queue.Length
		. " scripts=" . World.View.Scripts.Length . " settled=" . World.View.Settled
		. " bootstrap_pending=" . _LLM_Menu["bootstrap_pending"]
		. " checking=" . _LLM_Deps_Checking . " flow_cancelled=" . World.Flow.Cancelled . "`n", "*", "UTF-8")
}

_OPR_Run(World, Mode) {
	global _LLM_Menu, _OllamaWV_Ready, _OllamaWV_Queue
	_OPR_Require(World.Checks == 1 && World.ReadyChecks == 1 && !World.Flow.Cancelled,
		"the actual current menu bootstrap must dispatch exactly one retained operation")
	_OPR_Require(!_LLM_Menu["bootstrap_pending"], "active bootstrap must produce non-pending state before pause")
	_OPR_Require(!_OllamaWV_Ready && _OPR_Current(World) && _OllamaWV_Queue.Length == 1,
		"a live same-session page must own one real public Show command before readiness")
	Expected := ['window._i18n_strings={"fixture":"retained"};if(typeof window.i18n_apply===' . "'function'"
		. ')window.i18n_apply(window._i18n_strings);', 'setKind("ollama_install","","pause fixture")']
	if Mode == "current-ready" {
		_OPR_Ready(World)
	} else {
		Suspend(true)
		if Mode != "early-resume" {
			_OPR_Ready(World), _OPR_Safety(World)
			_OPR_Require(World.Args.Reads == 0 && !_OllamaWV_Ready && _OllamaWV_Queue.Length == 1
				&& World.View.Scripts.Length == 0 && _OPR_Current(World),
				"both paused deliveries must preserve the exact live unready queue without script effects")
		}
		if Mode == "bootstrap-tick" {
			World.Flow._Tick()
			_OPR_Require(World.Flow.Cancelled && !World.Files.HasOwner() && World.Files.Cancelled == 1,
				"the real bootstrap tick must retire its retained process boundary while suspended")
			_OPR_Require(_OPR_Current(World) && !_LLM_Menu["bootstrap_pending"],
				"actual cancellation must leave this page and must not fabricate a pending resume request")
		}
		_OPR_Require(!_LLM_Menu["bootstrap_pending"], "the actual paused producers must not have requested another bootstrap")
		_OPR_Resume(World)
		if Mode == "early-resume" {
			_OPR_Pump(World, 1)
			_OPR_Require(!_OllamaWV_Ready && _OllamaWV_Queue.Length == 1 && World.View.Scripts.Length == 0,
				"resume before ready or fallback must not prematurely certify or drain a loading document")
			_OPR_Ready(World)
		}
	}
	_OPR_Pump(World, Expected.Length)
	_OPR_Report(World, Mode)
	_OPR_Require(_OPR_Current(World), "resume delivery must retain the exact originating session")
	_OPR_Require(_OllamaWV_Ready && _OllamaWV_Queue.Length == 0 && World.View.Scripts.Length == Expected.Length,
		"a current ready signal consumed while paused must still recover its retained queue after real resume")
	for Script in Expected {
		Matches := 0
		for Observed in World.View.Scripts
			if Observed == Script
				Matches += 1
		_OPR_Require(Matches == 1, "deferred submission must preserve each independent locale/UI golden exactly once")
	}
}

_OPR_Main() {
	global _SharedDir, _I18nLocale, _LLM_Menu, _OPR_World
	global _OllamaWV_Gui, _OllamaWV_WebView, _OllamaWV_Controller, _OllamaWV_Epoch
	_OCSD_Note("main-entry")
	Mode := A_Args[1]
	World := {View: _OPR_View(), Args: _OPR_Args(), Controller: _OPR_Controller(),
		Checks: 0, ReadyChecks: 0, ReadyCalls: 0, SafetyCalls: 0, Resumes: 0, Flow: 0, AsyncFailure: 0}
	_OPR_World := World
	Primary := 0, CleanupError := 0
	try {
		_SharedDir := A_Args[2] . "\shared", _I18nLocale := "fixture"
		DirCreate(_SharedDir . "\data\locales")
		FileAppend('{"fixture":"retained"}', _SharedDir . "\data\locales\fixture.json", "UTF-8-RAW")
		_OCSD_Note("before-gui")
		World.Gui := Gui("+ToolWindow", "Private Ollama readiness component")
		World.Gui.Show("NA w80 h40 x-32000 y-32000")
		World.GuiHwnd := World.Gui.Hwnd
		_OCSD_Note("after-gui")
		_OllamaWV_Gui := World.Gui, _OllamaWV_WebView := World.View, _OllamaWV_Controller := World.Controller
		_OllamaWV_Epoch += 1, World.Epoch := _OllamaWV_Epoch
		World.Safety := _OPR_SafetyCallback(World.Epoch)
		_OCSD_Note("before-endpoint")
		_OPR_Require(LLM_Ollama_SetPort(11434), "the actual endpoint must be initialized through its real validator")
		_OCSD_Note("after-endpoint")
		_LLM_Menu["enabled"] := true
		Ports := Map("deps_ready", _OPR_DependencyReady.Bind(World), "deps_check", _OPR_DependencyCheck.Bind(World))
		_OCSD_Note("before-bootstrap")
		_OPR_Require(LLM_Menu_BootstrapOllama(true, Ports), "the actual menu bootstrap must admit its public dependency boundary")
		_OCSD_Note("after-bootstrap")
		_OCSD_Note("before-run")
		_OPR_Run(World, Mode)
		_OCSD_Note("after-run")
	} catch as Failure {
		Primary := Failure
	} finally {
		_OCSD_Note("before-cleanup")
		try {
			Suspend(false)
			if IsObject(World.Flow)
				_OPR_Require(World.Flow.Cancel(), "the exact passive bootstrap owner must retire")
			OllamaWV_Close()
			_OPR_Require(World.Controller.Closed == 1, "the exact private controller must close once")
			_OPR_Require(!IsSet(_OllamaWV_Gui) && !IsSet(_OllamaWV_WebView), "the private page must be detached")
		} catch as Failure {
			CleanupError := Failure
		}
		if World.HasOwnProp("GuiHwnd") && DllCall("IsWindow", "Ptr", World.GuiHwnd, "Int")
			try World.Gui.Destroy()
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
		World.Safety := 0
		if IsObject(World.Flow)
			World.Flow.Timer := 0, World.Flow.Port := 0, World.Flow.OnReady := 0, World.Flow.OnFailed := 0
		OnError(_OPR_AsyncError, 0)
		_OPR_World := 0
		_OCSD_Note("after-cleanup")
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
	FileAppend("PASS ollama-paused-readiness " . Mode . "`n", "*", "UTF-8")
}

Persistent(true)
global _OPR_World := 0
OnError(_OPR_AsyncError)
try {
	_OPR_Main()
	_OCSD_Note("before-exit-success")
	_OCSD_Finish()
	ExitApp(0)
} catch as Failure {
	_OCSD_Note("before-exit-failure")
	try _OCSD_Finish()
	FileAppend("FAIL ollama-paused-readiness: " . Failure.Message . "`n" . Failure.Stack . "`n", "*", "UTF-8")
	ExitApp(1)
}
