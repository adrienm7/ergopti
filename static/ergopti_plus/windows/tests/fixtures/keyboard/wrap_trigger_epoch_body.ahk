; tests/fixtures/keyboard/wrap_trigger_epoch_body.ahk

; Admission control only: real public descriptor/getter/wrapper, passive output.
; The registered F6 is deliberately a VK/I0 RegisterHotKey route, without a
; keyboard hook, so A_TimeIdlePhysical uses the real GetLastInputInfo fallback.
; User32 input is injected, not a hardware witness. No epoch is assigned/faked.
if A_Args.Length != 2 || A_Args[1] != "--allow-explicit-owned-wrap-trigger"
	throw Error("Explicit owned-window trigger opt-in is required.")
if A_PtrSize != 8 || !(A_Args[2] == "direct" || A_Args[2] == "registered-hotkey")
	throw Error("A known trigger case and the exact INPUT40 ABI are required.")
global Features := Map("shortcuts", Map(ConfigLeaf.WRAP_TEXT_IF_SELECTED, true)), _WS_Disabled := Map()
global _UIA_SelectionCache := 0, _SendHook := _WTE_Output
global _WTE := {Mode: A_Args[2], Window: 0, Edit: 0, Action: 0, Snapshot: 0,
	BeforeEpoch: 0, TriggerEpoch: 0, Outputs: [], Rings: [], Calls: 0, Injected: 0, Failure: 0, Registered: false}
_WTE_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerError(*) => 0
LoggerWarn(*) => 0
LoggerDebug(*) => 0
_WTE_Target() {
	global _WTE
	_WTE_Require(WIGetForegroundHwnd() == _WTE.Window.Hwnd && WIGetFocusedControlToken() == _WTE.Edit.Hwnd
		&& WinGetPID("ahk_id " . _WTE.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"The actual native trigger must remain confined to the child-owned Edit and its unchanged selection.")
}
_WTE_Output(Kind, Text, Args*) {
	global _WTE
	_WTE_Target()
	_WTE.Outputs.Push({Kind: Kind, Text: Text})
	return true
}
UpdateLastSentCharacter(Text) {
	global _WTE
	_WTE.Rings.Push(Text)
}
_WTE_Run(*) {
	global _WTE
	try {
		_WTE_Target()
		_WTE.Calls += 1
		_WTE.TriggerEpoch := _UIA_CurrentInputEpoch()
		Action := _WTE.Action
		Action.Call()
	} catch as Err
		_WTE.Failure := Err
}
_WTE_Inject() {
	global _WTE
	try {
		_WTE_Target()
		Packets := Buffer(80, 0)
		for Index, Flags in [0, 2] {
			Offset := (Index - 1) * 40
			NumPut("UInt", 1, Packets, Offset)
			NumPut("UShort", 0x75, "UShort", 0x40, "UInt", Flags, Packets, Offset + 8)
			NumPut("UPtr", 0x57544501, Packets, Offset + 24)
		}
		_WTE.Injected := DllCall("SendInput", "UInt", 2, "Ptr", Packets, "Int", 40, "UInt")
		_WTE_Require(_WTE.Injected == 2, "The original native F6 down/up vector must be accepted exactly.")
	} catch as Err
		_WTE.Failure := Err
}
_WTE_Main() {
	global _WTE, _UIA_SelectionCache
	_WTE.Window := Gui(, "Ergopti native wrap trigger admission")
	_WTE.Edit := _WTE.Window.AddEdit("w320 r3", "alpha")
	try {
		_WTE.Window.Show()
		WinActivate("ahk_id " . _WTE.Window.Hwnd)
		_WTE_Require(WinWaitActive("ahk_id " . _WTE.Window.Hwnd, , 2), "The owned receiver window must become active before the public trigger runs.")
		_WTE.Edit.Focus()
		_WTE_Target()
		for Key in [0x10, 0x11, 0x12, 0x5B, 0x5C]
			_WTE_Require(!(DllCall("GetAsyncKeyState", "Int", Key, "Short") & 0x8000), "Release modifiers before the native F6 trigger.")
		DllCall("SendMessageW", "Ptr", _WTE.Edit.Hwnd, "UInt", 0xB1, "Ptr", 0, "Ptr", -1)
		_WTE.Action := ErgoptiLayout_Action(Map("wrap", "[", "left", "[", "right", "]"), Map())
		_WTE.BeforeEpoch := _UIA_CurrentInputEpoch()
		_WTE.Snapshot := {Text: _WTE.Edit.Value, Hwnd: _WTE.Window.Hwnd, Control: _WTE.Edit.Hwnd,
			InputEpoch: _WTE.BeforeEpoch, CapturedAt: A_TickCount, Consumed: false}
		_UIA_SelectionCache := _WTE.Snapshot
		if _WTE.Mode == "direct"
			_WTE_Run()
		else {
			; A VK hotkey with no wildcard, SC, $, or positive input level does
			; not request the keyboard hook. It uses the genuine global hotkey.
			Hotkey("F6", _WTE_Run, "I0")
			_WTE.Registered := true
			SetTimer(_WTE_Inject, -50)
			Started := A_TickCount
			while !_WTE.Calls && !IsObject(_WTE.Failure) && A_TickCount - Started < 2000
				Sleep(5)
		}
		if IsObject(_WTE.Failure)
			throw _WTE.Failure
		_WTE_Target()
		Start := 0, End := 0
		DllCall("SendMessageW", "Ptr", _WTE.Edit.Hwnd, "UInt", 0xB0, "UInt*", &Start, "UInt*", &End)
		FileAppend("OBSERVATION wrap-trigger mode=" . _WTE.Mode . " calls=" . _WTE.Calls . " injected=" . _WTE.Injected
			. " before_epoch=" . _WTE.BeforeEpoch . " trigger_epoch=" . _WTE.TriggerEpoch
			. " epoch_changed=" . (_WTE.BeforeEpoch != _WTE.TriggerEpoch)
			. " selection_start=" . Start . " selection_end=" . End . " snapshot_consumed=" . _WTE.Snapshot.Consumed
			. " outputs=" . _WTE.Outputs.Length . " first_kind=" . (_WTE.Outputs.Length ? _WTE.Outputs[1].Kind : "none") . "`n", "*")
		_WTE_Require(_WTE.Calls == 1 && Start == 0 && End == 5 && _WTE.Edit.Value == "alpha",
			"One actual callback must retain the same native window, focused control, selected range and underlying text.")
		if _WTE.Mode == "registered-hotkey"
			_WTE_Require(_WTE.BeforeEpoch != _WTE.TriggerEpoch,
				"The no-hook native GetLastInputInfo fallback must actually advance before using this case as admission evidence.")
		_WTE_Require(_WTE.Snapshot.Consumed && _WTE.Outputs.Length == 1 && _WTE.Outputs[1].Kind == "SendInstant"
			&& _WTE.Outputs[1].Text == "[alpha]",
			"The authorized wrapping trigger must consume its still-identical selection snapshot rather than invalidate itself.")
	} finally {
		SetTimer(_WTE_Inject, 0)
		if _WTE.Registered
			Hotkey("F6", "Off")
		_WTE.Window.Destroy()
	}
}
try {
	_WTE_Main()
	FileAppend("PASS wrap-trigger-epoch " . _WTE.Mode, "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
