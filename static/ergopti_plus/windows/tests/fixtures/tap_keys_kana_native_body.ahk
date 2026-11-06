; tests/fixtures/tap_keys_kana_native_body.ahk

if A_Args.Length != 2 || A_Args[2] != "--allow-owned-native-kana-tap-probe" || A_PtrSize != 8
	throw Error("Explicit owned native INPUT40 probe opt-in is required.")
if !(A_Args[1] == "kana-plain" || A_Args[1] == "kana-held" || A_Args[1] == "standard-held")
	throw Error("A known tap-key admission mode is required.")
global _TKN := {Mode: A_Args[1], Window: 0, Edit: 0, Actions: [], Received: Map(),
	OemOwed: false, SuffixOwed: 0, Completed: false, Sent: 0, Failure: 0, Marker: 0x544B4E41}
global _ALTGR_KANA_FIXUP := _TKN.Mode != "standard-held"
global _TapHoldModifierIsHeld := (Name) => GetKeyState(Name == "SC138" ? "vkDF" : Name)
global TapKeyAssignments := Map("number_row_left", "native_probe", "number_row_right_1", "native_probe", "number_row_right_2", "native_probe")
global TAP_KEY_SCANCODES := Map("number_row_left", 0x29, "number_row_right_1", 0x0C, "number_row_right_2", 0x0D)
global GESTURE_ACTIONS := Map("native_probe", true)
global CategoryEnabled := Map("Shortcuts", true)
LoggerDebug(*) => 0
LLM_Menu_AiEnabled() => false
GestureInvokeAction(ActionName, BindingId := "") {
	global _TKN
	_TKN_Target()
	_TKN_Require(ActionName == "native_probe", "Only the harmless recording action may run.")
	_TKN.Actions.Push(BindingId)
}
_TKN_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_TKN_Target() {
	global _TKN
	_TKN_Require(DllCall("GetForegroundWindow", "Ptr") == _TKN.Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == _TKN.Edit.Hwnd
		&& WinGetPID("ahk_id " . _TKN.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Native injection must stay in the exact child-owned foreground Edit.")
}
_TKN_Packet(Vk, Sc, Flags) {
	global _TKN
	Packet := Buffer(40, 0)
	NumPut("UInt", 1, Packet, 0)
	NumPut("UShort", Vk, "UShort", Sc, "UInt", Flags, Packet, 8)
	NumPut("UPtr", _TKN.Marker, Packet, 24)
	return Packet
}
_TKN_Send(Vk, Sc, Flags) {
	_TKN_Target()
	Packet := _TKN_Packet(Vk, Sc, Flags)
	_TKN_Require(DllCall("SendInput", "UInt", 1, "Ptr", Packet, "Int", 40, "UInt") == 1,
		"The exact native key packet must be accepted.")
}
_TKN_Receive(WParam, LParam, Message, Hwnd) {
	global _TKN
	Sc := (LParam >> 16) & 0xFF
	if Hwnd != _TKN.Edit.Hwnd || !(Sc == 0x29 || Sc == 0x0C || Sc == 0x0D)
		return
	_TKN_Require(DllCall("GetMessageExtraInfo", "UPtr") == _TKN.Marker,
		"Every observed original suffix must have the exact injection marker.")
	_TKN.Received[Sc] := _TKN.Received.Get(Sc, 0) + 1
}
_TKN_AwaitLogicalUp(Name) {
	Started := A_TickCount
	while GetKeyState(Name) && A_TickCount - Started < 1000
		Sleep(5)
	_TKN_Require(!GetKeyState(Name), "The exact acknowledged native Up must settle logically before retirement: " . Name)
}
_TKN_Inject() {
	global _TKN
	try {
		for Sc in [0x29, 0x0C, 0x0D] {
			; The real static handler waits for Up. Admit its native Down/Up
			; pair before allowing that handler to interrupt this injection timer.
			PreviousCritical := Critical("On")
			try {
				_TKN_Send(0, Sc, 8)
				_TKN.SuffixOwed := Sc
				_TKN_Send(0, Sc, 10)
			} finally Critical(PreviousCritical)
			_TKN_AwaitLogicalUp(Format("SC{:03X}", Sc))
			_TKN.SuffixOwed := 0
			_TKN.Sent += 1
			Sleep(30)
		}
	} catch Any as InjectionFailure {
		_TKN.Failure := InjectionFailure
	} finally _TKN.Completed := true
}
_TKN_Main() {
	global _TKN
	_TKN.Window := Gui(, "Ergopti owned native Kana tap probe")
	_TKN.Edit := _TKN.Window.AddEdit("w360 r3")
	try {
		_TKN.Window.Show()
		WinActivate("ahk_id " . _TKN.Window.Hwnd)
		_TKN_Require(WinWaitActive("ahk_id " . _TKN.Window.Hwnd, , 2), "The exact owned target must become active.")
		_TKN.Edit.Focus()
		_TKN_Target()
		for Name in ["Ctrl", "Alt", "Shift", "LWin", "RWin", "vkDF", "SC029", "SC00C", "SC00D"]
			_TKN_Require(!GetKeyState(Name, "P") && !GetKeyState(Name), "No preexisting key state may be disturbed: " . Name)
		OnMessage(0x100, _TKN_Receive)
		if _TKN.Mode != "kana-plain" {
			_TKN_Send(0xDF, 0, 0)
			_TKN.OemOwed := true
			Started := A_TickCount
			while !GetKeyState("vkDF") && A_TickCount - Started < 1000
				Sleep(5)
			_TKN_Require(GetKeyState("vkDF"), "The genuine ordinary native OEM8 state must be down before suffix admission.")
		}
		_TKN_Require(TapHoldKanaAltGrHeld() == (_TKN.Mode == "kana-held"),
			"The real Kana helper must report exactly the native state under its explicit family seam.")
		for Name in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
			_TKN_Require(!GetKeyState(Name), "OEM8 must not masquerade as an AHK modifier.")
		SetTimer(_TKN_Inject, -20)
		Started := A_TickCount
		while !_TKN.Completed && A_TickCount - Started < 2000
			Sleep(10)
		_TKN_Require(_TKN.Completed && _TKN.Sent == 3, "All three owned native suffix vectors must complete before business assertions.")
		Sleep(50)
		if IsObject(_TKN.Failure)
			throw _TKN.Failure
		FileAppend("OBSERVATION tap-kana mode=" . _TKN.Mode . " actions=" . _TKN.Actions.Length
			. " left=" . _TKN.Received.Get(0x29, 0) . " right1=" . _TKN.Received.Get(0x0C, 0)
			. " right2=" . _TKN.Received.Get(0x0D, 0) . " oem_down=" . !!GetKeyState("vkDF") . "`n", "*")
		Held := _TKN.Mode == "kana-held"
		_TKN_Require(_TKN.Actions.Length == (Held ? 0 : 3), "Only plain taps may run the configured action.")
		for Sc in [0x29, 0x0C, 0x0D]
			_TKN_Require(_TKN.Received.Get(Sc, 0) == (Held ? 1 : 0), "Kana AltGr must preserve every original suffix exactly once.")
		if !Held {
			for Index, Id in ["number_row_left", "number_row_right_1", "number_row_right_2"]
				_TKN_Require(_TKN.Actions[Index] == "tap_key__" . Id, "The real handler must retain its binding identity.")
		}
	} finally {
		SetTimer(_TKN_Inject, 0)
		if _TKN.SuffixOwed {
			_TKN_Send(0, _TKN.SuffixOwed, 10)
			_TKN_AwaitLogicalUp(Format("SC{:03X}", _TKN.SuffixOwed))
			_TKN.SuffixOwed := 0
		}
		if _TKN.OemOwed {
			_TKN_Send(0xDF, 0, 2)
			_TKN_AwaitLogicalUp("vkDF")
			_TKN.OemOwed := false
		}
		OnMessage(0x100, _TKN_Receive, 0)
		_TKN.Window.Destroy()
	}
	FileAppend("PASS tap-kana-native " . _TKN.Mode, "*")
}
try {
	_TKN_Main()
	ExitApp(0)
} catch Any as TKNEntryFailure {
	FileAppend("FAIL tap-kana-native " . TKNEntryFailure.Message, "*")
	ExitApp(1)
}
