; tests/fixtures/editor_early_show_owner_body.ahk

; ==============================================================================
; MODULE: Native Editor Show Ownership Child
; DESCRIPTION:
; Real Gui.Show pumps a real WM_CLOSE before browser construction. Native
; messages and the original Close handler own cancellation; only browser,
; discovery/rendering data and diagnostics are passive external boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0

t(Key) => Key
GestureActionPickerItems() => []
GestureActionParameterPrompt(Action) => Action
GestureSendInputErrorText(Kind) => Kind
SendInputVocabularyJson() => "[]"
LLM_Menu_PromptChoices() => []
LLM_Vision_BackendChoices() => []
LLM_Translate_ShippedChoices() => []
GestureClearPickedParameter() => 0
LoggerSuccess(*) => 0
LoggerError(*) => 0
LoggerWarn(*) => 0

_ESOW_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_ESOW_State() {
	global _ESOW
	global _ActPickWeb_Gui, _ActPickWeb_SessionEpoch, _ActPickWeb_ResetDone
	global _ActPickWeb_Controller, _ActPickWeb_WebView, _ActPickWeb_MsgSub, _ActPickWeb_NavSub
	global _PathsEdWeb_Gui, _PathsEdWeb_SessionEpoch, _PathsEdWeb_ResetDone
	global _PathsEdWeb_Controller, _PathsEdWeb_WebView, _PathsEdWeb_MsgSub, _PathsEdWeb_NavSub
	if _ESOW.Owner == "action-picker"
		return {Window: _ActPickWeb_Gui, Epoch: _ActPickWeb_SessionEpoch, Reset: _ActPickWeb_ResetDone,
			Controller: IsSet(_ActPickWeb_Controller) ? _ActPickWeb_Controller : 0,
			View: IsSet(_ActPickWeb_WebView) ? _ActPickWeb_WebView : 0,
			Message: IsSet(_ActPickWeb_MsgSub), Navigation: IsSet(_ActPickWeb_NavSub)}
	return {Window: _PathsEdWeb_Gui, Epoch: _PathsEdWeb_SessionEpoch, Reset: _PathsEdWeb_ResetDone,
		Controller: IsSet(_PathsEdWeb_Controller) ? _PathsEdWeb_Controller : 0,
		View: IsSet(_PathsEdWeb_WebView) ? _PathsEdWeb_WebView : 0,
		Message: IsSet(_PathsEdWeb_MsgSub), Navigation: IsSet(_PathsEdWeb_NavSub)}
}

_ESOW_Record(Phase, Record) {
	global _ESOW
	State := _ESOW_State()
	if _ESOW.Trace.Length < 32
		_ESOW.Trace.Push(Map("phase", Phase, "window", Record.Index, "hwnd", Record.Hwnd,
			"epoch", State.Epoch, "published", State.Window == Record.Window,
			"exists", DllCall("User32\IsWindow", "Ptr", Record.Hwnd, "Int"),
			"visible", DllCall("User32\IsWindowVisible", "Ptr", Record.Hwnd, "Int"),
			"constructors", _ESOW.Controllers.Length, "environments", _ESOW.Environments,
			"public_returned", _ESOW.PublicReturned, "critical", A_IsCritical,
			"state_window_record", _ESOW_IdentityRecord(State.Window, "window"),
			"state_controller_record", _ESOW_IdentityRecord(State.Controller, "controller"),
			"state_view_record", _ESOW_IdentityRecord(State.View, "view"),
			"reset", State.Reset, "message_sub_set", State.Message, "navigation_sub_set", State.Navigation,
			"close_return_instrumented", HasProp(Record, "CallbackReturned") && Record.CallbackReturned))
}

Gui_Create(Options := "", Title := "") {
	global _ESOW
	Window := Gui(Options, Title)
	Record := {Window: Window, Hwnd: Window.Hwnd, Index: _ESOW.Windows.Length + 1,
		Epoch: _ESOW_State().Epoch, ShowCount: 0, CloseCount: 0, NativeClose: 0, Controller: 0, ExistsAfterClose: true}
	_ESOW.Windows.Push(Record)
	; Capture the native Func before installing an own registration observer;
	; ObjBindMethod would resolve that later own method instead of retaining it.
	Register := Gui.Prototype.OnEvent.Bind(Window)
	Window.DefineProp("OnEvent", {Call: _ESOW_RegisterEvent.Bind(Record, Register)})
	return Window
}

_ESOW_RegisterEvent(Record, Register, Window, Name, Callback, Options*) {
	_ESOW_Require(Window == Record.Window, "native event registration retains its exact GUI")
	if Name != "Close"
		return Register.Call(Name, Callback, Options*)
	_ESOW_Require(!HasProp(Record, "Callback") && Options.Length == 0,
		"the exact production Close callback is registered once with its original options")
	Record.Callback := Callback
	Record.Relay := _ESOW_CloseEvent.Bind(Record, Callback)
	return Register.Call(Name, Record.Relay, Options*)
}

_ESOW_CloseEvent(Record, Callback, Params*) {
	; This relay is invoked only by the real native Close event. Never replace
	; cancellation with a test cleanup, and preserve the genuine return value.
	_ESOW_CloseObserved(Record, Params*)
	Result := Callback.Call(Params*)
	Record.CallbackReturned := true
	_ESOW_CloseCompleted(Record)
	return Result
}

_ESOW_ShowMessage(WParam, LParam, Message, Hwnd) {
	global _ESOW
	try {
		if !_ESOW.Windows.Length || Hwnd != _ESOW.Windows[1].Hwnd || !WParam
			return
		Record := _ESOW.Windows[1]
		Record.ShowCount += 1
		if _ESOW.Mode == "current" || _ESOW.CloseSent
			return
		ProcessId := 0
		ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &ProcessId, "UInt")
		_ESOW_Require(ProcessId == DllCall("GetCurrentProcessId", "UInt")
			&& ThreadId == DllCall("GetCurrentThreadId", "UInt") && Record.Window.Hwnd == Hwnd,
			"The native show signal must belong to the exact newly owned GUI/thread.")
		_ESOW_Require(!_ESOW.PublicReturned && _ESOW.Controllers.Length == 0 && _ESOW.Environments == 0,
			"The native show boundary must precede public return and every browser callout.")
		_ESOW_Record("native-show-post-close", Record)
		_ESOW.CloseSent += 1
		_ESOW_Require(DllCall("User32\PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int"),
			"The exact native GUI must accept genuine WM_CLOSE.")
	} catch Any as Failure {
		_ESOW.Failure := Failure
	}
}

_ESOW_NativeClose(WParam, LParam, Message, Hwnd) {
	global _ESOW
	if _ESOW.Windows.Length && Hwnd == _ESOW.Windows[1].Hwnd
		_ESOW.Windows[1].NativeClose += 1
}

_ESOW_CloseObserved(Record, Window) {
	global _ESOW
	if Record.Index != 1 || _ESOW.Mode == "current"
		return
	try {
		_ESOW_Require(Window == Record.Window && Window.Hwnd == Record.Hwnd,
			"The real Close event must identify the exact original native owner.")
		State := _ESOW_State()
		_ESOW_Require(Record.ShowCount > 0 && Record.NativeClose == 1 && _ESOW.CloseSent == 1
			&& State.Epoch == Record.Epoch && !_ESOW.PublicReturned
			&& _ESOW.Controllers.Length == 0 && _ESOW.Environments == 0,
			"The actual Close event must precede browser startup, not run during await.")
		Record.CloseCount += 1
		_ESOW_Record("actual-close-before-production", Record)
		; Hold only this admitted native event thread. The exact original Close
		; callback and synchronous observer finish before the old Show resumes.
		Critical("On")
	} catch Any as Failure {
		_ESOW.Failure := Failure
	}
}

_ESOW_CloseCompleted(Record) {
	global _ESOW
	if Record.Index != 1 || _ESOW.Mode == "current"
		return
	try {
		_ESOW.Continuations += 1
		State := _ESOW_State()
		_ESOW_Record("original-close-returned-before-show-resume", Record)
		_ESOW_Require(_ESOW.Continuations == 1 && Record.CloseCount == 1 && State.Epoch > Record.Epoch
			&& !_ESOW.PublicReturned && _ESOW.Controllers.Length == 0 && _ESOW.Environments == 0,
			"The exact original Close callback must retire its owner before its native event thread returns.")
		Record.ExistsAfterClose := DllCall("User32\IsWindow", "Ptr", Record.Hwnd, "Int")
		_ESOW_Require(!Record.ExistsAfterClose && State.Reset && State.Window != Record.Window,
			"The original Close callback must detach and destroy its exact native owner.")
		if _ESOW.Mode == "reopen" {
			_ESOW_Open()
			_ESOW_Require(_ESOW.Windows.Length == 2, "The successor must use the same genuine public constructor.")
			_ESOW.Successor := _ESOW_State()
			_ESOW_Record("successor-public-return", _ESOW.Windows[2])
		}
	} catch Any as Failure {
		if !IsObject(_ESOW.Failure)
			_ESOW.Failure := Failure
	}
}

_ESOW_LateNotification(WParam, LParam, Message, Hwnd) {
	global _ESOW
	try {
		Record := _ESOW.Windows[1]
		_ESOW_Require(_ESOW.Mode == "close-after-return" && Hwnd == A_ScriptHwnd
			&& Message == _ESOW.Signal && WParam == Record.Hwnd,
			"the late message is fixture bookkeeping for the exact already-retired owner")
		_ESOW.LateNotifications += 1
		_ESOW_Require(_ESOW.PublicReturned && _ESOW.Continuations == 1,
			"late bookkeeping must follow the observed real callback and public return")
		_ESOW_Record("late-test-notification", Record)
	} catch Any as Failure {
		if !IsObject(_ESOW.Failure)
			_ESOW.Failure := Failure
	}
}

_ESOW_Open() {
	global _ESOW
	if _ESOW.Owner == "action-picker"
		ShowActionPicker("Private early-show owner", "none", _ESOW_Confirm)
	else
		FilePathsEditor()
}

_ESOW_Confirm(*) {
	global _ESOW
	_ESOW.Confirmations += 1
}

WebView_SharedEnvironment(Loader) {
	global _ESOW
	_ESOW.Environments += 1
	return {Passive: true}
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		global _ESOW
		_ESOW_Require(!IsSet(Callback) && Environment.Passive,
			"The external browser boundary must preserve its actual synchronous ABI.")
		Parent := DllCall("User32\GetParent", "Ptr", Hwnd, "Ptr"), Owned := 0
		for Record in _ESOW.Windows
			if Record.Hwnd == Parent
				Owned := Record
		_ESOW_Require(IsObject(Owned) && DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
			"The passive browser boundary must receive a real owned placeholder.")
		Controller := _ESOW_Controller()
		Owned.Controller := Controller
		_ESOW.Controllers.Push(Controller)
		return Controller
	}
}

class _ESOW_View {
	__New() {
		this.Settings := {}, this.Subscriptions := 0, this.Navigations := 0
	}
	WebMessageReceived(Callback) {
		this.Subscriptions += 1
		return {Callback: Callback}
	}
	NavigationCompleted(Callback) {
		this.Subscriptions += 1
		return {Callback: Callback}
	}
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
}

class _ESOW_Controller {
	__New() {
		this.CoreWebView2 := _ESOW_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}

; These stable fixture ordinals identify the actual retained object references.
; No GUI property, native call, object address or browser getter is needed here.
_ESOW_IdentityRecord(Value, Kind) {
	global _ESOW
	if !IsObject(Value)
		return 0
	if Kind == "window" {
		for Record in _ESOW.Windows
			if Record.Window == Value
				return Record.Index
		return -1
	}
	for Index, Controller in _ESOW.Controllers {
		Candidate := Kind == "view" ? Controller.CoreWebView2 : Controller
		if Candidate == Value
			return Index
	}
	return -1
}

_ESOW_FinalDiagnostic() {
	global _ESOW
	State := _ESOW_State(), Successor := _ESOW.Successor
	HasSuccessor := IsObject(Successor)
	Target := _ESOW.Windows.Length >= 2 ? _ESOW.Windows[2] : _ESOW.Windows[1]
	Controller := Target.Controller
	View := IsObject(Controller) ? Controller.CoreWebView2 : 0
	; Capture each conjunct separately without replacing either original oracle.
	Diagnostic := Map("owner", _ESOW.Owner, "mode", _ESOW.Mode,
		"window_count_two", _ESOW.Windows.Length == 2, "successor_available", HasSuccessor,
		"epoch_match", HasSuccessor && State.Epoch == Successor.Epoch,
		"window_match", HasSuccessor && State.Window == Successor.Window,
		"controller_match", HasSuccessor && State.Controller == Successor.Controller,
		"view_match", HasSuccessor && State.View == Successor.View,
		"current_ready", _ESOW_CurrentReady(Target),
		"final_epoch", State.Epoch, "successor_epoch", HasSuccessor ? Successor.Epoch : -1,
		"final_window_record", _ESOW_IdentityRecord(State.Window, "window"),
		"successor_window_record", HasSuccessor ? _ESOW_IdentityRecord(Successor.Window, "window") : -1,
		"final_controller_record", _ESOW_IdentityRecord(State.Controller, "controller"),
		"successor_controller_record", HasSuccessor ? _ESOW_IdentityRecord(Successor.Controller, "controller") : -1,
		"final_view_record", _ESOW_IdentityRecord(State.View, "view"),
		"successor_view_record", HasSuccessor ? _ESOW_IdentityRecord(Successor.View, "view") : -1,
		"ready_window_match", State.Window == Target.Window, "ready_epoch_match", State.Epoch == Target.Epoch,
		"ready_reset_clear", !State.Reset, "ready_controller_present", IsObject(Controller),
		"ready_controller_match", State.Controller == Controller, "ready_view_match", State.View == View,
		"ready_message_sub_set", State.Message, "ready_navigation_sub_set", State.Navigation,
		"ready_closed", IsObject(Controller) ? Controller.Closed : -1,
		"ready_fills", IsObject(Controller) ? Controller.Fills : -1,
		"ready_subscriptions", IsObject(View) ? View.Subscriptions : -1,
		"ready_navigations", IsObject(View) ? View.Navigations : -1,
		"ready_native_visible", DllCall("User32\IsWindowVisible", "Ptr", Target.Hwnd, "Int"),
		"target_window_record", Target.Index, "source_sha256", A_Args[4], "runtime_sha256", A_Args[5])
	FileAppend("DIAGNOSTIC editor-early-show " . KL_JsonEncode(Diagnostic) . "`n", "*", "UTF-8")
}

_ESOW_CurrentReady(Record) {
	State := _ESOW_State(), Controller := Record.Controller
	return State.Window == Record.Window && State.Epoch == Record.Epoch && !State.Reset
		&& IsObject(Controller) && State.Controller == Controller && State.View == Controller.CoreWebView2
		&& State.Message && State.Navigation && Controller.Closed == 0 && Controller.Fills > 0
		&& Controller.CoreWebView2.Subscriptions == 2 && Controller.CoreWebView2.Navigations == 1
		&& DllCall("User32\IsWindowVisible", "Ptr", Record.Hwnd, "Int")
}

_ESOW_Check() {
	global _ESOW
	if IsObject(_ESOW.Failure)
		throw _ESOW.Failure
	Old := _ESOW.Windows[1], State := _ESOW_State()
	_ESOW_Require(_ESOW.Confirmations == 0, "A native Close must never confirm an action.")
	if _ESOW.Mode == "current" {
		_ESOW_Require(_ESOW.Windows.Length == 1 && _ESOW.Controllers.Length == 1
			&& _ESOW.CloseSent == 0 && _ESOW.Continuations == 0 && _ESOW_CurrentReady(Old),
			"The normal positive must publish one fully current native/browser owner.")
		return
	}
	_ESOW_Require(Old.ShowCount > 0 && Old.NativeClose == 1 && Old.CloseCount == 1 && _ESOW.Continuations == 1,
		"The early cancellation must be an observed native Show/WM_CLOSE/original-handler chain.")
	_ESOW_Require(!Old.ExistsAfterClose,
		"Close during native Show must destroy the exact original native window.")
	_ESOW_Require(State.Window != Old.Window,
		"The suspended Show frame must never publish its retired native owner.")
	if IsObject(Old.Controller)
		_ESOW_Require(Old.Controller.Closed == 1 && Old.Controller.CoreWebView2.Subscriptions == 0
			&& Old.Controller.CoreWebView2.Navigations == 0 && Old.Controller.Fills == 0,
			"Any browser returned to a retired Show frame must remain private and retire exactly once.")
	if _ESOW.Mode == "reopen" {
		_ESOW_Require(_ESOW.Windows.Length == 2 && IsObject(_ESOW.Successor)
			&& State.Epoch == _ESOW.Successor.Epoch && State.Window == _ESOW.Successor.Window
			&& State.Controller == _ESOW.Successor.Controller && State.View == _ESOW.Successor.View
			&& _ESOW_CurrentReady(_ESOW.Windows[2]),
			"The resumed old Show frame must preserve the entire public successor unchanged.")
	} else
		_ESOW_Require(_ESOW.Windows.Length == 1 && !IsObject(State.Window) && State.Reset
			&& !IsObject(State.Controller) && !IsObject(State.View) && !State.Message && !State.Navigation,
			"A consumed early Close must leave no stale GUI/browser/subscriptions or native fallback.")
}

_ESOW_OnError(Failure, Mode) {
	global _ESOW
	if !IsObject(_ESOW.Failure)
		_ESOW.Failure := Failure
	return true
}

_ESOW_Main() {
	global _ESOW, _VendorDir, _SharedDir, _ConfigDir, _PathsFile, _I18nLocale, _LLM_Menu
	global _ActPickWeb_ProgramCapturing
	_ESOW_Require(A_Args.Length == 5, "The owned child ABI must be exact.")
	_ESOW_Require(CryptoSha256Bytes(FileRead(A_ScriptFullPath, "RAW")) == A_Args[4]
		&& CryptoSha256Bytes(FileRead(A_AhkPath, "RAW")) == A_Args[5], "Actual child source/runtime bytes must match.")
	Persistent(true)
	_ESOW := {Owner: A_Args[1], Mode: A_Args[2], Windows: [], Controllers: [], Trace: [], Failure: 0,
		CloseSent: 0, Continuations: 0, LateNotifications: 0, PublicReturned: false, Environments: 0, Successor: 0, Confirmations: 0}
	_ESOW_Require(_ESOW.Owner == "action-picker" || _ESOW.Owner == "paths", "The source owner must be exact.")
	_ESOW_Require(_ESOW.Mode == "current" || _ESOW.Mode == "close" || _ESOW.Mode == "reopen" || _ESOW.Mode == "close-after-return", "The mode must be exact.")
	_ESOW.Signal := DllCall("User32\RegisterWindowMessageW", "Str", "ErgoptiPlus.EarlyShow." . A_ScriptHwnd, "UInt")
	_ESOW_Require(_ESOW.Signal >= 0xC000, "The private signal must be outside emergency OnMessage IDs.")
	_VendorDir := A_Args[3], _SharedDir := A_Args[3], _ConfigDir := A_Args[3] . "\", _PathsFile := A_Args[3] . "\unwritten.toml"
	_I18nLocale := "en", _LLM_Menu := Map("n_predictions", 3), _ActPickWeb_ProgramCapturing := true
	Primary := 0
	OnError(_ESOW_OnError)
	OnMessage(0x18, _ESOW_ShowMessage), OnMessage(0x10, _ESOW_NativeClose), OnMessage(_ESOW.Signal, _ESOW_LateNotification)
	try {
		; Critical Off changes only this child caller, making the native final Show
		; pump eligible. No zero-grace default or extra sleep manufactures a yield.
		Critical("Off"), Thread("Priority", 0)
		_ESOW_Open()
		_ESOW.PublicReturned := true
		if _ESOW.Mode == "close-after-return" {
			Old := _ESOW.Windows[1], State := _ESOW_State()
			_ESOW_Require(Old.NativeClose == 1 && Old.CloseCount == 1 && State.Epoch > Old.Epoch
				&& State.Reset && State.Window != Old.Window && !DllCall("User32\IsWindow", "Ptr", Old.Hwnd, "Int")
				&& !IsObject(State.Controller) && !IsObject(State.View) && !State.Message && !State.Navigation
				&& _ESOW.Controllers.Length == 0 && _ESOW.Environments == 0,
				"The original Close must already fully retire its actual GUI before late test bookkeeping.")
			_ESOW_Record("closed-before-late-test-signal", Old)
			DllCall("User32\SendMessageW", "Ptr", A_ScriptHwnd, "UInt", _ESOW.Signal, "UPtr", Old.Hwnd, "Ptr", 0, "Ptr")
			_ESOW_Require(_ESOW.LateNotifications == 1, "the actual late bookkeeping message must be observed once")
			_ESOW_Record("closed-after-late-test-signal", Old)
		}
		for Entry in _ESOW.Trace
			FileAppend("TRACE editor-early-show " . KL_JsonEncode(Entry) . "`n", "*", "UTF-8")
		FileAppend("RECEIPT editor-early-show " . KL_JsonEncode(Map("owner", _ESOW.Owner, "mode", _ESOW.Mode,
			"windows", _ESOW.Windows.Length, "constructors", _ESOW.Controllers.Length, "close_sent", _ESOW.CloseSent,
			"native_close", _ESOW.Windows[1].NativeClose, "close_events", _ESOW.Windows[1].CloseCount,
			"after_close_callbacks", _ESOW.Continuations, "late_notifications", _ESOW.LateNotifications, "old_exists", DllCall("User32\IsWindow", "Ptr", _ESOW.Windows[1].Hwnd, "Int"),
			"old_published", _ESOW_State().Window == _ESOW.Windows[1].Window,
			"epoch", _ESOW_State().Epoch, "source_sha256", A_Args[4], "runtime_sha256", A_Args[5])) . "`n", "*", "UTF-8")
		_ESOW_FinalDiagnostic()
		_ESOW_Check()
	} catch Any as Failure {
		Primary := Failure
	} finally {
		OnMessage(0x18, _ESOW_ShowMessage, 0), OnMessage(0x10, _ESOW_NativeClose, 0)
		OnMessage(_ESOW.Signal, _ESOW_LateNotification, 0)
		try {
			if _ESOW.Owner == "action-picker"
				_ActPickWeb_Close()
			else
				_PathsEdWeb_Close()
			for Controller in _ESOW.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Record in _ESOW.Windows
				if DllCall("User32\IsWindow", "Ptr", Record.Hwnd, "Int")
					Record.Window.Destroy()
			for Record in _ESOW.Windows
				_ESOW_Require(!DllCall("User32\IsWindow", "Ptr", Record.Hwnd, "Int"), "Every exact private GUI must retire.")
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		OnError(_ESOW_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_ESOW.Failure)
		Primary := _ESOW.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS editor-early-show " . _ESOW.Owner . " " . _ESOW.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_ESOW_Main()
