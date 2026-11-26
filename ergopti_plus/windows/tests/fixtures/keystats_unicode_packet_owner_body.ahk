; tests/fixtures/keystats_unicode_packet_owner_body.ahk
; Real KEYEVENTF_UNICODE is confined to a verified child-owned Edit; no named Enter/Tab is sent.
#Requires AutoHotkey v2.0

KL_Watchers_OnKeystroke(*) { ; session observer only; no session timer in this child
	return true
}
KL_Watchers_OnPrivateKeystroke(*) {
	throw Error("The verified public receiver must not become a private activity sample.")
}
KL_Watchers_DetectShortcut(*) {
	throw Error("The existing explicit shortcut-classification port must be used.")
}
KL_LogShortcut(*) {
	throw Error("This fixture sends no shortcut.")
}
KL_Ergo_OnKeystroke(*) {
	return true
}
KL_Roi_OnChar(*) {
	return true
}
KL_Roi_OnKey(*) {
	return true
}
WPMWidget_Push(*) {
	return true
}
PersonalInfoRedactForLog(*) {
	throw Error("This public non-synthetic observation cannot require private redaction.")
}
_KID_NoShortcut(*) => ""
_KID_Down(Ih, Vk, Sc) {
	global _KID
	if !_KID.Active
		return
	try _KID_Target()
	catch Any as Failure {
		_KID.Failure := Failure
		return
	}
	_KID.LastCallback := A_TickCount
	if Vk == _KID.ExpectedVk
		_KID.TargetDown += 1
	KL_Hook_OnKeyDown(Ih, Vk, Sc, , , _KID_NoShortcut, KL_Ergo_OnKeystroke)
}
_KID_Char(Ih, Text) {
	global _KID
	if !_KID.Active
		return
	try _KID_Target()
	catch Any as Failure {
		_KID.Failure := Failure
		return
	}
	_KID.LastCallback := A_TickCount
	_KID.CharCalls += 1
	for Char in StrSplit(Text)
		_KID.CharUnits .= (_KID.CharUnits == "" ? "" : ",") . Ord(Char)
	KL_Hook_OnChar(Ih, Text, , , KL_Ergo_OnKeystroke)
}
_KID_KeyMessage(WParam, LParam, Message, Hwnd) {
	global _KID
	if _KID.Active && Hwnd == _KID.Edit.Hwnd && WParam == _KID.ExpectedVk
		_KID.NativeDown += 1
}
_KID_Target() {
	global _KID
	_KSD_Require(DllCall("User32\GetForegroundWindow", "Ptr") == _KID.Window.Hwnd
		&& DllCall("User32\GetFocus", "Ptr") == _KID.Edit.Hwnd
		&& WinGetPID("ahk_id " . _KID.Window.Hwnd) == ProcessExist(),
		"Every native input must remain confined to the exact child-owned foreground Edit.")
	for Modifier in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
		_KSD_Require(!GetKeyState(Modifier, "P"), "Native fixture cannot run over held physical modifiers.")
}
; This explicit native I/O port constructs only one Unicode down/up pair.
; It does not manufacture either InputHook callback or mutate a keystats buffer.
_KPU_SendUnicode(Unit) {
	_KID_Target()
	Size := A_PtrSize == 8 ? 40 : 28
	Keyboard := A_PtrSize == 8 ? 8 : 4
	Inputs := Buffer(Size * 2, 0)
	for Index, Flags in [0x0004, 0x0006] {
		Base := (Index - 1) * Size
		NumPut("UInt", 1, Inputs, Base)
		NumPut("UShort", Unit, Inputs, Base + Keyboard + 2)
		NumPut("UInt", Flags, Inputs, Base + Keyboard + 4)
	}
	_KSD_Require(DllCall("User32\SendInput", "UInt", 2, "Ptr", Inputs, "Int", Size, "UInt") == 2,
		"The owned receiver must accept exactly one real Unicode down/up input pair.")
}
; Passive native dialog-code observation only. AHK WantTab rewrites named
; VK_TAB, not VK_PACKET. Packet Tab is still delivered as WM_CHAR9 even though
; this native Edit does not materialize that control character as stored text.
_KPU_DialogCode(WParam, LParam, Message, Hwnd) {
	global _KID
	if _KID.Active && Hwnd == _KID.Edit.Hwnd {
		_KID.DialogRequests += 1
	}
}

_KPU_CharMessage(WParam, LParam, Message, Hwnd) {
	global _KID
	if _KID.Active && Hwnd == _KID.Edit.Hwnd {
		_KID.ReceiverChars += 1
		_KID.ReceiverUnits .= (_KID.ReceiverUnits == "" ? "" : ",") . WParam
	}
}

_KID_Exercise() {
	global _KID, _KSD
	_KID.Window := Gui(, "Ergopti keystats native callback probe")
	_KID.Edit := _KID.Window.AddEdit("w340 r4 Multi WantReturn WantTab", _KID.Mode == "backspace" ? "keepX" : "")
	Hook := 0
	PreviousLevel := A_SendLevel
	try {
		_KID.Window.Show()
		WinActivate("ahk_id " . _KID.Window.Hwnd)
		_KSD_Require(WinWaitActive("ahk_id " . _KID.Window.Hwnd, , 2), "The exact private receiver must acquire foreground.")
		_KID.Edit.Focus()
		_KID_Target()
		SendMessage(0xB1, -1, -1, _KID.Edit.Hwnd)
		Keystats.initialized := true
		MetricsFilters.secure_field := false
		_KSD_Acquire({App: "owned-native-keystats.exe", Title: "Owned native keystats receiver", Hwnd: _KID.Window.Hwnd})
		_KSD_Require(KL_Hook_RefreshContext(true) && !MF_ShouldFilter(), "The genuine canonical focus/privacy owners must admit the public receiver.")
		Hook := InputHook(HookDispatcherConst.INPUT_HOOK_OPTS)
		Hook.KeyOpt("{All}", "+N")
		Hook.NotifyNonText := true
		Hook.OnKeyDown := _KID_Down
		Hook.OnChar := _KID_Char
		OnMessage(0x100, _KID_KeyMessage)
		OnMessage(0x0087, _KPU_DialogCode)
		OnMessage(0x0102, _KPU_CharMessage)
		_KID.Active := true
		Hook.Start()
		_KSD_Require(Hook.InProgress, "The actual InputHook must own its active native hook.")
		_KID_Target()
		SendLevel(2)
		_KPU_SendUnicode(_KID.Mode == "packet-lf" ? 10 : 9)
		SendLevel(PreviousLevel)
		Started := A_TickCount
		while TickElapsed(Started) < 2000 {
			if _KID.NativeDown == 1 && _KID.TargetDown == 1 && TickElapsed(_KID.LastCallback) >= 100
				break
			Sleep(5)
		}
		_KID_Target()
		if IsObject(_KID.Failure)
			throw _KID.Failure
		_KSD_Require(_KID.NativeDown == 1 && _KID.TargetDown == 1 && _KSD.Errors == 0,
			"Exactly one actual native receiver keydown and one InputHook keydown must arrive without swallowed errors.")
		ExpectedText := _KID.Mode == "packet-lf" ? "`n" : "`t"
		; Input character preservation is independent of target-app text acceptance.
		; Native250 proves WM_CHAR9/InputHook9 with an empty Edit for packet Tab.
		ExpectedEditText := _KID.Mode == "packet-lf" ? "`n" : ""
		ObservedText := StrReplace(_KID.Edit.Value, "`r`n", "`n")
		ObservedUnits := ""
		for Character in StrSplit(ObservedText)
			ObservedUnits .= (ObservedUnits == "" ? "" : ",") . Ord(Character)
		FileAppend("RECEIVER unicode-packet mode=" . _KID.Mode . " receiver_chars=" . _KID.ReceiverChars
			. " receiver_units=" . _KID.ReceiverUnits . " edit_units=" . ObservedUnits
			. " dialog_requests=" . _KID.DialogRequests . " hook_chars=" . _KID.CharCalls
			. " hook_units=" . _KID.CharUnits . "`n", "*", "UTF-8")
		_KSD_Require(_KID.ReceiverChars == 1 && _KID.ReceiverUnits == (_KID.Mode == "packet-lf" ? "10" : "9"),
			"One actual native WM_CHAR must reach the exact owned receiver with the sent Unicode code unit.")
		_KSD_Require(ObservedText == ExpectedEditText,
			"The native Edit must preserve its independently qualified LF/packet-Tab text acceptance behavior.")
		Tokens := ""
		for Event in Keystats.buffer_events
			Tokens .= (Tokens == "" ? "" : ",") . (Event[1] == "`n" ? "LF" : Event[1] == "`t" ? "TABCHAR" : Event[1])
		FileAppend("RECEIPT native-keystats mode=" . _KID.Mode . " receiver_down=" . _KID.NativeDown
			. " hook_down=" . _KID.TargetDown . " char_calls=" . _KID.CharCalls . " char_units=" . _KID.CharUnits
			. " buffered_events=" . Keystats.buffer_events.Length . " text_units=" . StrLen(Keystats.buffer_text)
			. " tokens=" . Tokens . " privacy_hits=" . Keystats.health_privacy_hits . " errors=" . _KSD.Errors . "`n", "*", "UTF-8")
		_KSD_Require(Keystats.health_privacy_hits == 0 && KLHook.capture_queue.Length == 0 && !KLHook.capture_owner,
			"The actual accepted-input drain must finish without privacy drops or retained work.")
		_KSD_Require(Keystats.buffer_events.Length == 1,
			"One delivered native keystroke must produce exactly one canonical typing event.")
		ExpectedToken := _KID.Mode == "packet-lf" ? "`n" : "`t"
		_KSD_Require(Keystats.buffer_events[1][1] == ExpectedToken, "The accepted native keystroke must retain its canonical text/marker identity.")
		_KSD_Require(Keystats.buffer_text == (_KID.Mode == "backspace" ? "" : ExpectedText),
			"The canonical typing buffer cannot duplicate native Enter or Tab text.")
	} finally {
		_KID.Active := false
		SendLevel(PreviousLevel)
		if IsObject(Hook) {
			Hook.Stop()
			_KSD_Require(!Hook.InProgress, "The exact native InputHook must retire before the receiver.")
		}
		OnMessage(0x100, _KID_KeyMessage, 0)
		OnMessage(0x0087, _KPU_DialogCode, 0)
		OnMessage(0x0102, _KPU_CharMessage, 0)
		try _KID.Window.Destroy()
		Keystats.initialized := false
	}
}

if A_Args.Length != 3 || A_Args[3] != "--allow-explicit-owned-edit-unicode-input"
	throw Error("Explicit private receiver native-input opt-in is required.")
if !(A_Args[1] == "packet-lf" || A_Args[1] == "packet-tab")
	throw Error("Unknown native keyboard callback probe.")
global _KSD := {Log: A_Args[2] . "\private.log", Errors: 0, Probes: 0, FlushCalls: 0, LogCalls: 0, Failure: 0}
global _KID := {Mode: A_Args[1], Window: 0, Edit: 0, Active: false, NativeDown: 0, TargetDown: 0,
	CharCalls: 0, CharUnits: "", LastCallback: 0, Failure: 0, ReceiverChars: 0, ReceiverUnits: "", DialogRequests: 0,
	ExpectedVk: 0xE7}
try {
	_KID_Exercise()
	FileAppend("PASS native-keystats " . _KID.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as _KID_EntryFailure {
	FileAppend("FAIL native-keystats " . _KID_EntryFailure.Message . " [" . _KID_EntryFailure.File . ":" . _KID_EntryFailure.Line . "]`n", "*", "UTF-8")
	if FileExist(_KSD.Log)
		FileAppend(FileRead(_KSD.Log, "UTF-8"), "*", "UTF-8")
	ExitApp(1)
}
