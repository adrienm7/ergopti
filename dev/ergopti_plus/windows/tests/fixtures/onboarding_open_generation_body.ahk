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
		if this.Mode == "cold-success" || this.Mode == "reset-then-close" || InStr(this.Mode, "show-") == 1
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
_OWOC_ShowCloseProbe(State, WParam, LParam, Msg, Hwnd) {
	global _ob_gui, _OnbWeb_SessionEpoch
	if State.Fired || !WParam || Hwnd != State.Hwnd
			|| !DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
		return
	try {
		State.Fired := true
		State.Hwnd := Hwnd
		State.OwnerAbsent := !IsObject(_ob_gui)
		State.CriticalAtShow := A_IsCritical
		if !State.Close
			return
		Before := _OnbWeb_SessionEpoch
		DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while _OnbWeb_SessionEpoch == Before && TickElapsed(Started) < 500
			Sleep(1)
		State.CloseEntered := _OnbWeb_SessionEpoch != Before
	} catch Any as Failure {
		State.Failure := Failure
	}
}

; Bind the observer to this sole private production GUI at its genuine Close
; registration. Gui.Show itself and the original Close callback stay untouched.
_OWOC_ShowRegister(State, Window, Name, Callback, Options*) {
	Result := State.Register.Call(Window, Name, Callback, Options*)
	if Name != "Close" || State.Hwnd
		return Result
	_OWOC_Require(HasMethod(Callback, "Call"), "The genuine epoch-bound native Close callback must remain callable")
	State.CloseCallback := Callback
	Hwnd := Window.Hwnd
	; The genuine registration precedes Show. Native HWND ownership ignores
	; DetectHiddenWindows, unlike a WinTitle lookup of this still-hidden GUI.
	OwnerPid := 0
	ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &OwnerPid, "UInt")
	_OWOC_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
		&& ThreadId != 0 && OwnerPid == ProcessExist(),
		"The real Close registration must identify the exact new owned native GUI.")
	State.Window := Window, State.Hwnd := Hwnd
	; Fast callbacks preserve the caller's actual thread/Critical state; this
	; observer must not manufacture a fresh interruptible AHK thread.
	State.Subclass := CallbackCreate(_OWOC_ShowWndProc.Bind(State), "F", 6)
	_OWOC_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", Hwnd,
		"Ptr", State.Subclass, "UPtr", 0x43575348, "UPtr", 0, "Int") != 0,
		"The exact pre-Show native GUI must accept its passive window-procedure observer.")
	return Result
}

_OWOC_ShowWndProc(State, Hwnd, Message, WParam, LParam, Id, Data) {
	State.ActiveCallbacks += 1
	try {
		; Delegate first: a reentrant Close below may destroy this window. Never
		; call DefSubclassProc on its HWND after that destruction has completed.
		Result := DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message,
			"Ptr", WParam, "Ptr", LParam, "Ptr")
		if Hwnd == State.Hwnd {
			if Message == 0x10
				State.NativeCloses += 1
			if Message == 0x18 && WParam {
				State.NativeShows += 1
				_OWOC_ShowCloseProbe(State, WParam, LParam, Message, Hwnd)
			}
		}
		return Result
	} catch Any as Failure {
		State.Failure := Failure
		return 0
	} finally State.ActiveCallbacks -= 1
}

_OWOC_RetireShowObserver(State) {
	if !State.Subclass
		return
	if State.Hwnd && DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int")
		State.Window.Destroy()
	_OWOC_Require(!DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int")
		&& State.ActiveCallbacks == 0,
		"Only acknowledged native window and callback retirement may release the exact subclass thunk.")
	CallbackFree(State.Subclass)
	State.Subclass := 0
}

_OWOC_RecordNativeShow(State, Mode, Environment) {
	global _ob_gui, _OnbWeb_Controller
	NativeAlive := State.Hwnd && DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int") != 0
	FileAppend("DIAG onboarding-show-close mode=" . Mode . " observed=" . State.Fired
		. " owner_absent=" . State.OwnerAbsent . " close_entered=" . State.CloseEntered
		. " native_alive=" . NativeAlive . " gui_global=" . IsObject(_ob_gui)
		. " controller_global=" . IsSet(_OnbWeb_Controller) . " factory_calls=" . Environment.Calls
		. " native_shows=" . State.NativeShows . " native_closes=" . State.NativeCloses
		. " active_native_callbacks=" . State.ActiveCallbacks . " critical_at_show=" . State.CriticalAtShow . "`n", "*")
}

_OWOC_OpenGeneration(Mode) {
	global _WebView_SharedEnv, _WebView_SharedEnvRetired, _ob_gui, _OnbWeb_Controller
	global _OnbWeb_WebView, _OnbWeb_ResetDone, _OnbWeb_SessionEpoch
	_OWOC_Refuse(!!_ob_gui, "this private entry starts without any active onboarding window")
	PreviousEnv := _WebView_SharedEnv, PreviousRetired := _WebView_SharedEnvRetired
	PreviousCritical := Critical("Off")
	Environment := _OWOC_Environment(Mode)
	PreviousRegister := Gui.Prototype.GetOwnPropDesc("OnEvent")
	ShowState := {Fired: false, Close: Mode == "show-close", Register: PreviousRegister.Call,
		Window: 0, Hwnd: 0, Subclass: 0, ActiveCallbacks: 0, NativeShows: 0, NativeCloses: 0,
		OwnerAbsent: false, CloseEntered: false, CriticalAtShow: -1, Failure: 0}
	if InStr(Mode, "show-") == 1
		Gui.Prototype.DefineProp("OnEvent", {Call: _OWOC_ShowRegister.Bind(ShowState)})
	try {
		_WebView_SharedEnv := Environment, _WebView_SharedEnvRetired := false
		_OWOC_Require(_OnbWeb_Available(), "the genuine vendored SDK loader must be present")
		Thread("Interrupt", 0)
		try Started := _Onboarding_TryWeb()
		finally {
			if InStr(Mode, "show-") == 1
				_OWOC_RecordNativeShow(ShowState, Mode, Environment)
		}
		if InStr(Mode, "show-") == 1 {
			if ShowState.Failure is Error
				throw ShowState.Failure
			_OWOC_Require(ShowState.Fired && ShowState.Hwnd != 0, "The exact genuine initial Show must deliver native visibility")
			NativeAlive := DllCall("User32\IsWindow", "Ptr", ShowState.Hwnd, "Int") != 0
			if ShowState.Close {
				_OWOC_Require(ShowState.CloseEntered, "The genuine bound native Close must advance the epoch before Show returns")
				_OWOC_Refuse(NativeAlive, "Closing the initial wizard Show must retire that exact native window")
				_OWOC_Refuse(!!_ob_gui, "A cancelled opening cannot republish the native wizard sentinel")
				_OWOC_Refuse(IsSet(_OnbWeb_Controller))
				_OWOC_Equal(0, Environment.Calls, "The closed native host cannot start browser creation")
			} else {
				_OWOC_Require(NativeAlive && _ob_gui is Gui && IsSet(_OnbWeb_Controller))
				_OWOC_Equal(ShowState.Hwnd, _ob_gui.Hwnd)
				_OWOC_Equal(Environment.Controllers[1], _OnbWeb_Controller)
				_OWOC_Equal(1, Environment.Calls)
			}
		} else if Mode == "cold-success" || Mode == "reset-then-close" {
			_OWOC_Require(_ob_gui is Gui)
			_OWOC_Equal(Environment.Controllers[1], _OnbWeb_Controller)
			_OWOC_Equal(0, Environment.Controllers[1].Closed)
			if Mode == "reset-then-close" {
				Window := _ob_gui, Hwnd := Window.Hwnd, Controller := _OnbWeb_Controller
				_OnbWeb_Reset()
				_OWOC_Require(_ob_gui == Window && DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
					"The genuine BeforeReload plumbing reset must retain its exact native host")
				_OWOC_Equal(1, Controller.Closed, "The default reset closes the old controller once")
				_OWOC_Refuse(IsSet(_OnbWeb_Controller) || IsSet(_OnbWeb_WebView))
				RetiredEpoch := _OnbWeb_SessionEpoch
				_OnbWeb_OnClose(Window)
				_OWOC_Refuse(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
					"Manual Close of the exact retained host must still destroy its native HWND")
				_OWOC_Refuse(!!_ob_gui)
				_OWOC_Equal(1, Controller.Closed, "Host retirement cannot double-close already retired COM plumbing")
				_OWOC_Equal(RetiredEpoch, _OnbWeb_SessionEpoch)
				_OnbWeb_OnClose(Window)
				_OWOC_Equal(1, Controller.Closed, "A duplicate old host Close remains inert")
				_OWOC_Equal(RetiredEpoch, _OnbWeb_SessionEpoch)
				_OWOC_Phase("reset-then-close native_alive=0 sentinel=0 controller_closes=" . Controller.Closed)
			}
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
		_OWOC_Equal(Mode == "cold-success" || Mode == "show-current" || Mode == "reset-then-close", !!Started, "a stale open cannot claim a successful active window")
	} finally {
		if InStr(Mode, "show-") == 1
			Gui.Prototype.DefineProp("OnEvent", PreviousRegister)
		_OnbWeb_OnClose()
		for Controller in Environment.Controllers
			if !Controller.Closed
				Controller.Close()
		_OWOC_RetireShowObserver(ShowState)
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
} catch Any as OnboardingEntryFailure {
	FileAppend("FAIL onboarding-opening " . OnboardingEntryFailure.Message . " at " . OnboardingEntryFailure.File . ":" . OnboardingEntryFailure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
