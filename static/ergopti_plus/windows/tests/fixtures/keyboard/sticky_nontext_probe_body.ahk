; tests/fixtures/keyboard/sticky_nontext_probe_body.ahk

; The real StickyModifier/SIHO owner runs unchanged. Native SendEvent input is
; restricted to this child's verified foreground Edit; output transport is passive.
if A_Args.Length != 2 || A_Args[1] != "--allow-explicit-owned-edit-sendevent"
	throw Error("Explicit owned-Edit keyboard input opt-in is required.")
if !(A_Args[2] == "letter" || A_Args[2] == "enter" || A_Args[2] == "backspace")
	throw Error("Unknown sticky native probe.")
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 2
global _STN := {Mode: A_Args[2], Window: 0, Edit: 0, Sends: [], Keys: [], Logs: [], Delivered: 0, Failure: 0}

_STN_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerError(Args*) {
	global _STN
	_STN.Logs.Push(Args)
}
TextPressKey(Key, Modifiers) {
	global _STN
	_STN.Sends.Push({Key: Key, Modifiers: Modifiers})
	return true
}
_STN_KeyMessage(WParam, LParam, Message, Hwnd) {
	global _STN
	if IsObject(_STN.Edit) && Hwnd == _STN.Edit.Hwnd
		_STN.Keys.Push(WParam)
}
_STN_Target() {
	global _STN
	_STN_Require(DllCall("GetForegroundWindow", "Ptr") == _STN.Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == _STN.Edit.Hwnd
		&& WinGetPID("ahk_id " . _STN.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Keyboard input must remain confined to the child-owned foreground Edit.")
	for Name in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
		_STN_Require(!GetKeyState(Name, "P"), "Release physical modifiers before native delivery.")
}
_STN_Send() {
	global _STN
	PreviousLevel := A_SendLevel
	try {
		_STN_Target()
		SendLevel(0)
		SendEvent(_STN.Mode == "letter" ? "a" : (_STN.Mode == "enter" ? "{Enter}" : "{BackSpace}"))
	} catch as Err {
		_STN.Failure := Err
		SIHO_StopAll()
	} finally {
		SendLevel(PreviousLevel)
		_STN.Delivered += 1
	}
}
_STN_Main() {
	global _STN
	_STN.Window := Gui(, "Ergopti sticky native capture probe")
	_STN.Edit := _STN.Window.AddEdit("w320 r3", _STN.Mode == "backspace" ? "keepX" : "")
	try {
		_STN.Window.Show()
		WinActivate("ahk_id " . _STN.Window.Hwnd)
		_STN_Require(WinWaitActive("ahk_id " . _STN.Window.Hwnd, , 2), "The private target must acquire focus.")
		_STN.Edit.Focus()
		_STN_Target()
		DllCall("SendMessageW", "Ptr", _STN.Edit.Hwnd, "UInt", 0xB1, "Ptr", -1, "Ptr", -1)
		OnMessage(0x100, _STN_KeyMessage)
		SetTimer(_STN_Send, -1)
		Accepted := StickyModifier("sticky_ctrl")
		if IsObject(_STN.Failure)
			throw _STN.Failure
		Sleep(30)
		_STN_Target()
		_STN_Require(_STN.Delivered == 1 && Accepted && _STN.Sends.Length == 1,
			"One native capture must produce exactly one admitted sticky output.")
		ExpectedKey := _STN.Mode == "letter" ? "a" : (_STN.Mode == "enter" ? "Enter" : "BackSpace")
		_STN_Require(_STN.Sends[1].Key = ExpectedKey && _STN.Sends[1].Modifiers.Length == 1
			&& _STN.Sends[1].Modifiers[1] == "Ctrl", "The genuine sticky output must preserve its captured key and modifier.")
		FileAppend("OBSERVATION sticky " . _STN.Mode . " original_keydowns=" . _STN.Keys.Length
			. " edit_length=" . StrLen(_STN.Edit.Value) . " outputs=" . _STN.Sends.Length . "`n", "*")
		_STN_Require(_STN.Keys.Length == 0, "The original unmodified key must be suppressed before its sticky replay.")
		_STN_Require(_STN.Edit.Value == (_STN.Mode == "backspace" ? "keepX" : ""),
			"The captured original key must not modify the owned Edit before sticky output.")
		_STN_Require(SIHO_Count() == 0 && _STN.Logs.Length == 0, "The actual capture must settle without hidden registry errors.")
	} finally {
		SetTimer(_STN_Send, 0)
		try SIHO_StopAll()
		finally {
			OnMessage(0x100, _STN_KeyMessage, 0)
			_STN.Window.Destroy()
		}
	}
}
try {
	_STN_Main()
	FileAppend("PASS sticky-nontext " . _STN.Mode, "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
