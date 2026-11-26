; tests/fixtures/magic_key_capture_settlement_body.ahk

; No native InputHook or synthetic input is armed in this child. The passive
; hook reproduces native completion semantics: Stop retains completed input and
; reason. Actual hidden/visible GUI Close, real suspend/resume and the genuine
; singleton owner decide whether the genuine editor may persist that result.
if A_Args.Length != 2 || A_Args[1] != "character"
	ExitApp(2)
_MESC_Modes := Map("live", true, "cancel", true, "completed-close", true, "completed-paused-resumed", true,
	"completed-close-successor", true, "stop-refusal", true, "stop-reentrant", true,
	"scalar-pair", true, "invalid-high-BMP", true, "invalid-low", true, "invalid-max", true, "paused-live", true)
if !_MESC_Modes.Has(A_Args[2])
	ExitApp(2)
global _MagicKeyEditorInputHook := "", _MagicKeyEditorStopDebt := false, _MagicKeyEditorGui := ""
global _MESC := { Editor: A_Args[1], Mode: A_Args[2],
	Windows: [], Hooks: [], Calls: 0, Value: "", Errors: 0, Warnings: 0, Interrupts: 0, Failure: 0, Window: 0, Timer: 0, CloseAcks: 0 }
OnExit(_MESC_Exit)

_MESC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

t(Key) {
	return Key
}

; The prompt names the layout's default through the shared display rule.
global ScriptInformation := Map("MagicKeyDefault", "a")
MagicKeyShown(Char) => Char

Gui_Create(Options, Title) {
	global _MESC
	Window := Gui(Options, Title)
	_MESC.Windows.Push({ window: Window, hwnd: Window.Hwnd })
	_MESC.Window := Window
	return Window
}

WMPresentWindow(Window) {
	Window.Show()
}

LoggerError(*) {
	global _MESC
	_MESC.Errors += 1
}

LoggerWarn(Tag, Message, Reason) {
	global _MESC
	_MESC_Require(Reason == "incomplete-scalar" || Reason == "unexpected-end-reason",
		"Only the malformed scalar reason may reach the warning observer.")
	_MESC.Warnings += 1
}

_MESC_RawUnit(Unit) {
	Bytes := Buffer(4, 0)
	NumPut("UShort", Unit, Bytes)
	return StrGet(Bytes, 1, "UTF-16")
}

ModifyMagicKey(Window, Value) {
	_MESC_Record("character", Value)
}

_MESC_Record(Editor, Value) {
	global _MESC
	_MESC_Require(Editor == _MESC.Editor, "The actual editor must call its own persistence route.")
	_MESC.Calls += 1
	_MESC.Value := Value
}

class _MESC_Hook {
	__New(Mode) {
		global _MESC
		this.Mode := Mode
		this.Window := _MESC.Window
		this.Input := "", this.EndKey := "", this.EndReason := "", this.InProgress := false
		this.Starts := 0, this.Stops := 0
		this.TerminalStop := 1
	}
	Start() {
		this.Starts += 1
		this.InProgress := true
	}
	Stop() {
		this.Stops += 1
		if this.Stops == this.TerminalStop {
			if this.Mode == "stop-refusal" || this.Mode == "successor"
				throw Error("injected native terminal Stop refusal")
			if this.Mode == "stop-reentrant" {
				_MESC_NativeClose(this.Window, this)
				_MESC_OpenSuccessor()
			}
		}
		if this.InProgress {
			this.InProgress := false
			this.EndReason := "Stopped"
		}
	}
	Wait() {
		global _MESC
		this.InProgress := false
		this.EndReason := "EndKey"
		this.EndKey := this.Mode == "cancel" || this.Mode == "successor" ? "Escape" : "a"
		if this.Mode == "scalar-pair"
			this.Input := _MESC_RawUnit(0xD83D), this.EndKey := _MESC_RawUnit(0xDE00)
		else if this.Mode == "invalid-high-BMP"
			this.Input := _MESC_RawUnit(0xD83D)
		else if this.Mode == "invalid-low"
			this.EndKey := _MESC_RawUnit(0xDE00)
		else if this.Mode == "invalid-max"
			this.Input := _MESC_RawUnit(0xD83D) . _MESC_RawUnit(0xD83D), this.EndKey := "", this.EndReason := "Max"
		if this.Mode != "completed-close" && this.Mode != "completed-paused-resumed" && this.Mode != "completed-close-successor"
			return
		_MESC.Timer := _MESC_Interrupt.Bind(this)
		SetTimer(_MESC.Timer, -1)
		Started := A_TickCount
		while _MESC.Interrupts == 0 && A_TickCount - Started < 3000
			Sleep(10)
		_MESC_Require(_MESC.Interrupts == 1, "A real timer must retire the completed editor before its older Wait unwinds.")
		if IsObject(_MESC.Failure)
			throw _MESC.Failure
	}
}

_MESC_CreateHook(Options, EndKeys := "") {
	global _MESC
	_MESC_Require(Options == "L2 E C I" && EndKeys == _SIHO_ScalarEndKeys() . "{Escape}", "Only the real character constructor boundary is bound.")
	Mode := _MESC.Hooks.Length == 0 ? _MESC.Mode : "successor"
	Hook := _MESC_Hook(Mode)
	_MESC.Hooks.Push(Hook)
	return Hook
}

_MESC_NativeClose(Window, Hook) {
	global _MagicKeyEditorInputHook, _MESC
	_MESC_Require(_MagicKeyEditorInputHook == Hook, "Only the exact currently owned editor may receive Close.")
	Hwnd := Window.Hwnd
	_MESC_Require(DllCall("User32\PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int"),
		"The genuine window must receive native WM_CLOSE.")
	Started := A_TickCount
	while IsObject(_MagicKeyEditorInputHook) && _MagicKeyEditorInputHook == Hook && A_TickCount - Started < 1000
		Sleep(10)
	_MESC_Require(!IsObject(_MagicKeyEditorInputHook) || _MagicKeyEditorInputHook != Hook,
		"The actual native Close event must run the bound Stop owner before unwind.")
	_MESC.CloseAcks += 1
}

_MESC_Interrupt(Hook) {
	global _MESC, _MagicKeyEditorInputHook
	try {
		_MESC_Require(_MagicKeyEditorInputHook == Hook && !Hook.InProgress,
			"The genuine singleton must still own this completed passive capture before cancellation.")
		if _MESC.Mode == "completed-paused-resumed" {
			Suspend(true)
			try _MESC_Require(_MagicKeyEditorStopOwned(Hook), "The actual suspend lifecycle leaf must retire this exact hook.")
			finally Suspend(false)
			_MESC_Require(!IsObject(_MagicKeyEditorInputHook) && !A_IsSuspended,
				"A real pause and completed resume must precede the older Wait's return.")
		} else {
			_MESC_NativeClose(Hook.Window, Hook)
			if _MESC.Mode == "completed-close-successor" {
				; Admit a successor through the real public editor. Its injected Stop
				; debt keeps it owned while the older finally subsequently unwinds.
				_MESC_OpenSuccessor()
			}
		}
	} catch as Err {
		_MESC.Failure := Err
	}
	_MESC.Interrupts += 1
}

_MESC_OpenSuccessor() {
	global _MESC, _MagicKeyEditorInputHook
	_MESC_Open()
	_MESC_Require(_MESC.Hooks.Length == 2 && _MagicKeyEditorInputHook == _MESC.Hooks[2],
		"The real resumed editor must retain its own refused hook.")
}

_MESC_Open() {
	global _MESC
	MagicKeyEditor()
}

_MESC_Exit(Reason, Code) {
	global _MESC, _MagicKeyEditorInputHook
	Failures := []
	if HasMethod(_MESC.Timer, "Call") {
		try SetTimer(_MESC.Timer, 0)
		catch as Err
			Failures.Push(Err)
	}
	if IsObject(_MagicKeyEditorInputHook) {
		try _MESC_Require(_MagicKeyEditorStopOwned(_MagicKeyEditorInputHook), "The child must retire its exact cleanup debt.")
		catch as Err
			Failures.Push(Err)
	}
	for Record in _MESC.Windows {
		try Record.window.Destroy()
		catch as Err {
			; A real Close/finally normally destroyed this window already.
			if DllCall("IsWindow", "Ptr", Record.hwnd, "Int")
				Failures.Push(Err)
		}
	}
	if Failures.Length {
		for Err in Failures
			FileAppend("CLEANUP_FAILED " . Err.Message . "`n", "**")
		return 1
	}
	return 0
}

try {
	; A capture opened while paused completes and persists (paused-magic-capture).
	if _MESC.Mode == "paused-live"
		Suspend(true)
	_MESC_Open()
	if IsObject(_MESC.Failure)
		throw _MESC.Failure
	_MESC_Original := _MESC.Hooks[1]
	_MESC_Expected := _MESC.Mode == "live" || _MESC.Mode == "scalar-pair" || _MESC.Mode == "paused-live" ? 1 : 0
	FileAppend("RECEIPT editor=" . _MESC.Editor . " mode=" . _MESC.Mode . " publish_calls=" . _MESC.Calls
		. " expected=" . _MESC_Expected . " stops=" . _MESC_Original.Stops . " reason=" . _MESC_Original.EndReason . "`n", "*")
	_MESC_Require(_MESC_Original.Starts == 1 && _MESC.Calls == _MESC_Expected,
		"Only an uninterrupted completed editor may reach its real persistence route.")
	if _MESC_Expected
		_MESC_Require(_MESC.Value == (_MESC.Mode == "scalar-pair" ? Chr(0x1F600) : "a"), "A live capture must retain its exact value.")
	if _MESC.Mode == "stop-refusal" || _MESC.Mode == "completed-close-successor" || _MESC.Mode == "stop-reentrant" {
		_MESC_Retained := _MESC.Mode == "stop-refusal" ? _MESC_Original : _MESC.Hooks[2]
		_MESC_Require(_MagicKeyEditorInputHook == _MESC_Retained && _MagicKeyEditorStopDebt && _MESC.Errors == 1,
			"A refused terminal Stop must keep only its exact original or successor owner and debt.")
		_MESC_Require(_MESC_Retained.Stops == _MESC_Retained.TerminalStop, "An older finally must never retry a successor's native Stop.")
		_MESC_Require(_MagicKeyEditorStopOwned(_MESC_Retained), "The actual cleanup retry must retire only this retained owner.")
		_MESC_Require(_MESC_Retained.Stops == _MESC_Retained.TerminalStop + 1 && !_MagicKeyEditorStopDebt,
			"One successful retry must settle the exact native cleanup debt.")
	} else {
		_MESC_Require(!IsObject(_MagicKeyEditorInputHook) && !_MagicKeyEditorStopDebt && _MESC.Errors == 0,
			"No orphan singleton or hidden Stop error may survive this editor.")
	}
	_MESC_Require(_MESC.Warnings == (InStr(_MESC.Mode, "invalid-") == 1 ? 1 : 0), "Malformed text is refused visibly without persisting partial units.")
	if InStr(_MESC.Mode, "completed-close") == 1 || _MESC.Mode == "stop-reentrant"
		_MESC_Require(_MESC.CloseAcks == 1, "The refusal must cross exactly one actual native Close event.")
	FileAppend("PASS magic-key-capture-settlement " . _MESC.Editor . " " . _MESC.Mode . "`n", "*")
	ExitApp(0)
} catch as _MESC_Primary {
	FileAppend("FAIL " . _MESC_Primary.Message . "`n" . _MESC_Primary.Stack . "`n", "**")
	ExitApp(1)
}
