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
		if this.Mode == "cold-success" || InStr(this.Mode, "show-") == 1 || InStr(this.Mode, "native-destroy-") == 1
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
; Observe the production Gui.Show callout, then deliver the real native Close.
; Epoch advance proves the installed production Close event actually ran while
; Show was still on its stack; absence of that receipt is setup failure only.
_CWOC_ShowCloseProbe(State, WParam, LParam, Msg, Hwnd) {
	global _CLW_Gui, _CLW_WindowEpoch
	if State.Fired || !WParam || Hwnd != State.Hwnd
			|| !DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
		return
	try {
		State.Fired := true
		State.Hwnd := Hwnd
		State.OwnerAbsent := !IsSet(_CLW_Gui)
		State.CriticalAtShow := A_IsCritical
		if !State.Close
			return
		Before := _CLW_WindowEpoch
		DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while _CLW_WindowEpoch == Before && TickElapsed(Started) < 500
			Sleep(1)
		State.CloseEntered := _CLW_WindowEpoch != Before
	} catch Any as Failure {
		State.Failure := Failure
	}
}

; Bind the observer to the exact production GUI at its genuine Close
; registration. Gui.Show itself and the original Close callback stay untouched.
_CWOC_ShowRegister(State, Window, Name, Callback, Options*) {
	Result := State.Register.Call(Window, Name, Callback, Options*)
	if Name != "Close" || Callback != _CLW_OnClose || State.Hwnd
		return Result
	Hwnd := Window.Hwnd
	; The genuine registration precedes Show. Native HWND ownership ignores
	; DetectHiddenWindows, unlike a WinTitle lookup of this still-hidden GUI.
	OwnerPid := 0
	ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &OwnerPid, "UInt")
	_CWOC_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
		&& ThreadId != 0 && OwnerPid == ProcessExist(),
		"The real Close registration must identify the exact new owned native GUI.")
	State.Window := Window, State.Hwnd := Hwnd
	; Fast callbacks preserve the caller's actual thread/Critical state; this
	; observer must not manufacture a fresh interruptible AHK thread.
	State.Subclass := CallbackCreate(_CWOC_ShowWndProc.Bind(State), "F", 6)
	_CWOC_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", Hwnd,
		"Ptr", State.Subclass, "UPtr", 0x43575348, "UPtr", 0, "Int") != 0,
		"The exact pre-Show native GUI must accept its passive window-procedure observer.")
	return Result
}

_CWOC_ShowWndProc(State, Hwnd, Message, WParam, LParam, Id, Data) {
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
				_CWOC_ShowCloseProbe(State, WParam, LParam, Message, Hwnd)
			}
		}
		return Result
	} catch Any as Failure {
		State.Failure := Failure
		return 0
	} finally State.ActiveCallbacks -= 1
}

_CWOC_RetireShowObserver(State) {
	if !State.Subclass
		return
	if State.Hwnd && DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int")
		State.Window.Destroy()
	_CWOC_Require(!DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int")
		&& State.ActiveCallbacks == 0,
		"Only acknowledged native window and callback retirement may release the exact subclass thunk.")
	CallbackFree(State.Subclass)
	State.Subclass := 0
}

_CWOC_RecordNativeShow(State, Mode, Environment) {
	global _CLW_Gui, _CLW_Controller
	NativeAlive := State.Hwnd && DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int") != 0
	FileAppend("DIAG changelog-show-close mode=" . Mode . " observed=" . State.Fired
		. " owner_absent=" . State.OwnerAbsent . " close_entered=" . State.CloseEntered
		. " native_alive=" . NativeAlive . " gui_global=" . IsSet(_CLW_Gui)
		. " controller_global=" . IsSet(_CLW_Controller) . " factory_calls=" . Environment.Calls
		. " native_shows=" . State.NativeShows . " native_closes=" . State.NativeCloses
		. " active_native_callbacks=" . State.ActiveCallbacks . " critical_at_show=" . State.CriticalAtShow . "`n", "*")
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
	PreviousRegister := Gui.Prototype.GetOwnPropDesc("OnEvent")
	ShowState := {Fired: false, Close: Mode == "show-close", Register: PreviousRegister.Call,
		Window: 0, Hwnd: 0, Subclass: 0, ActiveCallbacks: 0, NativeShows: 0, NativeCloses: 0,
		OwnerAbsent: false, CloseEntered: false, CriticalAtShow: -1, Failure: 0}
	if InStr(Mode, "show-") == 1
		Gui.Prototype.DefineProp("OnEvent", {Call: _CWOC_ShowRegister.Bind(ShowState)})
	_Updater_OpenChangelogWindow.DefineProp("Call", {Call: _CWOC_NativeFallback})
	_CLW_FetchAndInject.DefineProp("Call", {Call: _CWOC_RejectFetch})
	try {
		_WebView_SharedEnv := Environment, _WebView_SharedEnvRetired := false
		_CWOC_Require(_CLW_WebView2Available(), "the genuine vendored SDK loader must be present")
		Thread("Interrupt", 0)
		try {
			if InStr(Mode, "native-fault-") == 1
				_CWSF_Run(Environment, Mode)
			else
				_CWOC_PublicOpen()
		}
		finally {
			if InStr(Mode, "show-") == 1
				_CWOC_RecordNativeShow(ShowState, Mode, Environment)
		}
		if InStr(Mode, "native-fault-") == 1 {
			; The explicit fault helper owns the exact-error/native-window oracles.
		} else if InStr(Mode, "show-") == 1 {
			if ShowState.Failure is Error
				throw ShowState.Failure
			_CWOC_Require(ShowState.Fired && ShowState.Hwnd != 0, "the exact public Gui.Show must deliver a native visibility notification")
			NativeAlive := DllCall("User32\IsWindow", "Ptr", ShowState.Hwnd, "Int") != 0

			if ShowState.Close {
				_CWOC_Require(ShowState.CloseEntered, "the genuine WM_CLOSE event must run before the Gui.Show callout returns")
				_CWOC_Refuse(NativeAlive, "a native close during initial Show must retire that exact native window")
				_CWOC_Refuse(IsSet(_CLW_Gui), "the cancelled opening cannot republish a GUI after its close event")
				_CWOC_Refuse(IsSet(_CLW_Controller), "the cancelled initial window cannot publish a controller")
			} else {
				_CWOC_Require(NativeAlive && IsSet(_CLW_Gui) && IsSet(_CLW_Controller), "observing native Show alone must retain the actual successful opening")
				_CWOC_Equal(ShowState.Hwnd, _CLW_Gui.Hwnd)
				_CWOC_Equal(Environment.Controllers[1], _CLW_Controller)
			}
		} else if InStr(Mode, "native-destroy-") == 1 {
			_CWNS_CloseNative(Environment, Mode)
		} else if Mode == "cold-success" {
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
		if InStr(Mode, "show-") == 1
			Gui.Prototype.DefineProp("OnEvent", PreviousRegister)
		Changelog_Close()
		_CWOC_RetireShowObserver(ShowState)
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

; A native WM_DESTROY from A opens B once, before A's real Close returns.
; Native window construction and public requests remain production owners.
_CWNS_WndProc(State, Hwnd, Message, WParam, LParam, Id, Data) {
	global _CLW_Gui, _CLW_Controller, _CLW_WindowEpoch
	State.ActiveCallbacks += 1
	try {
		Result := DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message,
			"Ptr", WParam, "Ptr", LParam, "Ptr")
		if State.Armed && !State.Fired && Hwnd == State.Hwnd && Message == 2 {
			State.Fired := true
			if State.Reopen {
				_CWOC_PublicOpen()
				State.NewGui := IsSet(_CLW_Gui) ? _CLW_Gui : 0
				State.NewController := IsSet(_CLW_Controller) ? _CLW_Controller : 0
				State.NewEpoch := _CLW_WindowEpoch
				State.NewHwnd := State.NewGui is Gui ? State.NewGui.Hwnd : 0
				State.Reopened := State.NewHwnd != 0
					&& DllCall("User32\IsWindow", "Ptr", State.NewHwnd, "Int") != 0
					&& IsObject(State.NewController)
				_CWOC_Require(State.Reopened, "A must observe the actual fully opened native B before returning from WM_DESTROY")
			}
		}
		return Result
	} catch Any as Failure {
		State.Failure := Failure
		return 0
	} finally State.ActiveCallbacks -= 1
}

_CWNS_CloseNative(Environment, Mode) {
	global _CLW_Gui, _CLW_Controller, _CLW_WindowEpoch
	_CWOC_Require(IsSet(_CLW_Gui) && IsSet(_CLW_Controller), "The public control must genuinely open A before native close")
	Original := _CLW_Gui, Controller := _CLW_Controller, Epoch := _CLW_WindowEpoch
	State := {Window: Original, Hwnd: Original.Hwnd, Subclass: 0, ActiveCallbacks: 0,
		Armed: false, Fired: false, Reopen: Mode == "native-destroy-reopen", Reopened: false,
		NewGui: 0, NewHwnd: 0, NewController: 0, NewEpoch: -1, Failure: 0}
	try {
		OwnerPid := 0
		_CWOC_Require(DllCall("User32\GetWindowThreadProcessId", "Ptr", State.Hwnd, "UInt*", &OwnerPid, "UInt") != 0
			&& OwnerPid == ProcessExist(), "Only the exact original private native window may receive WM_CLOSE")
		State.Subclass := CallbackCreate(_CWNS_WndProc.Bind(State), "F", 6)
		_CWOC_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", State.Hwnd,
			"Ptr", State.Subclass, "UPtr", 0x43574E53, "UPtr", 0, "Int") != 0)
		State.Armed := true
		DllCall("User32\SendMessageW", "Ptr", State.Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while !State.Fired && TickElapsed(Started) < 3000
			Sleep(5)
		if State.Failure is Error
			throw State.Failure
		NewAlive := State.NewHwnd && DllCall("User32\IsWindow", "Ptr", State.NewHwnd, "Int") != 0
		NewOwned := IsSet(_CLW_Gui) && _CLW_Gui == State.NewGui
		FileAppend("DIAG changelog-native-destroy mode=" . Mode . " destroy_entered=" . State.Fired
			. " reopened_before_return=" . State.Reopened . " newer_native_alive=" . NewAlive
			. " newer_gui_owned=" . NewOwned . " factory_calls=" . Environment.Calls . "`n", "*", "UTF-8")
		_CWOC_Require(State.Fired && State.ActiveCallbacks == 0, "The real A WM_DESTROY callback must complete before ownership is judged")
		_CWOC_Refuse(DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int"), "Native Close must retire A")
		_CWOC_Equal(1, Controller.Closed)
		if State.Reopen {
			_CWOC_Require(State.Reopened && NewAlive, "Actual native B must survive A's Close completion")
			_CWOC_Require(NewOwned, "The completed old Close cannot clear the public ownership of the native B it observed")
			_CWOC_Equal(State.NewController, _CLW_Controller)
			_CWOC_Equal(State.NewEpoch, _CLW_WindowEpoch)
			_CWOC_Equal(0, State.NewController.Closed)
			_CWOC_Equal(2, Environment.Calls)
		} else {
			_CWOC_Refuse(IsSet(_CLW_Gui) || IsSet(_CLW_Controller))
			_CWOC_Require(_CLW_WindowEpoch > Epoch)
			_CWOC_Equal(1, Environment.Calls)
		}
	} finally {
		State.Armed := false
		Changelog_Close()
		if IsObject(State.NewController) && !State.NewController.Closed
			State.NewController.Close()
		if State.NewGui is Gui && DllCall("User32\IsWindow", "Ptr", State.NewHwnd, "Int")
			State.NewGui.Destroy()
		_CWOC_RetireShowObserver(State)
	}
}

; Explicit fixture exception after the genuine native Show has returned. This
; does not pretend Windows itself failed; the exact Error must propagate.
_CWSF_Show(State, Window, Options*) {
	global _CLW_Gui
	Result := State.Show.Call(Window, Options*)
	if State.Injected
		return Result
	State.Injected := true
	State.Window := Window, State.Hwnd := Window.Hwnd
	_CWOC_Require(DllCall("User32\IsWindowVisible", "Ptr", State.Hwnd, "Int")
		&& IsSet(_CLW_Gui) && _CLW_Gui == Window,
		"The explicit fault follows actual native Show and current GUI publication")
	OwnerPid := 0
	_CWOC_Require(DllCall("User32\GetWindowThreadProcessId", "Ptr", State.Hwnd, "UInt*", &OwnerPid, "UInt") != 0
		&& OwnerPid == ProcessExist())
	State.Shown := true
	State.Subclass := CallbackCreate(_CWNS_WndProc.Bind(State), "F", 6)
	_CWOC_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", State.Hwnd,
		"Ptr", State.Subclass, "UPtr", 0x43574E53, "UPtr", 0, "Int") != 0)
	State.Armed := true
	throw State.Fault
}

_CWSF_Run(Environment, Mode) {
	global _CLW_Gui, _CLW_Controller, _CLW_WindowEpoch
	PreviousShow := Gui.Prototype.GetOwnPropDesc("Show")
	State := {Show: PreviousShow.Call, Fault: Error("Explicit fixture fault after genuine native Show."),
		Injected: false, Shown: false, Window: 0, Hwnd: 0, Subclass: 0, ActiveCallbacks: 0,
		Armed: false, Fired: false, Reopen: Mode == "native-fault-successor", Reopened: false,
		NewGui: 0, NewHwnd: 0, NewController: 0, NewEpoch: -1, Failure: 0}
	; Only passive browser COM scheduling changes: B can complete immediately
	; inside native Destroy. A's fault occurs before any browser factory call.
	Environment.Mode := "cold-success"
	Caught := 0
	try {
		Gui.Prototype.DefineProp("Show", {Call: _CWSF_Show.Bind(State)})
		try _CWOC_PublicOpen()
		catch Any as Failure
			Caught := Failure
		if State.Failure is Error
			throw State.Failure
		OldAlive := State.Hwnd && DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int") != 0
		NewAlive := State.NewHwnd && DllCall("User32\IsWindow", "Ptr", State.NewHwnd, "Int") != 0
		FileAppend("DIAG changelog-native-show-fault mode=" . Mode . " shown=" . State.Shown
			. " error_identity=" . (Caught == State.Fault) . " old_native_alive=" . OldAlive
			. " destroy_entered=" . State.Fired . " newer_seen=" . State.Reopened
			. " newer_native_alive=" . NewAlive . " factory_calls=" . Environment.Calls . "`n", "*", "UTF-8")
		_CWOC_Require(State.Injected && State.Shown, "The explicit fault must run after actual native Show")
		_CWOC_Require(Caught == State.Fault, "Cleanup must rethrow the identical injected Error, without replacing or swallowing it")
		_CWOC_Refuse(OldAlive, "An unexpected Show exception must retire its still-current published native GUI")
		_CWOC_Require(State.Fired && State.ActiveCallbacks == 0)
		if State.Reopen {
			_CWOC_Require(State.Reopened && NewAlive, "The real B opened during old A cleanup must remain natively alive")
			_CWOC_Require(IsSet(_CLW_Gui) && _CLW_Gui == State.NewGui,
				"Old Show exception cleanup cannot clear its independently opened successor")
			_CWOC_Equal(State.NewController, _CLW_Controller)
			_CWOC_Equal(State.NewEpoch, _CLW_WindowEpoch)
			_CWOC_Equal(0, State.NewController.Closed)
			_CWOC_Equal(1, Environment.Calls, "Only the genuinely reopened B reaches browser creation")
		} else {
			_CWOC_Refuse(IsSet(_CLW_Gui) || IsSet(_CLW_Controller))
			_CWOC_Equal(0, Environment.Calls, "Failed native Show cannot start browser creation")
		}
	} finally {
		State.Armed := false
		Gui.Prototype.DefineProp("Show", PreviousShow)
		Changelog_Close()
		if IsObject(State.NewController) && !State.NewController.Closed
			State.NewController.Close()
		if State.NewGui is Gui && DllCall("User32\IsWindow", "Ptr", State.NewHwnd, "Int")
			State.NewGui.Destroy()
		_CWOC_RetireShowObserver(State)
	}
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
} catch Any as ChangelogEntryFailure {
	FileAppend("FAIL changelog-opening " . ChangelogEntryFailure.Message . " at " . ChangelogEntryFailure.File . ":" . ChangelogEntryFailure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
