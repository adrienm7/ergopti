; tests/fixtures/action_picker_reset_owner_body.ahk

; ==============================================================================
; MODULE: Action Picker Teardown Owner Child
; DESCRIPTION:
; Public opening and native WM_CLOSE run unchanged. A passive browser Close
; pumps a real native timer that opens the public replacement before returning.
; The retired reset must preserve every reference and callback of that successor.
; ==============================================================================

#Requires AutoHotkey v2.0

_APRC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; Discovery and rendering data are outside this lifecycle fixture. The actual
; provider owner remains included, with its capture guard already held.
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
WebView_SharedEnvironment(Loader) => { Passive: true }

Gui_Create(Options := "", Title := "") {
	global _APRC
	Window := Gui(Options, Title)
	_APRC.Windows.Push(Window)
	_APRC.Hwnds.Push(Window.Hwnd)
	return Window
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		_APRC_Require(!IsSet(Callback) && Environment.Passive,
			"The production call must use its synchronous constructor contract.")
		return _APRC_Create(Hwnd)
	}
}

class _APRC_View {
	__New() {
		this.Settings := {}, this.Subscriptions := 0, this.Navigations := 0
	}
	WebMessageReceived(Callback) {
		this.Subscriptions += 1
		return { Callback: Callback }
	}
	NavigationCompleted(Callback) {
		this.Subscriptions += 1
		return { Callback: Callback }
	}
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
}

class _APRC_Controller {
	__New() {
		this.CoreWebView2 := _APRC_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
		_APRC_CloseBoundary(this)
	}
	Fill() {
		this.Fills += 1
	}
}

_APRC_Create(Hwnd) {
	global _APRC, _ActPickWeb_Gui
	_APRC_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "The passive browser boundary receives the genuine native placeholder.")
	Controller := _APRC_Controller()
	_APRC.Controllers.Push(Controller)
	return Controller
}

_APRC_Reopen() {
	global _APRC
	try ShowActionPicker("Private successor picker", "none", _APRC_Confirm.Bind("next"))
	catch Any as Failure
		_APRC.Failure := Failure is Error ? Failure : Error("The public reopen callback threw a " . Type(Failure) . " value.")
	finally _APRC.Delivered += 1
}

_APRC_CloseBoundary(Controller) {
	global _APRC
	if _APRC.Mode != "replace-during-close" || _APRC.Triggered || Controller != _APRC.Controllers[1]
		return
	_APRC.Triggered := true
	_APRC.Timer := _APRC_Reopen
	SetTimer(_APRC.Timer, -1)
	Started := A_TickCount
	while _APRC.Delivered == 0 && ((A_TickCount - Started) & 0xFFFFFFFF) < 3000
		Sleep(10)
	_APRC_Require(_APRC.Delivered == 1, "A native timer must deliver the real public reopen while controller Close is pumping.")
}

_APRC_Confirm(Which, Id) {
	global _APRC
	_APRC_Require(Id == "none", "The genuine callback preserves the selected action.")
	if Which == "next"
		_APRC.NextConfirmed += 1
	else
		_APRC.OldConfirmed += 1
}

; An asynchronous exception cannot cross the suspended Main try/catch. Suppress
; its modal only after retaining it as a mandatory failure, never as success.
_APRC_OnError(Failure, Mode) {
	global _APRC
	OwnerFile := "UNKNOWN", OwnerLine := 0
	if Failure is Error {
		SplitPath(Failure.File, &OwnerFile)
		OwnerLine := Failure.Line
	}
	if !IsObject(_APRC.Failure)
		_APRC.Failure := Failure is Error ? Failure
			: Error("An asynchronous child failure was observed: " . Type(Failure))
	try FileAppend("DIAG action-picker-startup async type=" . Type(Failure)
		. " file=" . OwnerFile . " line=" . OwnerLine . " mode=" . Mode . "`n", "*", "UTF-8")
	Stack := Error("Observer frame").Stack
	for Line in StrSplit(SubStr(Stack, 1, 2048), "`n", "`r")
		try FileAppend("DIAG action-picker-startup observer-stack " . Line . "`n", "*", "UTF-8")
	return true
}

_APCC_NativeCreate(WParam, LParam, Message, Hwnd) {
	global _APRC
	ClassBuffer := Buffer(256, 0)
	if !DllCall("User32\GetClassNameW", "Ptr", Hwnd, "Ptr", ClassBuffer, "Int", 128, "Int")
		return
	if StrGet(ClassBuffer, "UTF-16") != "AutoHotkeyGUI"
		return
	_APRC.CreateEvents += 1
	if _APRC.Mode != "reopen-create" || _APRC.Triggered
		return
	_APRC.Triggered := true
	try {
		_APRC.OriginalHwnd := Hwnd
		ShowActionPicker("Private successor picker", "none", _APRC_Confirm.Bind("next"))
		_APRC.Delivered += 1
	} catch Any as Failure
		_APRC.Failure := Failure is Error ? Failure : Error("The public native creation callback threw " . Type(Failure))
}

_APRC_Main() {
	global _ActPickWeb_ProgramCapturing, _ActPickWeb_Gui, _ActPickWeb_ResetDone
	global _ActPickWeb_Controller, _ActPickWeb_WebView, _ActPickWeb_MsgSub, _ActPickWeb_NavSub
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _APRC := { Mode: A_Args[1], Windows: [], Hwnds: [], Controllers: [], Pending: 0,
		Boundary: 0, Failure: 0, CloseSent: 0, OldEpoch: 0, OldConfirmed: 0, NextConfirmed: 0,
		Triggered: false, Delivered: 0, Timer: 0, CreateEvents: 0, OriginalHwnd: 0 }
	global _VendorDir := A_Args[2], _SharedDir := A_Args[2], _I18nLocale := "en"
	global _LLM_Menu := Map("n_predictions", 3)
	_ActPickWeb_ProgramCapturing := true
	Primary := 0
	OnError(_APRC_OnError)
	OnMessage(0x1, _APCC_NativeCreate, 2)
	try {
		Critical("Off"), Thread("Interrupt", 0)
		ShowActionPicker("Private original picker", "none", _APRC_Confirm.Bind("old"))
		if IsObject(_APRC.Failure)
			throw _APRC.Failure
		FileAppend("RECEIPT picker-create mode=" . _APRC.Mode . " create_events=" . _APRC.CreateEvents
			. " windows=" . _APRC.Windows.Length . " controllers=" . _APRC.Controllers.Length
			. " delivered=" . _APRC.Delivered . " published_successor=" . (_ActPickWeb_Gui == _APRC.Windows[1]) . "`n", "*", "UTF-8")
		if _APRC.Mode == "replace-during-close" {
			ShowActionPicker("Private intermediate picker", "none", _APRC_Confirm.Bind("old"))
			_APRC_Require(_APRC.Delivered == 1 && _APRC.Windows.Length >= 2 && _APRC.Controllers.Length >= 2,
				"A genuine native timer must fully open the newer public picker during replacement retirement.")
			FileAppend("RECEIPT picker-replacement windows=" . _APRC.Windows.Length
				. " controllers=" . _APRC.Controllers.Length . " delivered=" . _APRC.Delivered
				. " newest_published=" . (_ActPickWeb_Gui == _APRC.Windows[2]) . "`n", "*", "UTF-8")
			_APRC_Require(_ActPickWeb_Gui == _APRC.Windows[2] && _APRC.Windows.Length == 2
				&& _ActPickWeb_Controller == _APRC.Controllers[2] && !_ActPickWeb_ResetDone,
				"An older replacement request must not overwrite a newer picker opened during native retirement.")
			_APRC_Require(_ActPickWeb_Confirm("none") && _APRC.NextConfirmed == 1 && _APRC.OldConfirmed == 0,
				"Only the newest public request may retain its working confirmation.")
		} else if _APRC.Mode == "current" {
			_APRC_Require(_APRC.Windows.Length == 1 && _APRC.Controllers.Length == 1
				&& _ActPickWeb_Gui == _APRC.Windows[1], "The healthy public picker must publish its one complete native owner.")
			_APRC_Require(_ActPickWeb_Confirm("none") && _APRC.OldConfirmed == 1 && _APRC.NextConfirmed == 0,
				"The positive native constructor must preserve its callable confirmation.")
		} else {
			_APRC_Require(_APRC.CreateEvents == 2 && _APRC.Windows.Length == 2 && _APRC.Controllers.Length == 1
				&& _APRC.Delivered == 1, "The successor must fully open inside the original GUI's actual native WM_CREATE.")
			_APRC_Require(!DllCall("User32\IsWindow", "Ptr", _APRC.OriginalHwnd, "Int")
				&& DllCall("User32\IsWindowVisible", "Ptr", _APRC.Hwnds[1], "Int"),
				"Only the retired original native GUI may be destroyed after its constructor resumes.")
			_APRC_Require(_ActPickWeb_Gui == _APRC.Windows[1] && !_ActPickWeb_ResetDone
				&& IsSet(_ActPickWeb_Controller) && _ActPickWeb_Controller == _APRC.Controllers[1],
				"The resumed original constructor must preserve the successor's actual native owner slot.")
			_APRC_Require(_ActPickWeb_Confirm("none") && _APRC.NextConfirmed == 1 && _APRC.OldConfirmed == 0,
				"The successor alone must retain its working public confirmation after native construction reentry.")
		}
	} catch Any as Failure {
		Primary := Failure is Error ? Failure : Error("The public native constructor child threw " . Type(Failure))
	} finally {
		OnMessage(0x1, _APCC_NativeCreate, 0)
		_APRC.Triggered := true
		try {
			_ActPickWeb_Close()
			for Controller in _APRC.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Index, Window in _APRC.Windows
				if DllCall("User32\IsWindow", "Ptr", _APRC.Hwnds[Index], "Int")
					Window.Destroy()
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure is Error ? Failure : Error("The constructor child cleanup threw " . Type(Failure))
		}
		OnError(_APRC_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_APRC.Failure)
		Primary := _APRC.Failure
	if IsObject(Primary) {
		FileAppend("FAIL picker-create-owner " . Primary.Message . "`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS picker-create-owner " . _APRC.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}
_APRC_Main()
