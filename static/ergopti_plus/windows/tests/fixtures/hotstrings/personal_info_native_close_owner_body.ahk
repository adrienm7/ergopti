; tests/fixtures/hotstrings/personal_info_native_close_owner_body.ahk
; Actual public constructor, real GUI/WM_CLOSE/WM_DESTROY, passive browser only.
#Requires AutoHotkey v2.0

_PINS_Require(Condition, Message := "") {
	if !Condition
		throw Error(Message)
}
t(Key) => Key
LoggerSuccess(*) => 0
LoggerError(*) {
	global _PINS
	if IsSet(_PINS) && IsObject(_PINS) && InStr(_PINS.Mode, "subscription-error-") == 1
		_PINS.Errors += 1
	return 0
}
LoggerWarn(*) => 0
WebView_SharedEnvironment(Loader) => {Passive: true}
Gui_Create(Options := "", Title := "") {
	global _PINS
	Window := Gui(Options, Title)
	_PINS.Windows.Push(Window), _PINS.Hwnds.Push(Window.Hwnd)
	_PINS_Require(_PINS.Windows.Length <= (InStr(_PINS.Mode, "retry-") == 1 ? 3 : 2), "Only one actual successor may be constructed")
	return Window
}
class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		global _PINS, _PiEdWeb_Gui
		_PINS_Require(!IsSet(Callback) && Environment.Passive)
		_PINS_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"))
		_PINS_Require(_PiEdWeb_Gui is Gui)
		Controller := _PINS_Controller()
		_PINS.Controllers.Push(Controller)
		return Controller
	}
}
class _PINS_Subscription {
	__Delete() {
		global _PINS
		_PINS.SubscriptionsRetired += 1
	}
}
class _PINS_View {
	__New() {
		this.Settings := {}, this.Subscriptions := 0, this.Navigations := 0
	}
	WebMessageReceived(Callback) {
		global _PINS, _PiEdWeb_SessionEpoch, _PiEdWeb_Gui
		this.Subscriptions += 1
		if InStr(_PINS.Mode, "subscription-error-") == 1 && _PINS.Controllers.Length == 1
			throw Error("private SDK add_Event refusal")
		if _PINS.Mode == "subscription-close" || _PINS.Mode == "subscription-reset-close" || _PINS.Mode == "subscription-reset-retain" {
			Window := _PINS.Windows[1], Hwnd := Window.Hwnd
			Epoch := _PiEdWeb_SessionEpoch
			NativePid := 0
			_PINS_Require(DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &NativePid, "UInt")
				&& NativePid == ProcessExist(), "the real native close must target the exact private child window")
			_PINS.AddEntered += 1
			if _PINS.Mode == "subscription-reset-close" || _PINS.Mode == "subscription-reset-retain" {
				_PiEdWeb_Reset()
				_PINS.ResetRetained := _PiEdWeb_Gui == Window && !!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
				if _PINS.Mode == "subscription-reset-close" {
					_PiEdWeb_Close(Window)
					_PINS.ResetCloseDetached := !IsObject(_PiEdWeb_Gui)
				}
			} else
				_PINS_Require(DllCall("User32\PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int"), "real close must be posted to the private HWND")
			Started := A_TickCount
			while _PiEdWeb_SessionEpoch == Epoch && TickElapsed64(Started) < 1500
				Sleep(10)
			_PINS.CloseAcknowledged := _PiEdWeb_SessionEpoch != Epoch
			_PINS.HwndAtAddReturn := !!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
		}
		if InStr(_PINS.Mode, "subscription-")
			return _PINS_Subscription()
		return {Callback: Callback}
	}
	NavigationCompleted(Callback) {
		global _PINS
		this.Subscriptions += 1
		if InStr(_PINS.Mode, "subscription-")
			return _PINS_Subscription()
		return {Callback: Callback}
	}
	SetVirtualHostNameToFolderMapping(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
}
class _PINS_Controller {
	__New() {
		this.CoreWebView2 := _PINS_View(), this.Closed := 0, this.Fills := 0, this.Attempts := 0
	}
	Close() {
		global _PINS
		this.Attempts += 1
		if InStr(_PINS.Mode, "retry-") == 1 && this == _PINS.Controllers[1] {
			if _PINS.RetryRefuse {
				_PINS.RetryRefuse := false
				_PINS.RetryRefusals += 1
				throw Error("Controlled SDK Close refusal before effect")
			}
			if _PINS.RetryReenter {
				_PINS.RetryReenter := false
				PersonalInformationEditor()
				_PINS_Require(_PINS.Windows.Length == 2 && _PINS.Controllers.Length == 2,
					"The retirement callout must really open a second public native editor")
				_PINS.RetrySuccessor := true
				_PINS_RetryNativeClose(2, true)
				_PINS.RetrySuccessorClosed := _PINS.Controllers[2].Closed == 1
			}
		}
		this.Closed += 1
		if _PINS.Mode == "subscription-error-reopen" && !_PINS.CloseReopen && this == _PINS.Controllers[1] {
			_PINS.CloseReopen := true
			PersonalInformationEditor()
		}
		if InStr(_PINS.Mode, "subscription-") {
			_PINS.HwndAtControllerClose := !!DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[1], "Int")
			_PINS.RetiredAtControllerClose := _PINS.SubscriptionsRetired
		}
	}
	Fill() {
		this.Fills += 1
	}
}
_PINS_Destroy(Hwnd, Message, WParam, LParam, Id, RefData) {
	global _PINS, _PiEdWeb_Gui, _PiEdWeb_Controller
	_PINS.Callbacks += 1
	try {
		Mine := _PINS.Active && !_PINS.Fired && Hwnd == _PINS.OldHwnd && Message == 0x2
		if Mine {
			NativePid := 0
			DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &NativePid)
			_PINS_Require(NativePid == ProcessExist(), "Reentry is restricted to the exact owned process/window")
		}
		Result := DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message,
			"UPtr", WParam, "Ptr", LParam, "Ptr")
		if Mine {
			_PINS.Fired := true
			_PINS.Reopens += 1
			; Real public request while the original native destruction is on stack.
			PersonalInformationEditor()
			_PINS.SeenBeforeReturn := _PINS.Windows.Length == 2
			if _PINS.SeenBeforeReturn {
				_PINS.NewGui := _PINS.Windows[2]
				_PINS.NewHwnd := _PINS.Hwnds[2]
				_PINS.NewAliveBefore := DllCall("User32\IsWindow", "Ptr", _PINS.NewHwnd, "Int")
			}
		}
		return Result
	} catch as Failure {
		if !IsObject(_PINS.Failure)
			_PINS.Failure := Failure
		return 0
	} finally _PINS.Callbacks -= 1
}

_PINS_RetryNativeClose(Index, RequireDestroyed) {
	global _PINS, _PiEdWeb_SessionEpoch
	Hwnd := _PINS.Hwnds[Index], Epoch := _PiEdWeb_SessionEpoch, NativePid := 0
	_PINS_Require(DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &NativePid, "UInt")
		&& NativePid == ProcessExist() && DllCall("User32\IsWindowVisible", "Ptr", Hwnd, "Int"),
		"Native Close must target the exact visible private editor")
	DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while (_PiEdWeb_SessionEpoch == Epoch || (RequireDestroyed && DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")))
		&& TickElapsed64(Started) < 1500
		Sleep(10)
	_PINS_Require(_PiEdWeb_SessionEpoch != Epoch && (!RequireDestroyed || !DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")),
		"The genuine native handler must revoke its epoch and complete any requested exact destruction")
}
_PINS_RetryExercise() {
	global _PINS, _PiEdWeb_RetiredHosts, _PiEdWeb_Gui, _PiEdWeb_ResetDone
	_PINS_Require(_PiEdWeb_RetiredHosts.Length == 0, "No retirement record may be fabricated before the public open")
	PersonalInformationEditor()
	_PINS_Require(_PINS.Windows.Length == 1 && _PINS.Controllers.Length == 1
		&& _PINS.Controllers[1].Attempts == 0, "The real public editor must acquire its current native/controller pair")
	_PINS.RetryRefuse := true
	_PINS_RetryNativeClose(1, false)
	DebtCreated := _PINS.RetryRefusals == 1 && _PINS.Controllers[1].Attempts == 1
		&& _PINS.Controllers[1].Closed == 0 && _PiEdWeb_RetiredHosts.Length == 1
		&& !IsObject(_PiEdWeb_Gui) && DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[1], "Int")
	FileAppend("RECEIPT personal-initial-retry mode=" . _PINS.Mode . " debt_created=" . DebtCreated . "`n", "*")
	_PINS_Require(DebtCreated, "One real Close refusal before effect must produce the original pending host")
	_PINS.RetryReenter := _PINS.Mode == "retry-reentry"
	PersonalInformationEditor()
	FileAppend("RECEIPT personal-initial-retry result mode=" . _PINS.Mode
		. " windows=" . _PINS.Windows.Length . " controllers=" . _PINS.Controllers.Length
		. " old_attempts=" . _PINS.Controllers[1].Attempts . " old_closed=" . _PINS.Controllers[1].Closed
		. " successor_opened=" . _PINS.RetrySuccessor . " successor_closed=" . _PINS.RetrySuccessorClosed
		. " gui=" . IsObject(_PiEdWeb_Gui) . " pending=" . _PiEdWeb_RetiredHosts.Length . "`n", "*")
	_PINS_Require(_PINS.Controllers[1].Attempts == 2 && _PINS.Controllers[1].Closed == 1
		&& !DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[1], "Int") && _PiEdWeb_RetiredHosts.Length == 0,
		"Retry must retire the exact formerly refused browser and its native host")
	if _PINS.Mode == "retry-current" {
		_PINS_Require(_PINS.Windows.Length == 2 && _PINS.Controllers.Length == 2
			&& _PiEdWeb_Gui == _PINS.Windows[2] && !_PiEdWeb_ResetDone,
			"A current request must still open after successful retirement without an intervening public intent")
		_PINS_RetryNativeClose(2, true)
	} else {
		_PINS_Require(_PINS.RetrySuccessor && _PINS.RetrySuccessorClosed,
			"The nested public successor must really open and complete native Close before the outer opening resumes")
		_PINS_Require(_PINS.Windows.Length == 2 && _PINS.Controllers.Length == 2
			&& !IsObject(_PiEdWeb_Gui) && _PiEdWeb_ResetDone,
			"The older request must not reopen an editor after the intervening native cancellation")
	}
}

_PINS_Main() {
	global _PINS, _VendorDir, _SharedDir, ScriptInformation
	global PersonalInformation, PersonalInformationLetters, HSE_RuntimeDecisionGeneration
	global _PiEdWeb_Gui, _PiEdWeb_Controller, _PiEdWeb_ResetDone
	global _PiEdWeb_EditorSource, _PiEdWeb_SessionEpoch
	if A_Args.Length != 5 || A_Args[1] != "personal-info"
		ExitApp(2)
	Mode := A_Args[2], Root := A_Args[3]
	_PINS_Require(Mode == "current" || Mode == "destroy-reopen" || Mode == "reset-close" || Mode == "subscription-current" || Mode == "subscription-close" || Mode == "subscription-reset-close" || Mode == "subscription-error-current" || Mode == "subscription-error-reopen" || Mode == "subscription-reset-retain" || Mode == "retry-current" || Mode == "retry-reentry")
	_PINS := {Mode: Mode, AddEntered: 0, CloseAcknowledged: false, HwndAtAddReturn: false,
		HwndAtControllerClose: false, RetiredAtControllerClose: 0, SubscriptionsRetired: 0, ResetRetained: false, ResetCloseDetached: false, Errors: 0, CloseReopen: false,
		Windows: [], Hwnds: [], Controllers: [], Callbacks: 0, Active: false,
		Fired: false, Failure: 0, Reopens: 0, SeenBeforeReturn: false,
		OldHwnd: 0, NewGui: 0, NewHwnd: 0, NewAliveBefore: false,
		RetryRefuse: false, RetryRefusals: 0, RetryReenter: false, RetrySuccessor: false, RetrySuccessorClosed: false}
	_VendorDir := Root, _SharedDir := Root
	ScriptInformation := Map("PersonalInfoTomlPath", Root . "\personal_info.toml")
	PersonalInformation := Map("first_name", "Private default")
	PersonalInformationLetters := Map("p", "first_name")
	HSE_RuntimeDecisionGeneration := 0
	_PINS_Require(!FSStrictExists(ScriptInformation["PersonalInfoTomlPath"]),
		"The genuine form must capture its own absent-file/default source receipt")
	Subclass := 0, Primary := 0
	Thread("Interrupt", 0)
	try {
		if InStr(Mode, "retry-") == 1 {
			_PINS_RetryExercise()
		} else if Mode == "subscription-reset-retain" {
			OpenFailure := 0
			try PersonalInformationEditor()
			catch Any as OpenError
				OpenFailure := OpenError
			Ready := _PINS.Windows.Length == 1 && _PINS.Controllers.Length == 1
				&& _PiEdWeb_Gui == _PINS.Windows[1]
				&& DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[1], "Int")
				&& _PINS.Controllers[1].Closed == 1 && _PINS.SubscriptionsRetired == 1
				&& _PINS.RetiredAtControllerClose == 1 && _PINS.HwndAtControllerClose
			FileAppend("RECEIPT personal-info-subscription mode=" . Mode . " ready=" . Ready
				. " reset_retained=" . _PINS.ResetRetained . " add_alive=" . _PINS.HwndAtAddReturn
				. " close_count=" . (_PINS.Controllers.Length ? _PINS.Controllers[1].Closed : -1)
				. " retired=" . _PINS.SubscriptionsRetired . " error=" . IsObject(OpenFailure) . "`n", "*")
			if IsObject(OpenFailure)
				throw OpenFailure
			_PINS_Require(Ready && _PINS.ResetRetained && _PINS.CloseAcknowledged && _PINS.HwndAtAddReturn,
				"Reset during add must retain the exact GUI while retiring its handle and controller")
			_PiEdWeb_Close(_PINS.Windows[1])
			_PINS_Require(!IsObject(_PiEdWeb_Gui) && !DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[1], "Int")
				&& _PINS.Controllers[1].Closed == 1, "the later Close must destroy the retained GUI without repeating controller close")
		} else if Mode == "subscription-error-current" || Mode == "subscription-error-reopen" {
			OpenFailure := 0, OpenResult := "unset"
			try OpenResult := _PiEdWeb_TryOpen()
			catch Any as OpenError
				OpenFailure := OpenError
			HwndAlive := _PINS.Hwnds.Length ? !!DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[1], "Int") : false
			CloseCount := _PINS.Controllers.Length ? _PINS.Controllers[1].Closed : -1
			FileAppend("RECEIPT personal-info-subscription mode=" . Mode . " result=" . OpenResult
				. " error=" . IsObject(OpenFailure) . " logger_errors=" . _PINS.Errors . " close_count=" . CloseCount
				. " hwnd_alive=" . HwndAlive . " gui=" . IsObject(_PiEdWeb_Gui) . "`n", "*")
			if Mode == "subscription-error-current"
				_PINS_Require(!IsObject(OpenFailure) && OpenResult is Integer && OpenResult == 0
					&& _PINS.Errors == 1 && _PINS.Windows.Length == 1 && _PINS.Controllers.Length == 1
					&& CloseCount == 1 && !HwndAlive && !IsObject(_PiEdWeb_Gui),
					"a current SDK refusal must select the existing fallback and retire its exact native owner")
			else
				_PINS_Require(!IsObject(OpenFailure) && OpenResult is Integer && OpenResult == 1
					&& _PINS.Errors == 1 && _PINS.CloseReopen && _PINS.Windows.Length == 2 && _PINS.Controllers.Length == 2
					&& CloseCount == 1 && !HwndAlive && _PiEdWeb_Gui == _PINS.Windows[2]
					&& _PiEdWeb_Controller == _PINS.Controllers[2] && _PINS.Controllers[2].Closed == 0
					&& DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[2], "Int"),
					"a newer real opening during cleanup must own its host and prevent the old fallback")
		} else if InStr(Mode, "subscription-") {
			OpenFailure := 0
			try PersonalInformationEditor()
			catch Any as OpenError
				OpenFailure := OpenError
			Ready := _PINS.Windows.Length == 1 && _PINS.Controllers.Length == 1
				&& IsSet(_PiEdWeb_Controller) && _PiEdWeb_Controller == _PINS.Controllers[1]
				&& _PINS.Controllers[1].CoreWebView2.Subscriptions == 2
				&& _PINS.Controllers[1].CoreWebView2.Navigations == 1 && _PINS.Controllers[1].Fills >= 1
				&& DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[1], "Int")
			if Mode == "subscription-current" && Ready {
				DllCall("User32\SendMessageW", "Ptr", _PINS.Hwnds[1], "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
				CloseStart := A_TickCount
				while DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[1], "Int") && TickElapsed64(CloseStart) < 1500
					Sleep(10)
			}
			HwndAlive := _PINS.Hwnds.Length ? !!DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[1], "Int") : false
			CloseCount := _PINS.Controllers.Length ? _PINS.Controllers[1].Closed : -1
			FileAppend("RECEIPT personal-info-subscription mode=" . Mode . " ready=" . Ready
				. " add_entered=" . _PINS.AddEntered . " close_ack=" . _PINS.CloseAcknowledged . " reset_retained=" . _PINS.ResetRetained
				. " hwnd_at_return=" . _PINS.HwndAtAddReturn . " hwnd_at_close=" . _PINS.HwndAtControllerClose
				. " retired_at_close=" . _PINS.RetiredAtControllerClose . " retired=" . _PINS.SubscriptionsRetired
				. " close_count=" . CloseCount . " hwnd_alive=" . HwndAlive . " error=" . IsObject(OpenFailure) . "`n", "*")
			if IsObject(OpenFailure)
				throw OpenFailure
			_PINS_Require(_PINS.Windows.Length == 1 && _PINS.Controllers.Length == 1 && CloseCount == 1 && !HwndAlive,
				"the exact native owner must retire once after subscription")
			if Mode == "subscription-current"
				_PINS_Require(Ready && _PINS.SubscriptionsRetired == 2 && _PINS.RetiredAtControllerClose == 2 && _PINS.HwndAtControllerClose,
					"current native close must unsubscribe both handles before controller and host retirement")
			else
				_PINS_Require(_PINS.AddEntered == 1 && _PINS.CloseAcknowledged && _PINS.HwndAtAddReturn
					&& _PINS.HwndAtControllerClose && _PINS.SubscriptionsRetired == 1 && _PINS.RetiredAtControllerClose == 1,
					"close during add must retain the native host until returned subscription is retired before controller close")
			if Mode == "subscription-reset-close"
				_PINS_Require(_PINS.ResetRetained && _PINS.ResetCloseDetached && !IsObject(_PiEdWeb_Gui),
					"plumbing-only Reset must retain the exact GUI until a later Close detaches it")
		} else {
		PersonalInformationEditor()
		_PINS_Require(_PINS.Windows.Length == 1 && _PINS.Controllers.Length == 1,
			"The actual public constructor must complete its current control")
		Old := _PINS.Windows[1], _PINS.OldHwnd := _PINS.Hwnds[1]
		_PINS_Require(_PiEdWeb_Gui == Old && _PiEdWeb_Controller == _PINS.Controllers[1])
		_PINS_Require(DllCall("User32\IsWindowVisible", "Ptr", _PINS.OldHwnd, "Int"))
		if Mode == "destroy-reopen" {
			Subclass := CallbackCreate(_PINS_Destroy, , 6)
			_PINS_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", _PINS.OldHwnd,
				"Ptr", Subclass, "UPtr", 1, "UPtr", 0, "Int"))
			_PINS.Active := true
			DllCall("User32\SendMessageW", "Ptr", _PINS.OldHwnd, "UInt", 0x10,
				"UPtr", 0, "Ptr", 0, "Ptr")
			Started := A_TickCount
			while DllCall("User32\IsWindow", "Ptr", _PINS.OldHwnd, "Int") && TickElapsed64(Started) < 1500
				Sleep(10)
			_PINS.Active := false
			if IsObject(_PINS.Failure)
				throw _PINS.Failure
			FileAppend("RECEIPT personal-info-native-close mode=" . Mode . " destroy=" . _PINS.Fired
				. " reopen_calls=" . _PINS.Reopens . " windows=" . _PINS.Windows.Length
				. " factories=" . _PINS.Controllers.Length . " newer_seen=" . _PINS.SeenBeforeReturn
				. " newer_alive_before=" . _PINS.NewAliveBefore
				. " newer_alive_after=" . (_PINS.NewHwnd ? DllCall("User32\IsWindow", "Ptr", _PINS.NewHwnd, "Int") : 0)
				. " gui_owned=" . (IsObject(_PINS.NewGui) && _PiEdWeb_Gui == _PINS.NewGui)
				. " callbacks=" . _PINS.Callbacks . "`n", "*")
			_PINS_Require(_PINS.Fired && _PINS.Reopens == 1 && _PINS.Controllers[1].Closed == 1,
				"Genuine native destruction must retire the first controller and invoke one actual public request")
			_PINS_Require(!DllCall("User32\IsWindow", "Ptr", _PINS.OldHwnd, "Int"))
			_PINS_Require(_PINS.SeenBeforeReturn && _PINS.NewAliveBefore,
				"The accepted public request during native retirement must open its own live successor")
			_PINS_Require(DllCall("User32\IsWindow", "Ptr", _PINS.NewHwnd, "Int")
				&& _PiEdWeb_Gui == _PINS.NewGui && !_PiEdWeb_ResetDone,
				"Returning old Close must preserve the real successor's live global owner")
			_PINS_Require(_PINS.Controllers.Length == 2 && _PiEdWeb_Controller == _PINS.Controllers[2]
				&& _PINS.Controllers[2].Closed == 0)
		} else if Mode == "reset-close" {
			Source := _PiEdWeb_EditorSource
			_PiEdWeb_Reset()
			ResetEpoch := _PiEdWeb_SessionEpoch
			_PINS_Require(_PiEdWeb_Gui == Old && DllCall("User32\IsWindow", "Ptr", _PINS.OldHwnd, "Int")
				&& _PiEdWeb_ResetDone && _PINS.Controllers[1].Closed == 1 && !Source["active"],
				"A genuine plumbing-only Reset must retain its exact native host after one controller retirement")
			; Before-reload/manual cleanup must still close the retained exact host.
			_PiEdWeb_OnClose(Old)
			_PINS_Require(!DllCall("User32\IsWindow", "Ptr", _PINS.OldHwnd, "Int") && !IsObject(_PiEdWeb_Gui),
				"Exact manual Close after ResetDone must destroy its real retained window")
			_PINS_Require(_PINS.Controllers[1].Closed == 1 && _PiEdWeb_SessionEpoch == ResetEpoch,
				"Closing only a retained host must not repeat COM close or advance the already-retired source")
			_PiEdWeb_OnClose(Old)
			_PINS_Require(_PINS.Controllers[1].Closed == 1 && _PiEdWeb_SessionEpoch == ResetEpoch && !IsObject(_PiEdWeb_Gui),
				"A duplicate exact Close must remain inert after native destruction")
			FileAppend("RECEIPT personal-info-native-close mode=reset-close retained_before=1 native_after=0 controller_closes="
				. _PINS.Controllers[1].Closed . " epoch_preserved=" . (_PiEdWeb_SessionEpoch == ResetEpoch) . "`n", "*")
		} else {
			_PINS_Require(_PINS.Controllers[1].Closed == 0 && !_PiEdWeb_ResetDone)
			FileAppend("RECEIPT personal-info-native-close mode=current windows=1 factories=1 live=1`n", "*")
		}
		}
		_PINS_Require(!FSStrictExists(ScriptInformation["PersonalInfoTomlPath"]), "Opening/closing cannot persist the default identity")
	} catch as Failure {
		Primary := Failure
	} finally {
		_PINS.Active := false
		try _PiEdWeb_Close()
		for Controller in _PINS.Controllers
			if !Controller.Closed
				try Controller.Close()
		for Index, Window in _PINS.Windows
			if DllCall("User32\IsWindow", "Ptr", _PINS.Hwnds[Index], "Int")
				try Window.Destroy()
		if Subclass {
			if DllCall("User32\IsWindow", "Ptr", _PINS.OldHwnd, "Int")
				_PINS_Require(DllCall("Comctl32\RemoveWindowSubclass", "Ptr", _PINS.OldHwnd,
					"Ptr", Subclass, "UPtr", 1, "Int"), "A live window must release the exact callback before it is freed")
			_PINS_Require(_PINS.Callbacks == 0, "No callback may remain on stack when its exact native thunk is freed")
			CallbackFree(Subclass)
		}
	}
	if IsObject(Primary) {
		SplitPath(Primary.File, &FailureOwner)
		FileAppend("FAIL personal-info-native-close " . Type(Primary) . " " . FailureOwner . ":" . Primary.Line . " " . Primary.Message . "`n", "*")
		ExitApp(1)
	}
	FileAppend("PASS editor-early-show personal-info " . Mode . "`n", "*")
	ExitApp(0)
}
_PINS_Main()
