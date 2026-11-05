; tests/fixtures/layout_row_native_flags_body.ahk

; Native original input and real row passthrough replay target only this Edit.
; The registrar observer forwards to genuine Hotkey and the original callback.
if A_Args.Length != 6 || A_Args[6] != "--allow-explicit-owned-edit-row-flags"
	throw Error("Explicit owned-Edit row flags opt-in is required.")
if !(A_Args[5] == "plain" || A_Args[5] == "held" || A_Args[5] == "released") || A_PtrSize != 8
	throw Error("The exact INPUT40 ABI and a known native row case are required.")
global _SharedDir := A_Args[3]
global Features := Map("layout", Map("ergopti_base", true,
	"emulate_number_row", true, "emulate_top_row", false,
	"emulate_home_row", true, "emulate_bottom_row", true),
	"hotstrings", Map("magic_key", Map("replace", Map("enabled", false))))
global ScriptInformation := Map("MagicKeySourceChosen", false, "MagicKeySourceScan", "SC030")
global _LRNF := {Mode: A_Args[5], Window: 0, Edit: 0, Received: [], Callbacks: [],
	ShiftReleased: false, ShiftOwned: false, Failure: 0, Vk: 0, Observer: 0, ObservedKeys: 0, ObservedText: "", ExpectedHost: "", OriginalMarker: 0x4C524E46}

LoggerStart(*) => 0
LoggerSuccess(*) => 0
LoggerError(*) => 0
_LRNF_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_LRNF_Target() {
	global _LRNF
	_LRNF_Require(DllCall("GetForegroundWindow", "Ptr") == _LRNF.Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == _LRNF.Edit.Hwnd
		&& WinGetPID("ahk_id " . _LRNF.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Native input must stay confined to the child-owned foreground Edit.")
}
_LRNF_Dispatch(Original, Name) {
	global _LRNF
	_LRNF_Target()
	_LRNF.Callbacks.Push({Name: Name, Shift: !!(DllCall("GetAsyncKeyState", "Int", 0x10, "Short") & 0x8000),
		LogicalShift: !!GetKeyState("Shift"), ThreadShift: !!(DllCall("GetKeyState", "Int", 0x10, "Short") & 0x8000),
		LogicalCtrl: !!GetKeyState("Ctrl"), ThreadCtrl: !!(DllCall("GetKeyState", "Int", 0x11, "Short") & 0x8000)})
	return Original.Call(Name)
}
_LRNF_Register(Name, Callback, Options) {
	Hotkey(Name, _LRNF_Dispatch.Bind(Callback), Options)
}
_LRNF_Packets(Rows) {
	global _LRNF
	Packets := Buffer(Rows.Length * 40, 0)
	for Index, Row in Rows {
		Offset := (Index - 1) * 40
		NumPut("UInt", 1, Packets, Offset)
		NumPut("UShort", Row[1], "UShort", Row[2], "UInt", Row[3], Packets, Offset + 8)
		NumPut("UPtr", _LRNF.OriginalMarker, Packets, Offset + 24)
	}
	return Packets
}
_LRNF_ReleaseShift() {
	global _LRNF
	if !_LRNF.ShiftOwned
		return
	_LRNF_Target()
	Packets := _LRNF_Packets([[0xA0, 0x2A, 2]])
	_LRNF_Require(DllCall("SendInput", "UInt", 1, "Ptr", Packets, "Int", 40, "UInt") == 1,
		"The fixture must balance its own original Shift-down.")
	_LRNF.ShiftOwned := false
}
_LRNF_Inject() {
	global _LRNF
	try {
		_LRNF_Target()
		Rows := []
		if _LRNF.Mode != "plain" {
			Rows.Push([0xA0, 0x2A, 0])
			_LRNF.ShiftOwned := true
		}
		Rows.Push([0, 0x10, 8], [0, 0x10, 10])
		if _LRNF.Mode == "released"
			Rows.Push([0xA0, 0x2A, 2])
		Packets := _LRNF_Packets(Rows)
		_LRNF_Require(DllCall("SendInput", "UInt", Rows.Length, "Ptr", Packets, "Int", 40, "UInt") == Rows.Length,
			"The full native INPUT40 original vector must be accepted.")
		if _LRNF.Mode == "released"
			_LRNF.ShiftOwned := false
		_LRNF.ShiftReleased := !(DllCall("GetAsyncKeyState", "Int", 0x10, "Short") & 0x8000)
	} catch as Err
		_LRNF.Failure := Err
}
_LRNF_Receive(WParam, LParam, Message, Hwnd) {
	global _LRNF
	if Hwnd != _LRNF.Edit.Hwnd || WParam != _LRNF.Vk
		return
	_LRNF.Received.Push({Shift: !!(DllCall("GetKeyState", "Int", 0x10, "Short") & 0x8000),
		Extra: DllCall("GetMessageExtraInfo", "UPtr")})
	return
}

_LRNF_ObservedKey(Hook, Vk, Sc) {
	global _LRNF
	if Sc == 0x10
		_LRNF.ObservedKeys += 1
}
_LRNF_ObservedChar(Hook, Text) {
	global _LRNF
	_LRNF.ObservedText .= Text
}

_LRNF_Main() {
	global _LRNF
	_LRNF.Window := Gui(, "Ergopti native row flag probe")
	_LRNF.Edit := _LRNF.Window.AddEdit("w320 r3")
	try {
		_LRNF.Window.Show()
		WinActivate("ahk_id " . _LRNF.Window.Hwnd)
		_LRNF_Require(WinWaitActive("ahk_id " . _LRNF.Window.Hwnd, , 2), "The owned target must acquire focus.")
		_LRNF.Edit.Focus()
		_LRNF_Target()
		for Name in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
			_LRNF_Require(!GetKeyState(Name, "P") && !GetKeyState(Name), "Release modifiers before this native probe.")
		_LRNF.Vk := DllCall("MapVirtualKeyW", "UInt", 0x10, "UInt", 3, "UInt")
		_LRNF_Require(_LRNF.Vk >= 0x41 && _LRNF.Vk <= 0x5A, "The native top-row key must resolve to a letter VK.")
		_LRNF.ExpectedHost := _LRN_HostCharacter(_LRNF.Vk, _LRNF.Mode != "plain", DllCall("GetKeyboardLayout", "UInt", 0, "Ptr"))
		_LRNF.Observer := InputHook("V L0 I1")
		_LRNF.Observer.KeyOpt("{All}", "N")
		_LRNF.Observer.OnKeyDown := _LRNF_ObservedKey
		_LRNF.Observer.OnChar := _LRNF_ObservedChar
		_LRNF.Observer.Start()
		_LRNF_Require(_LayoutRowPassthroughCriterion("SC010", "+SC010"), "The real disabled-row criterion must admit the native variant.")
		OnMessage(0x100, _LRNF_Receive)
		_LRNF_Require(RegisterLayoutRowPassthrough(_LRNF_Register, HotIf) == 240, "The genuine native registrar must install all original variants.")
		SetTimer(_LRNF_Inject, -1)
		Started := A_TickCount
		while _LRNF.Received.Length == 0 && !IsObject(_LRNF.Failure) && A_TickCount - Started < 2000
			Sleep(5)
		if IsObject(_LRNF.Failure)
			throw _LRNF.Failure
		_LRNF_ReleaseShift()
		ObservedAt := A_TickCount
		while (_LRNF.ObservedKeys == 0 || _LRNF.ObservedText == "") && A_TickCount - ObservedAt < 500
			Sleep(5)
		Sleep(25)
		FileAppend("OBSERVATION row-native-feed mode=" . _LRNF.Mode . " observer_level=" . _LRNF.Observer.MinSendLevel
			. " keydowns=" . _LRNF.ObservedKeys . " char_units=" . StrLen(_LRNF.ObservedText)
			. " expected_units=" . StrLen(_LRNF.ExpectedHost) . "`n", "*")
		_LRNF_Require(_LRNF.Observer.MinSendLevel == 1 && _LRNF.ObservedKeys == 1 && _LRNF.ObservedText == _LRNF.ExpectedHost,
			"The true I1 observer must receive one keydown and the exact host character, without a duplicate feed; keys=" . _LRNF.ObservedKeys . ", units=" . StrLen(_LRNF.ObservedText))
		_LRNF_Require(_LRNF.Edit.Value == _LRNF.ExpectedHost, "The owned Edit must receive the host character exactly once.")
		_LRNF_Require(_LRNF.Callbacks.Length == 1 && _LRNF.Received.Length == 1,
			"Exactly one real row callback and one receiving keydown are required; callbacks=" . _LRNF.Callbacks.Length . ", keydowns=" . _LRNF.Received.Length)
		Callback := _LRNF.Callbacks[1], Received := _LRNF.Received[1]
		_LRNF_Require(SubStr(Callback.Name, 1, 1) == "~" && Received.Extra == _LRNF.OriginalMarker, "The native tilde owner must pass the exact original event to its receiver.")
		if _LRNF.Mode == "released"
			_LRNF_Require(_LRNF.ShiftReleased && !Callback.Shift, "The original native Shift-up must precede the admitted callback.")
		_LRNF_Require(Received.Shift == (_LRNF.Mode != "plain"),
			"The receiving key must retain the original modifier flags: mode=" . _LRNF.Mode . ", variant=" . Callback.Name
			. ", shift_released=" . _LRNF.ShiftReleased . ", callback_shift=" . Callback.Shift
			. ", logical_shift=" . Callback.LogicalShift . ", thread_shift=" . Callback.ThreadShift
			. ", logical_ctrl=" . Callback.LogicalCtrl . ", thread_ctrl=" . Callback.ThreadCtrl . ", receiver_shift=" . Received.Shift)
	} finally {
		SetTimer(_LRNF_Inject, 0)
		if IsObject(_LRNF.Observer)
			_LRNF.Observer.Stop()
		OnMessage(0x100, _LRNF_Receive, 0)
		_LRNF_ReleaseShift()
		_LRNF.Window.Destroy()
	}
}
try {
	_LRNF_Main()
	FileAppend("PASS layout-row-native-flags", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
