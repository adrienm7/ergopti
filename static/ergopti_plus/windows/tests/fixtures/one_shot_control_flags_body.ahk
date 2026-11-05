; tests/fixtures/one_shot_control_flags_body.ahk

; Real OneShotShift/SIHO and SendNewResult. Native Backspace (plain or Ctrl)
; is captured, then its real replay reaches only this private owned Edit.
; The oracle reads Win32 queue modifier flags at the receiver's actual keydown,
; never just the generated payload. No physical keyboard claim is made.
if A_Args.Length != 3 || A_Args[1] != "--allow-explicit-owned-one-shot-control-flags"
	throw Error("Explicit owned native one-shot control opt-in is required.")
if !(A_Args[2] == "plain" || A_Args[2] == "ctrl")
	throw Error("Unknown spent-control case.")
global _SharedDir := A_Args[3], _TapHoldOneShotCache := 0, _TH_SyntheticEpoch := 0
global ScriptInformation := Map("MagicKey", Chr(0x2605)), OneShotShiftEnabled := false
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 2, _SendHook := 0, TEXT_SENDER_SEND_LEVEL := 0
global _EMIT_SUPPRESSING_HOOKS := [], _AHK_SendInput := SendInput
global _OSPC := {Mode: A_Args[2], Window: 0, A: 0, B: 0, Hook: 0, ReadyAt: 0, Attempts: 0,
	ControlSent: 0, FollowingSent: 0, PendingAfterControl: -1, NativeKeys: [], FocusSteps: [], Escapes: 0,
	Backspaces: [], CtrlAttempted: false, Outputs: [], Rings: [], Logs: [], Failure: 0, Armed: false}
_OSPC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerError(Args*) {
	global _OSPC
	_OSPC.Logs.Push(Args)
}
LoggerWarn(Args*) {
	global _OSPC
	_OSPC.Logs.Push(Args)
}
ActivateHotstrings(*) => 0
UpdateLastSentCharacter(Text) {
	global _OSPC
	_OSPC.Rings.Push(Text)
}
_OSPC_Target() {
	global _OSPC
	Focus := DllCall("GetFocus", "Ptr")
	_OSPC_Require(DllCall("GetForegroundWindow", "Ptr") == _OSPC.Window.Hwnd
		&& (Focus == _OSPC.A.Hwnd || Focus == _OSPC.B.Hwnd)
		&& WinGetPID("ahk_id " . _OSPC.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Every original input and native replay must remain confined to the two child-owned Edits.")
	return Focus
}
_OSPC_NativeReplay(Keys) {
	global _OSPC
	_OSPC_Target()
	_OSPC_Require(SIHO_Count() == 0, "The actual output must follow settlement of the genuine one-shot capture.")
	_OSPC.Outputs.Push(Keys)
	return SendEvent(Keys)
}
_OSPC_Message(WParam, LParam, Message, Hwnd) {
	global _OSPC
	if Hwnd != _OSPC.A.Hwnd && Hwnd != _OSPC.B.Hwnd
		return
	if Message == 7 && _OSPC.Armed
		_OSPC.FocusSteps.Push(Hwnd)
	if Message == 0x100 {
		_OSPC.NativeKeys.Push(WParam)
		if WParam == 8
			_OSPC.Backspaces.Push({Ctrl: !!(DllCall("User32\GetKeyState", "Int", 0x11, "Short") & 0x8000),
				Shift: !!(DllCall("User32\GetKeyState", "Int", 0x10, "Short") & 0x8000)})
	}
	return
}
_OSPC_Escape(*) {
	global _OSPC
	_OSPC.Escapes += 1
	return true
}
_OSPC_Following() {
	global _OSPC
	try {
		_OSPC_Target()
		_OSPC.PendingAfterControl := SIHO_Count()
		SendLevel(0)
		SendEvent("a")
		_OSPC.FollowingSent += 1
	} catch as Err {
		_OSPC.Failure := Err
		SIHO_StopAll()
	}
}
_OSPC_Control() {
	global _OSPC
	try {
		_OSPC_Target()
		for Token, Record in _SIHO_Owners
			if Record["owner"] == "one-shot-shift" && Record["hook"].InProgress
				_OSPC.Hook := Record["hook"]
		if !IsObject(_OSPC.Hook) && A_TickCount - _OSPC.ReadyAt < 1500 {
			_OSPC.Attempts += 1
			SetTimer(_OSPC_Control, -5)
			return
		}
		_OSPC_Require(IsObject(_OSPC.Hook) && _OSPC.Hook.InProgress,
			"The first native control must reach the exact admitted one-shot hook within its bounded readiness window.")
		_OSPC.Armed := true
		SendLevel(0)
		if _OSPC.Mode == "ctrl" {
			_OSPC.CtrlAttempted := true
			SendEvent("{LCtrl down}")
		}
		try SendEvent("{Backspace}")
		finally {
			if _OSPC.CtrlAttempted {
				SendEvent("{LCtrl up}")
				_OSPC.CtrlAttempted := false
			}
		}
		_OSPC.ControlSent += 1
	} catch as Err {
		_OSPC.Failure := Err
		SIHO_StopAll()
	}
}
_OSPC_Main() {
	global _OSPC
	_OSPC.Window := Gui(, "Ergopti one-shot spent controls")
	_OSPC.A := _OSPC.Window.AddEdit("w320 r3 WantReturn -WantTab", "alpha bravo")
	_OSPC.B := _OSPC.Window.AddEdit("w320 r3 WantReturn -WantTab")
	_OSPC.Window.OnEvent("Escape", _OSPC_Escape)
	try {
		_OSPC.Window.Show()
		WinActivate("ahk_id " . _OSPC.Window.Hwnd)
		_OSPC_Require(WinWaitActive("ahk_id " . _OSPC.Window.Hwnd, , 2), "The owned receiver window must become active before original control injection.")
		_OSPC.A.Focus()
		DllCall("SendMessageW", "Ptr", _OSPC.A.Hwnd, "UInt", 0xB1, "Ptr", -1, "Ptr", -1)
		_OSPC_Target()
		for Key in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
			_OSPC_Require(!GetKeyState(Key, "P") && !GetKeyState(Key), "Release modifiers before native original control input.")
		_OSPC_Require(!GetKeyState("CapsLock", "T"), "The unshifted following-letter witness requires CapsLock off.")
		_SIHO_ScalarEndKeys()
		_TapHoldOneShotTable()
		OnMessage(0x100, _OSPC_Message)
		OnMessage(7, _OSPC_Message)
		_OSPC.ReadyAt := A_TickCount
		SetTimer(_OSPC_Control, -1)
		OneShotShift()
		Started := A_TickCount
		while (!_OSPC.Backspaces.Length || !_OSPC.ControlSent) && !IsObject(_OSPC.Failure) && A_TickCount - Started < 1500
			Sleep(5)
		if IsObject(_OSPC.Failure)
			throw _OSPC.Failure
		Captured := IsObject(_OSPC.Hook) ? _OSPC.Hook.EndMods : ""
		FileAppend("OBSERVATION one-shot-control-flags mode=" . _OSPC.Mode . " captured_mods=" . Captured
			. " control_sent=" . _OSPC.ControlSent . " outputs=" . _OSPC.Outputs.Length
			. " receiver_backspaces=" . _OSPC.Backspaces.Length
			. " receiver_ctrl=" . (_OSPC.Backspaces.Length ? _OSPC.Backspaces[1].Ctrl : -1)
			. " receiver_shift=" . (_OSPC.Backspaces.Length ? _OSPC.Backspaces[1].Shift : -1)
			. " ctrl_released=" . !(DllCall("User32\GetAsyncKeyState", "Int", 0x11, "Short") & 0x8000)
			. " capture_owners=" . SIHO_Count() . " logs=" . _OSPC.Logs.Length . "`n", "*")
		_OSPC_Require(_OSPC.ControlSent == 1 && _OSPC.Outputs.Length == 1 && SIHO_Count() == 0,
			"The genuine one-shot must consume and replay its one ending control exactly once.")
		_OSPC_Require(_OSPC.Mode == "ctrl" ? InStr(Captured, "^") > 0 : Captured == "",
			"The true native capture must witness exactly the intended original modifier flags.")
		_OSPC_Require(_OSPC.Backspaces.Length == 1 && !_OSPC.Backspaces[1].Shift
			&& _OSPC.Backspaces[1].Ctrl == (_OSPC.Mode == "ctrl"),
			"A spent-unshifted control must preserve its captured Ctrl flag at the actual receiving native keydown.")
	} finally {
		SetTimer(_OSPC_Control, 0)
		if _OSPC.CtrlAttempted {
			_OSPC_Target()
			SendEvent("{LCtrl up}")
			_OSPC.CtrlAttempted := false
		}
		SetTimer(_OSPC_Following, 0)
		SIHO_StopAll()
		OnMessage(0x100, _OSPC_Message, 0)
		OnMessage(7, _OSPC_Message, 0)
		_OSPC.Window.Destroy()
	}
}
try {
	_OSPC_Main()
	FileAppend("PASS one-shot-control-flags " . _OSPC.Mode, "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
