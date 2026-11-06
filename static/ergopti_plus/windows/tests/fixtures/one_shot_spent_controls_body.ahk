; tests/fixtures/one_shot_spent_controls_body.ahk

; Real OneShotShift/SIHO and SendNewResult. Both the original native input and
; the production SendEvent replay are guarded to this child-owned dialog.
if A_Args.Length != 3 || A_Args[1] != "--allow-explicit-owned-one-shot-controls"
	throw Error("Explicit owned native one-shot control opt-in is required.")
if !(A_Args[2] == "enter" || A_Args[2] == "tab" || A_Args[2] == "escape" || A_Args[2] == "left" || A_Args[2] == "escape-native")
	throw Error("Unknown spent-control case.")
global _SharedDir := A_Args[3], _TapHoldOneShotCache := 0, _TH_SyntheticEpoch := 0
global ScriptInformation := Map("MagicKey", Chr(0x2605)), OneShotShiftEnabled := false
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 2, _SendHook := 0, TEXT_SENDER_SEND_LEVEL := 0
global _EMIT_SUPPRESSING_HOOKS := [], _AHK_SendInput := SendInput
global _OSPC := {Mode: A_Args[2], Window: 0, A: 0, B: 0, Hook: 0, ReadyAt: 0, Attempts: 0,
	ControlSent: 0, FollowingSent: 0, PendingAfterControl: -1, NativeKeys: [], FocusSteps: [], Escapes: 0,
	Subclass: 0, Outputs: [], Rings: [], Logs: [], Failure: 0, Armed: false}
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
	if Message == 0x100
		_OSPC.NativeKeys.Push(WParam)
	return
}
; WM_SETFOCUS is sent directly to the child control, not dequeued through
; the script's OnMessage observer. Observe the real control procedure instead.
_OSPC_ControlProc(Hwnd, Message, WParam, LParam, Id, Data) {
	global _OSPC
	try {
		if Message == 7 && _OSPC.Armed
			_OSPC.FocusSteps.Push(Hwnd)
	} catch as Failure {
		_OSPC.Failure := Failure
	}
	return DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message,
		"Ptr", WParam, "Ptr", LParam, "Ptr")
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
		if _OSPC.Mode == "escape-native" {
			_OSPC.Armed := true
			SendLevel(0)
			SendEvent("{Escape}")
			_OSPC.ControlSent += 1
			SetTimer(_OSPC_Following, -75)
			return
		}
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
		SendEvent(Map("enter", "{Enter}", "tab", "{Tab}", "escape", "{Escape}", "left", "{Left}")[_OSPC.Mode])
		_OSPC.ControlSent += 1
		SetTimer(_OSPC_Following, -75)
	} catch as Err {
		_OSPC.Failure := Err
		SIHO_StopAll()
	}
}
_OSPC_Main() {
	global _OSPC
	_OSPC.Window := Gui(, "Ergopti one-shot spent controls")
	_OSPC.A := _OSPC.Window.AddEdit("w320 r3 WantReturn -WantTab", _OSPC.Mode == "left" ? "xy" : "")
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
		_OSPC.Subclass := CallbackCreate(_OSPC_ControlProc, , 6)
		for Control in [_OSPC.A, _OSPC.B]
			_OSPC_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", Control.Hwnd,
				"Ptr", _OSPC.Subclass, "UPtr", 0x45525043, "UPtr", 0, "Int") != 0,
				"The two owned controls must accept their passive native focus observers.")
		_OSPC.ReadyAt := A_TickCount
		SetTimer(_OSPC_Control, -1)
		if _OSPC.Mode != "escape-native"
			OneShotShift()
		Started := A_TickCount
		while !_OSPC.FollowingSent && !IsObject(_OSPC.Failure) && A_TickCount - Started < 1500
			Sleep(5)
		Sleep(50)
		if IsObject(_OSPC.Failure)
			throw _OSPC.Failure
		Focus := _OSPC_Target()
		A := StrReplace(_OSPC.A.Value, "`r", ""), B := StrReplace(_OSPC.B.Value, "`r", "")
		EndKey := IsObject(_OSPC.Hook) ? _OSPC.Hook.EndKey : ""
		NativeCodes := ""
		for Vk in _OSPC.NativeKeys
			NativeCodes .= (NativeCodes == "" ? "" : ",") . Vk
		Output := _OSPC.Outputs.Length ? _OSPC.Outputs[1] : ""
		FileAppend("OBSERVATION one-shot-controls mode=" . _OSPC.Mode . " pending_after_control=" . _OSPC.PendingAfterControl
			. " control_sent=" . _OSPC.ControlSent . " following_sent=" . _OSPC.FollowingSent
			. " end_reason=" . (IsObject(_OSPC.Hook) ? _OSPC.Hook.EndReason : "none")
			. " end_key_units=" . StrLen(EndKey) . " end_key_first_unit=" . (EndKey != "" ? NumGet(StrPtr(EndKey), 0, "UShort") : 0)
			. " native_keydowns=" . _OSPC.NativeKeys.Length . " native_vks=" . NativeCodes
			. " outputs=" . _OSPC.Outputs.Length . " output_units=" . StrLen(Output)
			. " output_last_unit=" . (Output != "" ? NumGet(StrPtr(Output), (StrLen(Output) - 1) * 2, "UShort") : 0)
			. " focus_steps=" . _OSPC.FocusSteps.Length . " escapes=" . _OSPC.Escapes
			. " a_units=" . StrLen(A) . " b_units=" . StrLen(B)
			. " following_lower=" . (SubStr(A . B, -1) == "a") . " logs=" . _OSPC.Logs.Length . "`n", "*")
		_OSPC_Require(_OSPC.ControlSent == 1 && _OSPC.FollowingSent == 1, "The two separate native presses must each be admitted once.")
		_OSPC_Require(_OSPC.PendingAfterControl == (_OSPC.Mode == "left" ? 1 : 0),
			"Spent controls must retire the capture; native navigation must leave it armed for the following letter.")
		if _OSPC.Mode == "left"
			_OSPC_Require(A == "xAy" && B == "" && _OSPC.FocusSteps.Length == 0 && _OSPC.Escapes == 0,
				"A non-ending Left must reach the native caret once while the one-shot still capitalizes the following letter.")
		else if _OSPC.Mode == "tab"
			_OSPC_Require(A == "" && B == "a" && Focus == _OSPC.B.Hwnd && _OSPC.FocusSteps.Length == 1,
				"An unshifted Tab must move focus once and leave the following letter lowercase.")
		else if _OSPC.Mode == "escape" || _OSPC.Mode == "escape-native"
			_OSPC_Require(A == "a" && B == "" && _OSPC.Escapes == 1,
				"Escape must reach the owned GUI once and leave the following letter lowercase.")
		else
			_OSPC_Require(A == "`na" && B == "" && _OSPC.Escapes == 0,
				"The Enter control must produce one newline and leave the following letter lowercase.")
		_OSPC_Require(SIHO_Count() == 0, "The genuine scalar capture must retire after the two-key sequence.")
	} finally {
		SetTimer(_OSPC_Control, 0)
		SetTimer(_OSPC_Following, 0)
		SIHO_StopAll()
		OnMessage(0x100, _OSPC_Message, 0)
		_OSPC.Armed := false
		OwnedAHwnd := _OSPC.A.Hwnd, OwnedBHwnd := _OSPC.B.Hwnd
		_OSPC.Window.Destroy()
		; Destroy returns after both native control procedures have retired.
		; Never free a callback still installed on a live owned HWND.
		if _OSPC.Subclass {
			_OSPC_Require(!DllCall("User32\IsWindow", "Ptr", OwnedAHwnd, "Int")
				&& !DllCall("User32\IsWindow", "Ptr", OwnedBHwnd, "Int"),
				"The actual subclass owners must retire before freeing their callback.")
			CallbackFree(_OSPC.Subclass)
			_OSPC.Subclass := 0
		}
	}
}
try {
	_OSPC_Main()
	FileAppend("PASS one-shot-spent-control " . _OSPC.Mode, "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
