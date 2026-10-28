; tests/fixtures/action_picker_confirmation_failure_body.ahk

; ==============================================================================
; MODULE: Action Picker Confirmation Failure Child
; DESCRIPTION:
; The public picker, native GUI, actual confirmation and central logger execute
; unchanged. Caller callbacks provide controlled failure values, while browser
; effects remain passive. Every refused callback must reach the ERROR queue.
; ==============================================================================

#Requires AutoHotkey v2.0

_APCF_Require(Condition, Message) {
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
WebView_SharedEnvironment(Loader) => { Passive: true }

Gui_Create(Options := "", Title := "") {
	global _APCF
	Window := Gui(Options, Title)
	_APCF.Windows.Push(Window)
	_APCF.Hwnds.Push(Window.Hwnd)
	return Window
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		_APCF_Require(!IsSet(Callback) && Environment.Passive,
			"The production call must use its synchronous constructor contract.")
		return _APCF_Create(Hwnd)
	}
}

class _APCF_View {
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

class _APCF_Controller {
	__New() {
		this.CoreWebView2 := _APCF_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
		_APCF_CloseBoundary(this)
	}
	Fill() {
		this.Fills += 1
	}
}

_APCF_Create(Hwnd) {
	global _APCF, _ActPickWeb_Gui
	_APCF_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "The passive browser boundary receives the genuine native placeholder.")
	Controller := _APCF_Controller()
	_APCF.Controllers.Push(Controller)
	return Controller
}

_APCF_Reopen() {
	global _APCF
	try ShowActionPicker("Private successor picker", "none", _APCF_Confirm.Bind("next"))
	catch Any as Failure
		_APCF.Failure := Failure is Error ? Failure : Error("The confirmation callback threw a " . Type(Failure) . " value.")
	finally _APCF.Delivered += 1
}

_APCF_CloseBoundary(Controller) {
	global _APCF
	if _APCF.Mode != "reopen" || _APCF.Triggered || Controller != _APCF.Controllers[1]
		return
	_APCF.Triggered := true
	_APCF.Timer := _APCF_Reopen
	SetTimer(_APCF.Timer, -1)
	Started := A_TickCount
	while _APCF.Delivered == 0 && ((A_TickCount - Started) & 0xFFFFFFFF) < 3000
		Sleep(10)
	_APCF_Require(_APCF.Delivered == 1, "A native timer must deliver the real public reopen while controller Close is pumping.")
}

_APCF_Confirm(Which, Id) {
	global _APCF
	_APCF_Require(Id == "none", "The real caller must receive its selected action exactly once.")
	_APCF.OldConfirmed += 1
	if _APCF.Mode == "error"
		throw Error("Controlled caller assignment refusal")
	if _APCF.Mode == "empty-error"
		throw Error("")
	if _APCF.Mode == "string-error"
		throw "Controlled scalar assignment refusal"
	if _APCF.Mode == "map-error"
		throw Map("controlled", true)
}

; An asynchronous exception cannot cross the suspended Main try/catch. Suppress
; its modal only after retaining it as a mandatory failure, never as success.
_APCF_OnError(Failure, Mode) {
	global _APCF
	OwnerFile := "UNKNOWN", OwnerLine := 0
	if Failure is Error {
		SplitPath(Failure.File, &OwnerFile)
		OwnerLine := Failure.Line
	}
	if !IsObject(_APCF.Failure)
		_APCF.Failure := Failure is Error ? Failure
			: Error("An asynchronous child failure was observed: " . Type(Failure))
	try FileAppend("DIAG action-picker-startup async type=" . Type(Failure)
		. " file=" . OwnerFile . " line=" . OwnerLine . " mode=" . Mode . "`n", "*", "UTF-8")
	Stack := Error("Observer frame").Stack
	for Line in StrSplit(SubStr(Stack, 1, 2048), "`n", "`r")
		try FileAppend("DIAG action-picker-startup observer-stack " . Line . "`n", "*", "UTF-8")
	return true
}

_APCF_ErrorLines() {
	Lines := []
	for Line in LoggerRingBufferSnapshot()
		if InStr(Line, "[ERROR] [ActionPicker]")
			Lines.Push(Line)
	return Lines
}

_APCF_Main() {
	global _ActPickWeb_ProgramCapturing, _ActPickWeb_Gui, _ActPickWeb_ResetDone, _ActPickWeb_Confirming
	global _LOGGER_PENDING_ERRORS
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _APCF := { Mode: A_Args[1], Windows: [], Hwnds: [], Controllers: [], Pending: 0,
		Boundary: 0, Failure: 0, CloseSent: 0, OldEpoch: 0, OldConfirmed: 0, NextConfirmed: 0,
		Triggered: false, Delivered: 0, Timer: 0 }
	global _VendorDir := A_Args[2], _SharedDir := A_Args[2], _I18nLocale := "en"
	global _LLM_Menu := Map("n_predictions", 3)
	_ActPickWeb_ProgramCapturing := true
	Primary := 0
	try {
		Critical("Off"), Thread("Interrupt", 0)
		ShowActionPicker("Private original picker", "none", _APCF_Confirm.Bind("old"))
		_APCF_Require(_APCF.Controllers.Length == 1 && _ActPickWeb_Gui == _APCF.Windows[1], "The real public picker must publish before any confirmation.")
		Returned := _ActPickWeb_Confirm("none")
		ErrorLines := _APCF_ErrorLines()
		_APCF_Require(_APCF.OldConfirmed == 1 && !_ActPickWeb_Confirming && _ActPickWeb_ResetDone
			&& !IsObject(_ActPickWeb_Gui) && _APCF.Controllers[1].Closed == 1,
			"The actual confirmation must invoke its caller once and complete real native teardown.")
		if _APCF.Mode == "current"
			_APCF_Require(Returned is Integer && Returned == 1 && ErrorLines.Length == 0 && _LOGGER_PENDING_ERRORS.Length == 0, "A healthy caller must still succeed without an error diagnostic.")
		else
			_APCF_Require(Returned is Integer && Returned == 0 && ErrorLines.Length == 1 && _LOGGER_PENDING_ERRORS.Length == 1,
				"A failed actual assignment callback must reach the real central ERROR ring and pending error queue instead of disappearing after the picker closed.")
		if _APCF.Mode != "current" {
			_APCF_Require(InStr(ErrorLines[1], "Action picker confirmation failed"), "The central logger must identify the failed operation.")
			if _APCF.Mode == "error"
				_APCF_Require(InStr(ErrorLines[1], "Controlled caller assignment refusal"), "The actual Error message must survive central formatting.")
		}
	} catch Any as Failure {
		Primary := Failure is Error ? Failure : Error("The confirmation child threw a " . Type(Failure) . " value.")
	} finally {
		_APCF.Triggered := true
		try {
			_ActPickWeb_Close()
			for Controller in _APCF.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Index, Window in _APCF.Windows
				if DllCall("User32\IsWindow", "Ptr", _APCF.Hwnds[Index], "Int")
					Window.Destroy()
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure is Error ? Failure : Error("The confirmation child threw a " . Type(Failure) . " value.")
		}
	}
	if IsObject(Primary) {
		FileAppend("FAIL action-picker-confirmation-failure " . Primary.Message . "`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS action-picker-confirmation-failure " . _APCF.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}
_APCF_Main()
