; tests/fixtures/one_shot_control_flags_body.ahk

; Real OneShotShift/SIHO and SendNewResult. Native Backspace or Tab with captured flags
; is captured, then its real replay reaches only this private owned Edit.
; The oracle reads Win32 queue modifier flags at the receiver's actual keydown,
; never just the generated payload. No physical keyboard claim is made.
if A_Args.Length != 3 || A_Args[1] != "--allow-explicit-owned-one-shot-control-flags"
	throw Error("Explicit owned native one-shot control opt-in is required.")
if !(A_Args[2] == "plain" || A_Args[2] == "ctrl" || A_Args[2] == "shift" || A_Args[2] == "ctrl-shift" || A_Args[2] == "tab" || A_Args[2] == "tab-shift" || A_Args[2] == "kana-plain" || A_Args[2] == "kana-released")
	throw Error("Unknown spent-control case.")
global _SharedDir := A_Args[3], _TapHoldOneShotCache := 0, _TH_SyntheticEpoch := 0
global ScriptInformation := Map("MagicKey", Chr(0x2605)), OneShotShiftEnabled := false
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 2, _SendHook := 0, TEXT_SENDER_SEND_LEVEL := 0
global _EMIT_SUPPRESSING_HOOKS := [], _AHK_SendInput := SendInput
global _OSPC := {Mode: A_Args[2], Window: 0, A: 0, B: 0, Hook: 0, ReadyAt: 0, Attempts: 0,
	ControlSent: 0, FollowingSent: 0, PendingAfterControl: -1, NativeKeys: [], FocusSteps: [], Escapes: 0,
	Backspaces: [], CtrlAttempted: false, ShiftAttempted: false, Outputs: [], Rings: [], Logs: [], Failure: 0, Armed: false,
	KanaObserver: 0, KanaKeys: [], KanaInserted: 0, KanaOemOwed: false, KanaBackOwed: false,
	KanaOriginalOem: 0, KanaAsyncReleased: false, KanaLogicalReleased: false}
; Simulated family only; actual native input ABI is independently observed below.
global _ALTGR_KANA_FIXUP := InStr(_OSPC.Mode, "kana-") == 1, _ALTGR_LAYOUT_PROBE := Map("altgr_vk", 0xDF)
if _ALTGR_KANA_FIXUP && A_PtrSize != 8
	throw Error("The exact native INPUT40 probe requires 64-bit AutoHotkey")
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
	if InStr(_OSPC.Mode, "kana-") == 1 {
		_OSPC.KanaAsyncReleased := !(DllCall("User32\GetAsyncKeyState", "Int", 0xDF, "Short") & 0x8000)
		_OSPC.KanaLogicalReleased := !GetKeyState("vkDF")
	}
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
		if WParam == 0xDF && DllCall("User32\GetMessageExtraInfo", "UPtr") == 0x4F534301
			_OSPC.KanaOriginalOem += 1
		if WParam == (InStr(_OSPC.Mode, "tab") == 1 ? 9 : 8)
			_OSPC.Backspaces.Push({Ctrl: !!(DllCall("User32\GetKeyState", "Int", 0x11, "Short") & 0x8000),
				Shift: !!(DllCall("User32\GetKeyState", "Int", 0x10, "Short") & 0x8000),
				Oem: !!(DllCall("User32\GetKeyState", "Int", 0xDF, "Short") & 0x8000), Extra: DllCall("User32\GetMessageExtraInfo", "UPtr")})
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
		if InStr(_OSPC.Mode, "kana-") == 1 {
			_OSPC_KanaControl()
			return
		}
		SendLevel(0)
		if InStr(_OSPC.Mode, "ctrl") {
			_OSPC.CtrlAttempted := true
			SendEvent("{LCtrl down}")
		}
		if InStr(_OSPC.Mode, "shift") {
			_OSPC.ShiftAttempted := true
			SendEvent("{LShift down}")
		}
		try SendEvent(InStr(_OSPC.Mode, "tab") == 1 ? "{Tab}" : "{Backspace}")
		finally {
			if _OSPC.ShiftAttempted {
				SendEvent("{LShift up}")
				_OSPC.ShiftAttempted := false
			}
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
		if InStr(_OSPC.Mode, "kana-") == 1
			_OSPC_Require(!GetKeyState("vkDF") && !(DllCall("User32\GetAsyncKeyState", "Int", 0xDF, "Short") & 0x8000),
				"The private native original requires a released OEM key before it owns a Down")
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
			. " receiver_vkey=" . (InStr(_OSPC.Mode, "tab") == 1 ? 9 : 8) . " receiver_backspaces=" . _OSPC.Backspaces.Length
			. " receiver_ctrl=" . (_OSPC.Backspaces.Length ? _OSPC.Backspaces[1].Ctrl : -1)
			. " receiver_shift=" . (_OSPC.Backspaces.Length ? _OSPC.Backspaces[1].Shift : -1)
			. " ctrl_released=" . !(DllCall("User32\GetAsyncKeyState", "Int", 0x11, "Short") & 0x8000)
			. " shift_released=" . !(DllCall("User32\GetAsyncKeyState", "Int", 0x10, "Short") & 0x8000)
			. " capture_owners=" . SIHO_Count() . " logs=" . _OSPC.Logs.Length . "`n", "*")
		_OSPC_Require(_OSPC.ControlSent == 1 && _OSPC.Outputs.Length == 1 && SIHO_Count() == 0,
			"The genuine one-shot must consume and replay its one ending control exactly once.")
		if InStr(_OSPC.Mode, "kana-") == 1
			_OSPC_KanaCheck()
		ExpectedCtrl := InStr(_OSPC.Mode, "ctrl") > 0
		ExpectedShift := InStr(_OSPC.Mode, "shift") > 0
		_OSPC_Require((InStr(Captured, "^") > 0) == ExpectedCtrl
			&& (InStr(Captured, "+") > 0) == ExpectedShift && !InStr(Captured, "!") && !InStr(Captured, "#"),
			"The true native capture must witness exactly the intended original modifier flags.")
		_OSPC_Require(_OSPC.Backspaces.Length == 1 && _OSPC.Backspaces[1].Shift == ExpectedShift
			&& _OSPC.Backspaces[1].Ctrl == ExpectedCtrl,
			"A spent-unshifted control must preserve its captured modifier flags at its actual receiving native keydown.")
	} finally {
		SetTimer(_OSPC_Control, 0)
		if _OSPC.ShiftAttempted {
			_OSPC_Target()
			SendEvent("{LShift up}")
			_OSPC.ShiftAttempted := false
		}
		if _OSPC.CtrlAttempted {
			_OSPC_Target()
			SendEvent("{LCtrl up}")
			_OSPC.CtrlAttempted := false
		}
		SetTimer(_OSPC_Following, 0)
		SIHO_StopAll()
		_OSPC_KanaCleanup()
		OnMessage(0x100, _OSPC_Message, 0)
		OnMessage(7, _OSPC_Message, 0)
		_OSPC.Window.Destroy()
	}
}
; Exact original native packets; this is injected input, not physical input.
_OSPC_KanaPackets(Rows) {
	Packets := Buffer(Rows.Length * 40, 0)
	for Index, Row in Rows {
		Offset := (Index - 1) * 40
		NumPut("UInt", 1, Packets, Offset)
		NumPut("UShort", Row[1], "UShort", Row[2], "UInt", Row[3], Packets, Offset + 8)
		NumPut("UPtr", 0x4F534301, Packets, Offset + 24)
	}
	return Packets
}
_OSPC_KanaObserve(Hook, Vk, Sc) {
	global _OSPC
	if Hook == _OSPC.KanaObserver
		_OSPC.KanaKeys.Push({Vk: Vk, Sc: Sc})
}
_OSPC_KanaControl() {
	global _OSPC
	_OSPC_Target()
	_OSPC.KanaObserver := InputHook("V L0 I1")
	_OSPC.KanaObserver.KeyOpt("{All}", "N")
	_OSPC.KanaObserver.OnKeyDown := _OSPC_KanaObserve
	_OSPC.KanaObserver.Start()
	_OSPC_Require(_OSPC.KanaObserver.InProgress, "The independent native ABI observer must be newest before original injection")
	Rows := _OSPC.Mode == "kana-released"
		? [[0xDF, 0x38, 1], [0x08, 0x0E, 0], [0x08, 0x0E, 2], [0xDF, 0x38, 3]]
		: [[0x08, 0x0E, 0], [0x08, 0x0E, 2]]
	Packets := _OSPC_KanaPackets(Rows)
	_OSPC.KanaInserted := DllCall("SendInput", "UInt", Rows.Length, "Ptr", Packets, "Int", 40, "UInt")
	for Index, Row in Rows {
		if Index > _OSPC.KanaInserted
			break
		if Row[1] == 0xDF
			_OSPC.KanaOemOwed := !(Row[3] & 2)
		else if Row[1] == 8
			_OSPC.KanaBackOwed := !(Row[3] & 2)
	}
	_OSPC_Require(_OSPC.KanaInserted == Rows.Length, "Every exact INPUT40 row must be acknowledged before interpreting capture results")
	_OSPC.ControlSent += 1
}
_OSPC_KanaCheck() {
	global _OSPC
	Expected := _OSPC.Mode == "kana-released"
	Count := Expected ? 2 : 1
	Started := A_TickCount
	while _OSPC.KanaKeys.Length < Count && A_TickCount - Started < 1000
		Sleep(5)
	_OSPC.KanaObserver.Stop()
	_OSPC_Require(!_OSPC.KanaObserver.InProgress, "The exact passive ABI observer must retire before sampling its receipt")
	NativeOem := Expected && _OSPC.KanaKeys.Length >= 1
		&& _OSPC.KanaKeys[1].Vk == 0xDF && _OSPC.KanaKeys[1].Sc == 0x138
	NativeBack := _OSPC.KanaKeys.Length == Count
		&& _OSPC.KanaKeys[Count].Vk == 8 && _OSPC.KanaKeys[Count].Sc == 0x0E
	FileAppend("OBSERVATION one-shot-kana mode=" . _OSPC.Mode . " native_oem=" . NativeOem
		. " native_backspace=" . NativeBack . " original_oem=" . _OSPC.KanaOriginalOem
		. " async_released_at_replay=" . _OSPC.KanaAsyncReleased . " logical_released_at_replay=" . _OSPC.KanaLogicalReleased
		. " receiver_oem=" . (_OSPC.Backspaces.Length ? _OSPC.Backspaces[1].Oem : -1)
		. " captured_end=" . _OSPC.Hook.EndKey . " outputs=" . _OSPC.Outputs.Length . "`n", "*")
	_OSPC_Require(NativeBack && (!Expected || NativeOem), "The native original VK/SC pair must be witnessed independently of its constructed packets")
	_OSPC_Require(_OSPC.KanaOriginalOem == Expected && _OSPC.KanaAsyncReleased,
		"The original visible OEM key and its acknowledged release must precede the actual replay")
	_OSPC_Require(_OSPC.Backspaces.Length == 1 && _OSPC.Backspaces[1].Extra != 0x4F534301,
		"Only the real replay, not the suppressed original control, may reach the owned receiver")
	_OSPC_Require(_OSPC.Backspaces[1].Oem == Expected,
		"The spent native control must retain its captured custom modifier after its original release")
}
_OSPC_KanaCleanup() {
	global _OSPC
	if IsObject(_OSPC.KanaObserver) {
		_OSPC.KanaObserver.Stop()
		_OSPC_Require(!_OSPC.KanaObserver.InProgress, "The exact passive observer must retire before the receiver")
	}
	Rows := []
	if _OSPC.KanaBackOwed
		Rows.Push([0x08, 0x0E, 2])
	if _OSPC.KanaOemOwed
		Rows.Push([0xDF, 0x38, 3])
	if Rows.Length {
		_OSPC_Target()
		Packets := _OSPC_KanaPackets(Rows)
		_OSPC_Require(DllCall("SendInput", "UInt", Rows.Length, "Ptr", Packets, "Int", 40, "UInt") == Rows.Length,
			"Every actually admitted original Down retains its exact owed native Up")
		_OSPC.KanaBackOwed := false, _OSPC.KanaOemOwed := false
	}
	if InStr(_OSPC.Mode, "kana-") == 1 {
		Started := A_TickCount
		while (GetKeyState("vkDF") || GetKeyState("Backspace")) && A_TickCount - Started < 1000
			Sleep(5)
		_OSPC_Require(!GetKeyState("vkDF") && !GetKeyState("Backspace"), "Acknowledged original Ups must settle logically before native window destruction")
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
