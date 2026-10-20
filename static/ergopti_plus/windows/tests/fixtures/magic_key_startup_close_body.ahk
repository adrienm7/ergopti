; tests/fixtures/magic_key_startup_close_body.ahk

; Only the native hook factory/physical-state ports are passive. The private Gui
; subclass calls genuine Show before sending native WM_CLOSE to its visible HWND.
; This is a deterministic lifecycle boundary, not a claim about human timing.
if A_Args.Length != 7 || !Map("character", true, "source", true).Has(A_Args[1])
	ExitApp(2)
if !Map("constructor-close", true, "show-close", true).Has(A_Args[2])
	ExitApp(2)
; The real driver is persistent. Default Hide must not end this isolated child
; before it can observe the older constructor resuming.
Persistent(true)
global _MagicKeyEditorInputHook := "", _MagicKeyEditorStopDebt := false, _MagicKeyEditorGui := ""
global HOTKEY_MODIFIER_VKS := Map()
global _MSUC := { Editor: A_Args[1], Mode: A_Args[2], Code: A_Args[3], Scan: A_Args[4],
	Scans: StrSplit(A_Args[5], ","), Poll: Integer(A_Args[6]), Timeout: Integer(A_Args[7]),
	Window: 0, Hwnd: 0, Hook: 0, State: 0, Shows: 0, CloseSent: 0, CloseVisible: 0,
	FactoryVisible: false, HiddenActive: false, WaitVisible: false, Calls: 0, Value: "", Errors: 0 }
OnExit(_MSUC_Exit)

_MSUC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

t(Key) {
	return Key
}

class _MSUC_Gui extends Gui {
	Show(Options := "") {
		global _MSUC
		super.Show(Options)
		_MSUC.Shows += 1
		if _MSUC.Mode == "show-close"
			_MSUC_CloseVisible(this)
	}
}

Gui_Create(Options, Title) {
	global _MSUC
	_MSUC.Window := _MSUC_Gui(Options, Title)
	_MSUC.Hwnd := _MSUC.Window.Hwnd
	return _MSUC.Window
}

_MSUC_CloseVisible(Window) {
	global _MSUC
	_MSUC_Require(Window.Hwnd == _MSUC.Hwnd && DllCall("User32\IsWindowVisible", "Ptr", _MSUC.Hwnd, "Int"),
		"A user-close boundary must target only this actual VISIBLE editor.")
	_MSUC.CloseVisible += 1
	_MSUC.CloseSent += 1
	DllCall("User32\SendMessageW", "Ptr", _MSUC.Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
}

WMPresentWindow(Window) {
	Window.Show()
}

LoggerError(*) {
	global _MSUC
	_MSUC.Errors += 1
}

LoggerWarn(*) {
	throw Error("The startup lifecycle corpus must not qualify malformed scalar text.")
}

ModifyMagicKey(Window, Value) {
	_MSUC_Record("character", Value)
}

ModifyMagicKeySource(Value) {
	_MSUC_Record("source", Value)
}

_MSUC_Record(Editor, Value) {
	global _MSUC
	_MSUC_Require(Editor == _MSUC.Editor, "The genuine editor must use its own persistence route.")
	_MSUC.Calls += 1
	_MSUC.Value := Value
}

TimingsGet(Section, Key) {
	global _MSUC
	_MSUC_Require(Section == "ui", "Only editor UI timings are bound.")
	if Key == "magic_key_capture_poll_ms"
		return _MSUC.Poll
	_MSUC_Require(Key == "magic_key_capture_timeout_ms", "No other timer is substituted.")
	return _MSUC.Timeout
}

TimingsGetSec(Section, Key) {
	return TimingsGet(Section, Key) / 1000.0
}

LayoutRegistry_Keycodes() {
	return "fixture-selected-lookup"
}

LayoutRegistry_KeyCode(Scan, Keycodes) {
	global _MSUC
	_MSUC_Require(Scan == _MSUC.Scan && Keycodes == "fixture-selected-lookup", "The physical answer must retain its admitted scan.")
	return _MSUC.Code
}

_MSUC_CreateSourceState() {
	global _MSUC
	_MSUC.State := { Scans: _MSUC.Scans.Clone(), IsDown: _MSUC_IsDown, Held: Map(), Scan: "", Refused: false }
	return _MSUC.State
}

_MSUC_IsDown(Scan) {
	global _MSUC
	return _MSUC.Mode == "constructor-close" && _MSUC.CloseSent == 0 && Scan == _MSUC.Scan
}

_MSUC_CreateHook(Options, EndKeys := "") {
	global _MSUC
	_MSUC_Require(!IsObject(_MSUC.Hook), "The genuine entry point must construct exactly one hook.")
	if _MSUC.Editor == "character"
		_MSUC_Require(Options == "L2 E C I" && EndKeys == _SIHO_ScalarEndKeys() . "{Escape}", "The character constructor must remain genuine.")
	else
		_MSUC_Require(Options == "L0 I T" . (_MSUC.Timeout / 1000.0) && EndKeys == "", "The source constructor must remain genuine.")
	_MSUC.FactoryVisible := DllCall("User32\IsWindowVisible", "Ptr", _MSUC.Hwnd, "Int") != 0
	if _MSUC.Mode == "constructor-close" && _MSUC.FactoryVisible {
		_MSUC_CloseVisible(_MSUC.Window)
		_MSUC_Require(DllCall("User32\IsWindow", "Ptr", _MSUC.Hwnd, "Int")
			&& !DllCall("User32\IsWindowVisible", "Ptr", _MSUC.Hwnd, "Int"),
			"Before a Close owner exists, native WM_CLOSE must hide the still-valid Gui.")
	}
	_MSUC.Hook := _MSUC_Hook()
	return _MSUC.Hook
}

class _MSUC_Hook {
	__New() {
		this.Input := "", this.EndKey := "", this.EndReason := "", this.InProgress := false
		this.Starts := 0, this.Stops := 0, this.Waits := 0
	}
	KeyOpt(Keys, Options) {
		_MSUC_Require(Keys == "{All}" && Options == "NS", "The physical capture must retain suppression and notification.")
	}
	Start() {
		this.Starts += 1
		this.InProgress := true
	}
	Stop() {
		this.Stops += 1
		if this.InProgress {
			this.InProgress := false
			this.EndReason := "Stopped"
		}
	}
	Wait() {
		global _MSUC
		this.Waits += 1
		; Close may be queued by the real runtime while startup is Critical.
		; Release that queue before judging whether an invisible capture survived.
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		if _MSUC.CloseSent {
			while this.InProgress && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 1000
				Sleep(10)
		}
		Visible := DllCall("User32\IsWindowVisible", "Ptr", _MSUC.Hwnd, "Int") != 0
		_MSUC.WaitVisible := Visible
		_MSUC.HiddenActive := this.InProgress && !Visible
		if this.InProgress {
			if _MSUC.CloseSent
				this.Stop()
			else if _MSUC.Editor == "character" {
				this.EndKey := "a", this.EndReason := "EndKey", this.InProgress := false
			} else
				_MagicKeySourceCapturePoll(_MSUC.State, this)
		}
	}
}

_MSUC_Exit(*) {
	global _MSUC, _MagicKeyEditorInputHook
	Failed := false
	if IsObject(_MagicKeyEditorInputHook) {
		try _MagicKeyEditorStopOwned(_MagicKeyEditorInputHook)
		catch as Err {
			FileAppend("CLEANUP_FAILED " . Err.Message . "`n", "**")
			Failed := true
		}
	}
	if IsObject(_MSUC.Window) {
		try _MSUC.Window.Destroy()
		catch as Err {
			if DllCall("User32\IsWindow", "Ptr", _MSUC.Hwnd, "Int") {
				FileAppend("CLEANUP_FAILED " . Err.Message . "`n", "**")
				Failed := true
			}
		}
	}
	return Failed ? 1 : 0
}

try {
	if _MSUC.Editor == "character"
		MagicKeyEditor()
	else
		MagicKeySourceCapture()
	Hook := _MSUC.Hook
	_MSUC_Require(IsObject(Hook) && Hook.Starts == 1 && Hook.Waits <= 1 && _MSUC.Shows == 1,
		"The genuine entry must construct, start and show exactly once without a repeated wait.")
	FileAppend("RECEIPT editor=" . _MSUC.Editor . " mode=" . _MSUC.Mode . " factory_visible=" . _MSUC.FactoryVisible
		. " hidden_active=" . _MSUC.HiddenActive . " show=" . _MSUC.Shows . " close_visible=" . _MSUC.CloseVisible
		. " starts=" . Hook.Starts . " stops=" . Hook.Stops . " calls=" . _MSUC.Calls . "`n", "*")
	_MSUC_Require(!_MSUC.HiddenActive, "A canceled native dialog must never leave a suppressive capture active while invisible.")
	if _MSUC.Mode == "constructor-close" {
		_MSUC_Require(!_MSUC.FactoryVisible && _MSUC.CloseSent == 0 && Hook.Waits == 1 && _MSUC.WaitVisible,
			"Cold construction must finish hidden, then expose one valid live dialog without closing an invisible Gui.")
		_MSUC_Require(_MSUC.Calls == 1 && _MSUC.Value == (_MSUC.Editor == "character" ? "a" : _MSUC.Code),
			"The uninterrupted constructor control must persist its exact answer once after real Show.")
	} else {
		_MSUC_Require(_MSUC.CloseSent == 1 && _MSUC.CloseVisible == 1 && !Hook.InProgress && _MSUC.Calls == 0,
			"One native Close of the visible editor must cancel without publication.")
		_MSUC_Require(Hook.EndReason == "Stopped", "The genuine Close owner must stop its exact passive hook.")
	}
	_MSUC_Require(!IsObject(_MagicKeyEditorInputHook) && !_MagicKeyEditorStopDebt && _MSUC.Errors == 0,
		"No singleton, stop debt or hidden logger error may survive startup retirement.")
	_MSUC_Require(!DllCall("User32\IsWindow", "Ptr", _MSUC.Hwnd, "Int"), "The genuine editor finally must destroy its exact Gui.")
	FileAppend("PASS magic-key-editor-startup-close " . _MSUC.Editor . " " . _MSUC.Mode . "`n", "*")
	ExitApp(0)
} catch as Err {
	FileAppend("FAIL " . Err.Message . "`n" . Err.Stack . "`n", "**")
	ExitApp(1)
}
