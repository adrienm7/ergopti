; tests/fixtures/send_key_native_scalar_body.ahk

; Real parse/emission, TextSender and synthetic RAM/prefix transaction. Only the
; unused tooltip surface is a passive presentation port; native keys target this Edit.
if A_Args.Length != 3 || A_Args[1] != "--allow-explicit-owned-edit-send-key"
	throw Error("Explicit owned-Edit send-key opt-in is required.")
if !(A_Args[2] == "ascii" || A_Args[2] == "bmp" || A_Args[2] == "astral")
	throw Error("Unknown native scalar case.")
global _SharedDir := A_Args[3]
global _SEND_INPUT_VOCABULARY_JSON := FileRead(_SharedDir . "\modules\actions\send_keys.json", "UTF-8")
global _SEND_INPUT_VOCABULARY := JsonParse(_SEND_INPUT_VOCABULARY_JSON)
global TEXT_SENDER_SEND_LEVEL := 0
global HSE_Buffer := "", _PrefixBuffer := "", HSE_Suppressed := 0, HSE_FinalNoOpPending := false
global HSE_StartIsWordBoundary := false, HSE_StartIsLineStart := false
global HSE_ArrowResetsWord := true, HSE_ShortcutResetsWord := true, HSE_TapHoldResetsWord := true
global _TH_OwnedModifiers := Map(), LayerEnabled := false, _TapHoldTapInDispatch := ""
global _PrefixFocusedControlToken := 0, _PrefixInputContextGeneration := 0, _PrefixContentGeneration := 0
global _PrefixDeferredGeneration := 0, _TriggerSet := Map(), _TooltipDequeueActive := false
global _TooltipGeneration := 0, _TooltipActiveSurface := 0, _TooltipRequestSerial := 0
global _KLLastShownSuggestion := 0, Keystats := {initialized: false}
global _SNK := {Mode: A_Args[2], Window: 0, Edit: 0, Payloads: [], Errors: [], Critical: false, Finishes: 0, Hides: 0}
global _AHK_SendInput := _SNK_NativeSend

_SNK_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerError(Args*) {
	global _SNK
	_SNK.Errors.Push(Args)
}
LoggerWarn(Args*) {
	global _SNK
	_SNK.Errors.Push(Args)
}
LoggerDebug(Tag, Message, Args*) {
	global _SNK
	if Tag == "HotstringBuffers"
		_SNK.Finishes += 1
}
TooltipHide(Args*) {
	global _SNK
	_SNK.Hides += 1
}
_SNK_Target() {
	global _SNK
	_SNK_Require(DllCall("GetForegroundWindow", "Ptr") == _SNK.Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == _SNK.Edit.Hwnd
		&& WinGetPID("ahk_id " . _SNK.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Native input must remain confined to the child-owned foreground Edit.")
}
_SNK_NativeSend(Keys) {
	global _SNK
	_SNK_Target()
	_SNK.Payloads.Push(Keys)
	_SNK.Critical := !!A_IsCritical
	_SNK_Require(_SNK.Critical, "The actual native replay must execute inside the real synthetic transaction.")
	SendInput(Keys)
}
_SNK_Main() {
	global _SNK, _PrefixInputContextGeneration, _PrefixContentGeneration
	Value := _SNK.Mode == "ascii" ? "a" : (_SNK.Mode == "bmp" ? Chr(0xE9) : Chr(0x1F44B))
	Parsed := SendInputParse("key", Value)
	_SNK_Require(Parsed is Map && Parsed.Has("char") && Parsed["char"] == Value,
		"The real shared grammar must admit this exact single scalar as a character key.")
	_SNK.Window := Gui(, "Ergopti native send-key scalar probe")
	_SNK.Edit := _SNK.Window.AddEdit("w320 r3")
	try {
		_SNK.Window.Show()
		WinActivate("ahk_id " . _SNK.Window.Hwnd)
		_SNK_Require(WinWaitActive("ahk_id " . _SNK.Window.Hwnd, , 2), "The native target must acquire focus.")
		_SNK.Edit.Focus()
		_SNK_Target()
		for Name in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
			_SNK_Require(!GetKeyState(Name, "P") && !GetKeyState(Name), "Release modifiers before native scalar output.")
		Accepted := SendInputEmit("key", Parsed)
		Started := A_TickCount
		while _SNK.Edit.Value != Value && A_TickCount - Started < 1000
			Sleep(5)
		Observed := _SNK.Edit.Value
		FileAppend("OBSERVATION send-key mode=" . _SNK.Mode . " accepted=" . Accepted
			. " payload=" . (_SNK.Payloads.Length ? _SNK.Payloads[1] : "") . " critical=" . _SNK.Critical
			. " context=" . _PrefixInputContextGeneration . " content=" . _PrefixContentGeneration
			. " finishes=" . _SNK.Finishes . " hides=" . _SNK.Hides
			. " expected_units=" . StrLen(Value) . " received_units=" . StrLen(Observed) . "`n", "*")
		_SNK_Require(Accepted && _SNK.Errors.Length == 0 && _SNK.Payloads.Length == 1,
			"The actual parser/emitter and native sender must admit one output without errors.")
		_SNK_Require(_SNK.Critical && _PrefixInputContextGeneration == 1 && _PrefixContentGeneration == 1
			&& _SNK.Finishes == 1 && _SNK.Hides == 1,
			"The real default-policy synthetic commit/send/prefix finalizer must execute.")
		_SNK_Require(Observed == Value, "The receiving Edit must obtain the exact accepted scalar character.")
	} finally _SNK.Window.Destroy()
}
try {
	_SNK_Main()
	FileAppend("PASS send-key-native-scalar " . _SNK.Mode, "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
