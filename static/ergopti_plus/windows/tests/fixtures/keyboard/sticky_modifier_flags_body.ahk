; tests/fixtures/keyboard/sticky_modifier_flags_body.ahk

; Both original and replay are native injection into this child's owned Edit.
; Original injection uses User32, not SendEvent's persistent modifier ownership.
; This is injected input, not a physical-key witness.
if A_Args.Length != 2 || A_Args[1] != "--allow-explicit-owned-edit-native-modifiers"
	throw Error("Explicit native modifier injection opt-in is required.")
if A_PtrSize != 8 || !(A_Args[2] == "plain" || A_Args[2] == "shift")
	throw Error("The exact 64-bit INPUT40 probe and known case are required.")
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 2, TEXT_SENDER_SEND_LEVEL := 0
; A valid production policy keeps shortcut words open. Its actual complete-scalar
; predicate and policy reader run below; no transaction/commit function is stubbed.
global HSE_ArrowResetsWord := false, HSE_ShortcutResetsWord := false, HSE_TapHoldResetsWord := false
global HSE_Buffer := "seed", _PrefixBuffer := "seed"
global _TH_OwnedModifiers := Map(), LayerEnabled := false, _TapHoldTapInDispatch := ""
global _SSM := {Mode: A_Args[2], Window: 0, Edit: 0, Hook: 0, Received: [], Payloads: [], Errors: [],
	Injected: 0, NativeShiftReleased: false, Failure: 0, TransactionCritical: false, Finishes: []}
global _AHK_SendInput := _SSM_Replay

_SSM_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerError(Args*) {
	global _SSM
	_SSM.Errors.Push(Args)
}
LoggerWarn(Args*) {
	global _SSM
	_SSM.Errors.Push(Args)
}
LoggerDebug(Tag, Message, Args*) {
	global _SSM
	if Tag == "HotstringBuffers"
		_SSM.Finishes.Push(A_IsCritical)
}
_SSM_Target() {
	global _SSM
	_SSM_Require(DllCall("GetForegroundWindow", "Ptr") == _SSM.Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == _SSM.Edit.Hwnd
		&& WinGetPID("ahk_id " . _SSM.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Every native send must target the child-owned foreground Edit.")
}
_SSM_Receiver(WParam, LParam, Message, Hwnd) {
	global _SSM
	if Hwnd != _SSM.Edit.Hwnd || WParam != 0x75
		return
	; Win32 GetKeyState here reflects the receiver's dequeued key message,
	; rather than the final asynchronous state after the whole input batch.
	_SSM.Received.Push({Ctrl: !!(DllCall("GetKeyState", "Int", 0x11, "Short") & 0x8000),
		Shift: !!(DllCall("GetKeyState", "Int", 0x10, "Short") & 0x8000)})
	return 0
}
_SSM_Replay(Keys) {
	global _SSM
	_SSM_Target()
	_SSM.Payloads.Push(Keys)
	_SSM.TransactionCritical := !!A_IsCritical
	_SSM_Require(_SSM.TransactionCritical, "Native replay must be admitted inside the actual HS transaction.")
	SendInput(Keys)
}
_SSM_Packets(Rows) {
	Packets := Buffer(Rows.Length * 40, 0)
	for Index, Row in Rows {
		Offset := (Index - 1) * 40
		NumPut("UInt", 1, Packets, Offset)
		NumPut("UShort", Row[1], "UShort", Row[2], "UInt", Row[3], Packets, Offset + 8)
		NumPut("UPtr", 0x53534D01, Packets, Offset + 24)
	}
	return Packets
}
_SSM_Inject() {
	global _SSM
	try {
		_SSM_Target()
		for Token, Record in _SIHO_Owners
			if Record["owner"] == "sticky-modifier"
				_SSM.Hook := Record["hook"]
		_SSM_Require(_SSM.Hook is InputHook && _SSM.Hook.InProgress,
			"Original injection must reach the actual admitted sticky InputHook.")
		Rows := _SSM.Mode == "shift" ? [[0xA0, 0x2A, 0], [0x75, 0x40, 0], [0x75, 0x40, 2], [0xA0, 0x2A, 2]]
			: [[0x75, 0x40, 0], [0x75, 0x40, 2]]
		Packets := _SSM_Packets(Rows)
		_SSM.Injected := DllCall("SendInput", "UInt", Rows.Length, "Ptr", Packets, "Int", 40, "UInt")
		_SSM_Require(_SSM.Injected == Rows.Length, "The complete exact native INPUT40 vector must be admitted.")
		_SSM.NativeShiftReleased := !(DllCall("GetAsyncKeyState", "Int", 0x10, "Short") & 0x8000)
	} catch as Err {
		_SSM.Failure := Err
		SIHO_StopAll()
	}
}
_SSM_Main() {
	global _SSM
	_SSM.Window := Gui(, "Ergopti native sticky flag probe")
	_SSM.Edit := _SSM.Window.AddEdit("w320 r3")
	try {
		_SSM.Window.Show()
		WinActivate("ahk_id " . _SSM.Window.Hwnd)
		_SSM_Require(WinWaitActive("ahk_id " . _SSM.Window.Hwnd, , 2), "The native target must acquire focus.")
		_SSM.Edit.Focus()
		_SSM_Target()
		for Modifier in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
			_SSM_Require(!GetKeyState(Modifier, "P") && !GetKeyState(Modifier), "Native probe requires released modifiers.")
		OnMessage(0x100, _SSM_Receiver)
		SetTimer(_SSM_Inject, -1)
		Accepted := StickyModifier("sticky_ctrl")
		if IsObject(_SSM.Failure)
			throw _SSM.Failure
		Started := A_TickCount
		while _SSM.Received.Length == 0 && A_TickCount - Started < 1500
			Sleep(5)
		CapturedMods := IsObject(_SSM.Hook) ? _SSM.Hook.EndMods : ""
		FileAppend("OBSERVATION sticky-flags mode=" . _SSM.Mode . " inserted=" . _SSM.Injected
			. " captured_mods=" . CapturedMods . " shift_released=" . _SSM.NativeShiftReleased
			. " received=" . _SSM.Received.Length . " payload=" . (_SSM.Payloads.Length ? _SSM.Payloads[1] : "") . "`n", "*")
		_SSM_Require(Accepted && _SSM.Errors.Length == 0 && _SSM.Payloads.Length == 1,
			"The actual sticky capture and actual TextPressKey must emit one native replay without errors.")
		_SSM_Require(_SSM.TransactionCritical && _SSM.Finishes.Length == 1 && !_SSM.Finishes[1]
			&& HSE_Buffer == "seed" && _PrefixBuffer == "seed",
			"The actual keep-word commit, Critical native send and post-commit finish must compose unchanged.")
		FileAppend("OBSERVATION transaction_critical=" . _SSM.TransactionCritical . " finish_critical=" . _SSM.Finishes[1]
			. " engine_unchanged=" . (HSE_Buffer == "seed") . " preview_unchanged=" . (_PrefixBuffer == "seed") . "`n", "*")
		_SSM_Require(_SSM.Hook.EndReason == "EndKey" && _SSM.Hook.EndKey == "F6" && SIHO_Count() == 0,
			"The actual scalar-independent key capture must settle exactly.")
		_SSM_Require(_SSM.NativeShiftReleased, "The original native Shift must already be released before replay.")
		_SSM_Require(!!InStr(CapturedMods, "+") == (_SSM.Mode == "shift"),
			"The actual InputHook EndMods must independently witness the original Shift flag.")
		_SSM_Require(_SSM.Received.Length == 1, "The original F6 must be suppressed and only its sticky replay received.")
		Event := _SSM.Received[1]
		FileAppend("OBSERVATION receiver ctrl=" . Event.Ctrl . " shift=" . Event.Shift . "`n", "*")
		_SSM_Require(Event.Ctrl, "The receiver must observe the requested sticky Ctrl.")
		_SSM_Require(Event.Shift == (_SSM.Mode == "shift"), "The replay must preserve the modifiers captured with the original key.")
	} finally {
		SetTimer(_SSM_Inject, 0)
		try SIHO_StopAll()
		finally {
			; Balance a possibly partial original native modifier batch before exit.
			if _SSM.Mode == "shift" {
				Packets := _SSM_Packets([[0xA0, 0x2A, 2]])
				DllCall("SendInput", "UInt", 1, "Ptr", Packets, "Int", 40, "UInt")
			}
			OnMessage(0x100, _SSM_Receiver, 0)
			_SSM.Window.Destroy()
		}
	}
}
try {
	_SSM_Main()
	FileAppend("PASS sticky-native-flags " . _SSM.Mode, "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
