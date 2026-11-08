; tests/fixtures/layout_row_external_flags_body.ahk

; A real global hotkey sender and its receiver use different processes and
; input threads. No AttachThreadInput is used. The parent owns the target Edit.
if A_Args.Length != 8 || A_Args[1] != "--allow-explicit-family-edit-row-flags" || A_PtrSize != 8
	throw Error("Explicit owned-family Edit and exact INPUT40 ABI opt-in are required.")
if !(A_Args[2] == "plain" || A_Args[2] == "held" || A_Args[2] == "released")
	throw Error("Unknown external receiver row case.")
global _SharedDir := A_Args[8]
global Features := Map("layout", Map("ergopti_base", true,
	"emulate_number_row", true, "emulate_top_row", false,
	"emulate_home_row", true, "emulate_bottom_row", true),
	"hotstrings", Map("magic_key", Map("replace", Map("enabled", false))))
global ScriptInformation := Map("MagicKeySourceChosen", false, "MagicKeySourceScan", "SC030")
global _LRNX := {Mode: A_Args[2], Window: Integer(A_Args[3]), Edit: Integer(A_Args[4]), Pid: Integer(A_Args[5]),
	Vk: Integer(A_Args[6]), Receipt: A_Args[7], Callbacks: [], ShiftReleased: false, ShiftOwned: false,
	Failure: 0, Observer: 0, ObservedKeys: 0, ObservedText: "", ExpectedHost: "", OriginalMarker: 0x4C524E58, Received: 0}
LoggerStart(*) => 0
LoggerSuccess(*) => 0
LoggerError(*) => 0
_LRNX_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_LRNX_Target() {
	global _LRNX
	ActualPid := 0
	ThreadId := DllCall("GetWindowThreadProcessId", "Ptr", _LRNX.Window, "UInt*", &ActualPid, "UInt")
	Info := Buffer(72, 0)
	NumPut("UInt", Info.Size, Info)
	_LRNX_Require(ActualPid == _LRNX.Pid && ActualPid != DllCall("GetCurrentProcessId", "UInt")
		&& ThreadId != DllCall("GetCurrentThreadId", "UInt")
		&& DllCall("GetForegroundWindow", "Ptr") == _LRNX.Window
		&& DllCall("GetGUIThreadInfo", "UInt", ThreadId, "Ptr", Info, "Int")
		&& NumGet(Info, 16, "Ptr") == _LRNX.Edit
		&& WinGetPID("ahk_id " . _LRNX.Edit) == _LRNX.Pid,
		"Every original and replay must remain confined to the parent-owned foreground Edit on a distinct input thread.")
}
_LRNX_Dispatch(Original, Name) {
	global _LRNX
	_LRNX_Target()
	_LRNX.Callbacks.Push({Name: Name, AsyncShift: !!(DllCall("GetAsyncKeyState", "Int", 0x10, "Short") & 0x8000),
		LogicalShift: !!GetKeyState("Shift"), ThreadShift: !!(DllCall("GetKeyState", "Int", 0x10, "Short") & 0x8000),
		LogicalCtrl: !!GetKeyState("Ctrl"), ThreadCtrl: !!(DllCall("GetKeyState", "Int", 0x11, "Short") & 0x8000)})
	return Original.Call(Name)
}
_LRNX_Register(Name, Callback, Options) {
	Hotkey(Name, _LRNX_Dispatch.Bind(Callback), Options)
}
_LRNX_Packets(Rows) {
	global _LRNX
	Packets := Buffer(Rows.Length * 40, 0)
	for Index, Row in Rows {
		Offset := (Index - 1) * 40
		NumPut("UInt", 1, Packets, Offset)
		NumPut("UShort", Row[1], "UShort", Row[2], "UInt", Row[3], Packets, Offset + 8)
		NumPut("UPtr", _LRNX.OriginalMarker, Packets, Offset + 24)
	}
	return Packets
}
_LRNX_ReleaseShift() {
	global _LRNX
	if !_LRNX.ShiftOwned
		return
	_LRNX_Target()
	Packets := _LRNX_Packets([[0xA0, 0x2A, 2]])
	_LRNX_Require(DllCall("SendInput", "UInt", 1, "Ptr", Packets, "Int", 40, "UInt") == 1,
		"The fixture must balance its own original Shift-down.")
	_LRNX.ShiftOwned := false
}
_LRNX_Inject() {
	global _LRNX
	try {
		_LRNX_Target()
		Rows := []
		if _LRNX.Mode != "plain" {
			; Shift-down is its own injection, acknowledged by the system key
			; state before the row key follows: batched with the key, the
			; receiver could translate the key before it saw Shift (one CI run
			; read 'q' for 'Q'). The released Shift-up still travels with the key,
			; so it still precedes the admitted row callback.
			ShiftDown := _LRNX_Packets([[0xA0, 0x2A, 0]])
			_LRNX_Require(DllCall("SendInput", "UInt", 1, "Ptr", ShiftDown, "Int", 40, "UInt") == 1,
				"The native Shift-down must be accepted.")
			_LRNX.ShiftOwned := true
			Acknowledged := A_TickCount
			while !(DllCall("GetAsyncKeyState", "Int", 0x10, "Short") & 0x8000) && A_TickCount - Acknowledged < 500
				Sleep(5)
			_LRNX_Require(DllCall("GetAsyncKeyState", "Int", 0x10, "Short") & 0x8000,
				"The system must acknowledge the native Shift-down before the row key.")
			_LRNX_Target()
		}
		Rows.Push([0, 0x10, 8], [0, 0x10, 10])
		if _LRNX.Mode == "released"
			Rows.Push([0xA0, 0x2A, 2])
		Packets := _LRNX_Packets(Rows)
		_LRNX_Require(DllCall("SendInput", "UInt", Rows.Length, "Ptr", Packets, "Int", 40, "UInt") == Rows.Length,
			"The full native INPUT40 original vector must be accepted.")
		if _LRNX.Mode == "released"
			_LRNX.ShiftOwned := false
		_LRNX.ShiftReleased := !(DllCall("GetAsyncKeyState", "Int", 0x10, "Short") & 0x8000)
	} catch as Err
		_LRNX.Failure := Err
}
_LRNX_ObserveReceipt() {
	global _LRNX
	Text := ""
	try Text := FileRead(_LRNX.Receipt, "UTF-8")
	if !RegExMatch(Text, "^([01])\|(-?[0-9]+)\|([0-9]+)\|([0-9]+)\|([0-9]+)$", &Fields)
		return false
	_LRNX_Require(Integer(Fields[3]) == _LRNX.Vk && Integer(Fields[4]) == _LRNX.Edit && Integer(Fields[5]) == _LRNX.Pid,
		"The receiver receipt must identify the exact parent-owned Edit, process and key.")
	_LRNX.Received := {Shift: Integer(Fields[1]), Extra: Integer(Fields[2])}
	return true
}

_LRNX_ObservedKey(Hook, Vk, Sc) {
	global _LRNX
	if Sc == 0x10
		_LRNX.ObservedKeys += 1
}
_LRNX_ObservedChar(Hook, Text) {
	global _LRNX
	_LRNX.ObservedText .= Text
}

_LRNX_Main() {
	global _LRNX
	try {
		_LRNX_Target()
		for Name in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
			_LRNX_Require(!GetKeyState(Name, "P") && !GetKeyState(Name), "Release modifiers before this native external-receiver probe.")
		ReceiverThread := DllCall("GetWindowThreadProcessId", "Ptr", _LRNX.Window, "Ptr", 0, "UInt")
		_LRNX.ExpectedHost := _LRN_HostCharacter(_LRNX.Vk, _LRNX.Mode != "plain", DllCall("GetKeyboardLayout", "UInt", ReceiverThread, "Ptr"))
		_LRNX.Observer := InputHook("V L0 I1")
		_LRNX.Observer.KeyOpt("{All}", "N")
		_LRNX.Observer.OnKeyDown := _LRNX_ObservedKey
		_LRNX.Observer.OnChar := _LRNX_ObservedChar
		_LRNX.Observer.Start()
		_LRNX_Require(_LayoutRowPassthroughCriterion("SC010", "+SC010"), "The genuine disabled-row criterion must admit its native variant.")
		_LRNX_Require(RegisterLayoutRowPassthrough(_LRNX_Register, HotIf) == 240, "The real native registrar must install every original row variant.")
		SetTimer(_LRNX_Inject, -1)
		Started := A_TickCount
		while !_LRNX_ObserveReceipt() && !IsObject(_LRNX.Failure) && A_TickCount - Started < 2500
			Sleep(5)
		if IsObject(_LRNX.Failure)
			throw _LRNX.Failure
		_LRNX_ReleaseShift()
		ObservedAt := A_TickCount
		while (_LRNX.ObservedKeys == 0 || _LRNX.ObservedText == "") && A_TickCount - ObservedAt < 500
			Sleep(5)
		Sleep(25)
		FileAppend("OBSERVATION row-native-feed mode=" . _LRNX.Mode . " observer_level=" . _LRNX.Observer.MinSendLevel
			. " keydowns=" . _LRNX.ObservedKeys . " char_units=" . StrLen(_LRNX.ObservedText)
			. " expected_units=" . StrLen(_LRNX.ExpectedHost) . "`n", "*")
		_LRNX_Require(_LRNX.Observer.MinSendLevel == 1 && _LRNX.ObservedKeys == 1 && _LRNX.ObservedText == _LRNX.ExpectedHost,
			"The true I1 observer must receive one keydown and the exact host character, without a duplicate feed; keys=" . _LRNX.ObservedKeys . ", units=" . StrLen(_LRNX.ObservedText))
		_LRNX_Require(_LRNX.Callbacks.Length == 1 && IsObject(_LRNX.Received),
			"Exactly one real row callback and one external receiver receipt are required; callbacks=" . _LRNX.Callbacks.Length)
		Callback := _LRNX.Callbacks[1], Received := _LRNX.Received
		FileAppend("OBSERVATION external-row-flags mode=" . _LRNX.Mode . " variant=" . Callback.Name
			. " shift_released=" . _LRNX.ShiftReleased . " callback_async_shift=" . Callback.AsyncShift
			. " callback_logical_shift=" . Callback.LogicalShift . " callback_thread_shift=" . Callback.ThreadShift
			. " callback_logical_ctrl=" . Callback.LogicalCtrl . " callback_thread_ctrl=" . Callback.ThreadCtrl
			. " receiver_shift=" . Received.Shift . "`n", "*")
		_LRNX_Require(SubStr(Callback.Name, 1, 1) == "~" && Received.Extra == _LRNX.OriginalMarker, "The native tilde owner must pass the exact original event to the external receiver.")
		if _LRNX.Mode == "released"
			_LRNX_Require(_LRNX.ShiftReleased && !Callback.AsyncShift, "The original Shift-up must precede the admitted callback.")
		_LRNX_Require(Received.Shift == (_LRNX.Mode != "plain"), "The external receiving key must retain its original modifier flags.")
	} finally {
		SetTimer(_LRNX_Inject, 0)
		if IsObject(_LRNX.Observer)
			_LRNX.Observer.Stop()
		_LRNX_ReleaseShift()
	}
}
try {
	_LRNX_Main()
	FileAppend("PASS layout-row-external-native-flags", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
