; tests/fixtures/hcw_early_show_owner_body.ahk

; ==============================================================================
; MODULE: Native Hotstrings Config Show Ownership Child
; DESCRIPTION:
; Real Gui.Show pumps a real WM_CLOSE before browser construction. Native
; messages and the original Close handler own cancellation. Actual data builders
; read the private delivered language index; browser and labels are passive.
; ==============================================================================

#Requires AutoHotkey v2.0

t(Key) => Key
LoggerSuccess(*) => 0
LoggerError(*) => 0

_HESW_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_HESW_State() {
	global _HCWWeb_Gui, _HCWWeb_SessionEpoch, _HCWWeb_ResetDone
	global _HCWWeb_Controller, _HCWWeb_WebView, _HCWWeb_MsgSub, _HCWWeb_NavSub
	return {Window: _HCWWeb_Gui, Epoch: _HCWWeb_SessionEpoch, Reset: _HCWWeb_ResetDone,
		Controller: IsSet(_HCWWeb_Controller) ? _HCWWeb_Controller : 0,
		View: IsSet(_HCWWeb_WebView) ? _HCWWeb_WebView : 0,
		Message: IsSet(_HCWWeb_MsgSub), Navigation: IsSet(_HCWWeb_NavSub)}
}

_HESW_Record(Phase, Record) {
	global _HESW
	State := _HESW_State()
	if _HESW.Trace.Length < 32
		_HESW.Trace.Push(Map("phase", Phase, "window", Record.Index, "hwnd", Record.Hwnd,
			"epoch", State.Epoch, "published", State.Window == Record.Window,
			"exists", DllCall("User32\IsWindow", "Ptr", Record.Hwnd, "Int"),
			"visible", DllCall("User32\IsWindowVisible", "Ptr", Record.Hwnd, "Int"),
			"constructors", _HESW.Controllers.Length, "environments", _HESW.Environments,
			"public_returned", _HESW.PublicReturned, "critical", A_IsCritical))
}

Gui_Create(Options := "", Title := "") {
	global _HESW
	Window := Gui(Options, Title)
	Record := {Window: Window, Hwnd: Window.Hwnd, Index: _HESW.Windows.Length + 1,
		Epoch: _HESW_State().Epoch, ShowCount: 0, CloseCount: 0, NativeClose: 0, Controller: 0, ExistsAfterClose: true}
	_HESW.Windows.Push(Record)
	; A stale web opening must not enter unrelated native fallback controls.
	; Track the real new GUI first so even this refusal retains cleanup custody.
	if _HESW.Windows.Length > (_HESW.Mode == "reopen" ? 2 : 1) {
		_HESW.FallbackAttempts += 1
		throw Error("Business oracle: a retired web opening attempted native fallback.")
	}
	; This observer is first, returns no event result, and never invokes the
	; production handler. The original SessionCall is registered next by SUT.
	Window.OnEvent("Close", _HESW_CloseObserved.Bind(Record))
	return Window
}

_HESW_ShowMessage(WParam, LParam, Message, Hwnd) {
	global _HESW
	try {
		if !_HESW.Windows.Length || Hwnd != _HESW.Windows[1].Hwnd || !WParam
			return
		Record := _HESW.Windows[1]
		Record.ShowCount += 1
		if _HESW.Mode == "current" || _HESW.CloseSent
			return
		ProcessId := 0
		ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &ProcessId, "UInt")
		_HESW_Require(ProcessId == DllCall("GetCurrentProcessId", "UInt")
			&& ThreadId == DllCall("GetCurrentThreadId", "UInt") && Record.Window.Hwnd == Hwnd,
			"The native show signal must belong to the exact newly owned GUI/thread.")
		_HESW_Require(!_HESW.PublicReturned && _HESW.Controllers.Length == 0 && _HESW.Environments == 0,
			"The native show boundary must precede public return and every browser callout.")
		_HESW_Record("native-show-post-close", Record)
		_HESW.CloseSent += 1
		_HESW_Require(DllCall("User32\PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int"),
			"The exact native GUI must accept genuine WM_CLOSE.")
	} catch Any as Failure {
		if !IsObject(_HESW.Failure)
			_HESW.Failure := Failure
	}
}

_HESW_NativeClose(WParam, LParam, Message, Hwnd) {
	global _HESW
	if _HESW.Windows.Length && Hwnd == _HESW.Windows[1].Hwnd
		_HESW.Windows[1].NativeClose += 1
}

_HESW_CloseObserved(Record, Window) {
	global _HESW
	if Record.Index != 1 || _HESW.Mode == "current"
		return
	try {
		_HESW_Require(Window == Record.Window && Window.Hwnd == Record.Hwnd,
			"The real Close event must identify the exact original native owner.")
		State := _HESW_State()
		_HESW_Require(Record.ShowCount > 0 && Record.NativeClose == 1 && _HESW.CloseSent == 1
			&& State.Epoch == Record.Epoch && !_HESW.PublicReturned
			&& _HESW.Controllers.Length == 0 && _HESW.Environments == 0,
			"The actual Close event must precede browser startup, not run during await.")
		Record.CloseCount += 1
		_HESW_Record("actual-close-before-production", Record)
		; Only this newly admitted GUI-event thread becomes Critical. Its original
		; Close handler runs next without a nested reopen; thread retirement restores
		; the caller's eligibility. The high private message cannot be an emergency
		; OnMessage interruption and is delivered by the same native Show pump later.
		Critical("On")
		_HESW_Require(DllCall("User32\PostMessageW", "Ptr", A_ScriptHwnd, "UInt", _HESW.Signal,
			"UPtr", Record.Hwnd, "Ptr", 0, "Int"), "The private after-Close signal must queue.")
	} catch Any as Failure {
		if !IsObject(_HESW.Failure)
			_HESW.Failure := Failure
	}
}

_HESW_AfterClose(WParam, LParam, Message, Hwnd) {
	global _HESW
	try {
		Record := _HESW.Windows[1]
		_HESW_Require(Hwnd == A_ScriptHwnd && Message == _HESW.Signal && WParam == Record.Hwnd,
			"Only the exact private child signal may admit the successor.")
		_HESW.Signals += 1
		State := _HESW_State()
		_HESW_Require(_HESW.Signals == 1 && Record.CloseCount == 1 && State.Epoch > Record.Epoch
			&& !_HESW.PublicReturned && _HESW.Controllers.Length == 0 && _HESW.Environments == 0,
			"The original production Close must revoke its epoch before the native Show pump resumes.")
		Record.ExistsAfterClose := DllCall("User32\IsWindow", "Ptr", Record.Hwnd, "Int")
		_HESW_Record("production-close-completed-before-browser", Record)
		if _HESW.Mode == "reopen" {
			_HESW_Open()
			_HESW_Require(_HESW.Windows.Length == 2, "The successor must use the same genuine public constructor.")
			_HESW.Successor := _HESW_State()
			_HESW_Record("successor-public-return", _HESW.Windows[2])
		}
	} catch Any as Failure {
		if !IsObject(_HESW.Failure)
			_HESW.Failure := Failure
	}
}

_HESW_Open() {
	OpenHotstringsConfigWindow()
}

WebView_SharedEnvironment(Loader) {
	global _HESW
	_HESW.Environments += 1
	return {Passive: true}
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		global _HESW
		_HESW_Require(!IsSet(Callback) && Environment.Passive,
			"The external browser boundary must preserve its actual synchronous ABI.")
		Parent := DllCall("User32\GetParent", "Ptr", Hwnd, "Ptr"), Owned := 0
		for Record in _HESW.Windows
			if Record.Hwnd == Parent
				Owned := Record
		_HESW_Require(IsObject(Owned) && DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
			"The passive browser boundary must receive a real owned placeholder.")
		Controller := _HESW_Controller()
		Owned.Controller := Controller
		_HESW.Controllers.Push(Controller)
		return Controller
	}
}

class _HESW_View {
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

class _HESW_Controller {
	__New() {
		this.CoreWebView2 := _HESW_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}

_HESW_CurrentReady(Record) {
	State := _HESW_State(), Controller := Record.Controller
	return State.Window == Record.Window && State.Epoch == Record.Epoch && !State.Reset
		&& IsObject(Controller) && State.Controller == Controller && State.View == Controller.CoreWebView2
		&& State.Message && State.Navigation && Controller.Closed == 0 && Controller.Fills > 0
		&& Controller.CoreWebView2.Subscriptions == 2 && Controller.CoreWebView2.Navigations == 1
		&& DllCall("User32\IsWindowVisible", "Ptr", Record.Hwnd, "Int")
}

_HESW_Check() {
	global _HESW
	if IsObject(_HESW.Failure)
		throw _HESW.Failure
	Old := _HESW.Windows[1], State := _HESW_State()
	if _HESW.Mode == "current" {
		_HESW_Require(_HESW.Windows.Length == 1 && _HESW.Controllers.Length == 1
			&& _HESW.CloseSent == 0 && _HESW.Signals == 0 && _HESW_CurrentReady(Old),
			"The normal positive must publish one fully current native/browser owner.")
		return
	}
	_HESW_Require(Old.ShowCount > 0 && Old.NativeClose == 1 && Old.CloseCount == 1 && _HESW.Signals == 1,
		"The early cancellation must be an observed native Show/WM_CLOSE/original-handler chain.")
	_HESW_Require(!Old.ExistsAfterClose,
		"Close during native Show must destroy the exact original native window.")
	_HESW_Require(State.Window != Old.Window,
		"The suspended Show frame must never publish its retired native owner.")
	if IsObject(Old.Controller)
		_HESW_Require(Old.Controller.Closed == 1 && Old.Controller.CoreWebView2.Subscriptions == 0
			&& Old.Controller.CoreWebView2.Navigations == 0 && Old.Controller.Fills == 0,
			"Any browser returned to a retired Show frame must remain private and retire exactly once.")
	if _HESW.Mode == "reopen" {
		_HESW_Require(_HESW.Windows.Length == 2 && IsObject(_HESW.Successor)
			&& State.Epoch == _HESW.Successor.Epoch && State.Window == _HESW.Successor.Window
			&& State.Controller == _HESW.Successor.Controller && State.View == _HESW.Successor.View
			&& _HESW_CurrentReady(_HESW.Windows[2]),
			"The resumed old Show frame must preserve the entire public successor unchanged.")
	} else
		_HESW_Require(_HESW.Windows.Length == 1 && !IsObject(State.Window) && State.Reset
			&& !IsObject(State.Controller) && !IsObject(State.View) && !State.Message && !State.Navigation,
			"A consumed early Close must leave no stale GUI/browser/subscriptions or native fallback.")
}

_HESW_OnError(Failure, Mode) {
	global _HESW
	if !IsObject(_HESW.Failure)
		_HESW.Failure := Failure
	return true
}

_HESW_Main() {
	global _HESW, _VendorDir, _SharedDir, _ConfigDir, _I18nLocale, _ExtensionsDir, ScriptInformation
	global _HESW_SourceIndexHash, _HCW_CATEGORY_LIST, _HCW_GROUP_LIST, _TomlFileCache
	_HESW_Require(A_Args.Length == 5, "The owned child ABI must be exact.")
	_HESW_Require(CryptoSha256Bytes(FileRead(A_ScriptFullPath, "RAW")) == A_Args[4]
		&& CryptoSha256Bytes(FileRead(A_AhkPath, "RAW")) == A_Args[5], "Actual child source/runtime bytes must match.")
	Persistent(true)
	_HESW := {Owner: A_Args[1], Mode: A_Args[2], Windows: [], Controllers: [], Trace: [], Failure: 0,
		CloseSent: 0, Signals: 0, PublicReturned: false, Environments: 0, Successor: 0, FallbackAttempts: 0}
	_HESW_Require(_HESW.Owner == "hcw", "The source owner must be exact.")
	_HESW_Require(_HESW.Mode == "current" || _HESW.Mode == "close" || _HESW.Mode == "reopen", "The mode must be exact.")
	_HESW.Signal := DllCall("User32\RegisterWindowMessageW", "Str", "ErgoptiPlus.EarlyShow." . A_ScriptHwnd, "UInt")
	_HESW_Require(_HESW.Signal >= 0xC000, "The private signal must be outside emergency OnMessage IDs.")
	_VendorDir := A_Args[3], _SharedDir := A_Args[3] . "\shared", _ConfigDir := A_Args[3] . "\"
	_ExtensionsDir := A_Args[3] . "\extensions", _I18nLocale := "en"
	ScriptInformation := Map("PersonalHotstringsDir", A_Args[3] . "\personal\")
	Index := _SharedDir . "\modules\hotstrings\_index.toml"
	_HESW_Require(CryptoSha256Bytes(FSReadBytesStrict(Index)) == _HESW_SourceIndexHash,
		"The genuine category builder must receive exact delivered index bytes.")
	Primary := 0
	OnError(_HESW_OnError)
	OnMessage(0x18, _HESW_ShowMessage), OnMessage(0x10, _HESW_NativeClose), OnMessage(_HESW.Signal, _HESW_AfterClose)
	try {
		; Critical Off changes only this child caller, making the native final Show
		; pump eligible. No zero-grace default or extra sleep manufactures a yield.
		Critical("Off"), Thread("Priority", 0)
		_HESW_Open()
		_HESW.PublicReturned := true
		_HESW_Require(_TomlFileCache.Has(Index) && HotstringsLanguagePacks().Length > 0
			&& _HCW_CATEGORY_LIST.Length > 6 && _HCW_GROUP_LIST.Length >= 2,
			"The public opener must use its genuine index/cache/category/group data path.")
		for Entry in _HESW.Trace
			FileAppend("TRACE hcw-early-show " . KL_JsonEncode(Entry) . "`n", "*", "UTF-8")
		FileAppend("RECEIPT hcw-early-show " . KL_JsonEncode(Map("owner", _HESW.Owner, "mode", _HESW.Mode,
			"windows", _HESW.Windows.Length, "constructors", _HESW.Controllers.Length,
			"fallback_attempts", _HESW.FallbackAttempts, "boundary_failure", IsObject(_HESW.Failure),
			"close_sent", _HESW.CloseSent,
			"native_close", _HESW.Windows[1].NativeClose, "close_events", _HESW.Windows[1].CloseCount,
			"after_close_signals", _HESW.Signals, "old_exists", DllCall("User32\IsWindow", "Ptr", _HESW.Windows[1].Hwnd, "Int"),
			"old_published", _HESW_State().Window == _HESW.Windows[1].Window,
			"epoch", _HESW_State().Epoch, "categories", _HCW_CATEGORY_LIST.Length,
			"groups", _HCW_GROUP_LIST.Length, "index_sha256", _HESW_SourceIndexHash,
			"source_sha256", A_Args[4], "runtime_sha256", A_Args[5])) . "`n", "*", "UTF-8")
		_HESW_Check()
	} catch Any as Failure {
		Primary := IsObject(_HESW.Failure) ? _HESW.Failure : Failure
	} finally {
		OnMessage(0x18, _HESW_ShowMessage, 0), OnMessage(0x10, _HESW_NativeClose, 0)
		OnMessage(_HESW.Signal, _HESW_AfterClose, 0)
		try {
			_HCWWeb_Close()
			for Controller in _HESW.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Record in _HESW.Windows
				if DllCall("User32\IsWindow", "Ptr", Record.Hwnd, "Int")
					Record.Window.Destroy()
			for Record in _HESW.Windows
				_HESW_Require(!DllCall("User32\IsWindow", "Ptr", Record.Hwnd, "Int"), "Every exact private GUI must retire.")
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		OnError(_HESW_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_HESW.Failure)
		Primary := _HESW.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS hcw-early-show " . _HESW.Owner . " " . _HESW.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_HESW_Main()
