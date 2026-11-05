; tests/fixtures/personal_info_native_close_owner_body.ahk
; Actual public constructor, real GUI/WM_CLOSE/WM_DESTROY, passive browser only.
#Requires AutoHotkey v2.0

_PINS_Require(Condition, Message := "") {
	if !Condition
		throw Error(Message)
}
t(Key) => Key
LoggerSuccess(*) => 0
LoggerError(*) => 0
LoggerWarn(*) => 0
WebView_SharedEnvironment(Loader) => {Passive: true}
Gui_Create(Options := "", Title := "") {
	global _PINS
	Window := Gui(Options, Title)
	_PINS.Windows.Push(Window), _PINS.Hwnds.Push(Window.Hwnd)
	_PINS_Require(_PINS.Windows.Length <= 2, "Only one actual successor may be constructed")
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
		global _PINS, _PiEdWeb_SessionEpoch
		this.Subscriptions += 1
		if _PINS.Mode == "subscription-close" {
			Window := _PINS.Windows[1], Hwnd := Window.Hwnd
			Epoch := _PiEdWeb_SessionEpoch
			NativePid := 0
			_PINS_Require(DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &NativePid, "UInt")
				&& NativePid == ProcessExist(), "the real native close must target the exact private child window")
			_PINS.AddEntered += 1
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
		this.CoreWebView2 := _PINS_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		global _PINS
		this.Closed += 1
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
_PINS_Main() {
	global _PINS, _VendorDir, _SharedDir, ScriptInformation
	global PersonalInformation, PersonalInformationLetters, HSE_RuntimeDecisionGeneration
	global _PiEdWeb_Gui, _PiEdWeb_Controller, _PiEdWeb_ResetDone
	global _PiEdWeb_EditorSource, _PiEdWeb_SessionEpoch
	if A_Args.Length != 5 || A_Args[1] != "personal-info"
		ExitApp(2)
	Mode := A_Args[2], Root := A_Args[3]
	_PINS_Require(Mode == "current" || Mode == "destroy-reopen" || Mode == "reset-close" || Mode == "subscription-current" || Mode == "subscription-close")
	_PINS := {Mode: Mode, AddEntered: 0, CloseAcknowledged: false, HwndAtAddReturn: false,
		HwndAtControllerClose: false, RetiredAtControllerClose: 0, SubscriptionsRetired: 0,
		Windows: [], Hwnds: [], Controllers: [], Callbacks: 0, Active: false,
		Fired: false, Failure: 0, Reopens: 0, SeenBeforeReturn: false,
		OldHwnd: 0, NewGui: 0, NewHwnd: 0, NewAliveBefore: false}
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
		if InStr(Mode, "subscription-") {
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
				. " add_entered=" . _PINS.AddEntered . " close_ack=" . _PINS.CloseAcknowledged
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
