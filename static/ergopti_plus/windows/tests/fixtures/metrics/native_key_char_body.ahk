; tests/fixtures/metrics/native_key_char_body.ahk
; Native input is confined to a verified child-owned Edit. No fabricated dual callback.
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
_KID_Up(Ih, Vk, Sc) {
	global _KID
	if !_KID.Active
		return
	try _KID_Target()
	catch Any as Failure {
		_KID.Failure := Failure
		return
	}
	_KID.LastCallback := A_TickCount
	KL_Hook_OnKeyUp(Ih, Vk, Sc)
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
		Hook.OnKeyUp := _KID_Up
		OnMessage(0x100, _KID_KeyMessage)
		_KID.Active := true
		Hook.Start()
		_KSD_Require(Hook.InProgress, "The actual InputHook must own its active native hook.")
		_KID_Target()
		SendLevel(2)
		SendEvent(_KID.Mode == "letter" ? "a" : _KID.Mode == "enter" ? "{Enter}" : _KID.Mode == "tab" ? "{Tab}" : "{Backspace}")
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
		ExpectedText := _KID.Mode == "letter" ? "a" : _KID.Mode == "enter" ? "`n" : _KID.Mode == "tab" ? "`t" : "keep"
		_KSD_Require(StrReplace(_KID.Edit.Value, "`r`n", "`n") == ExpectedText,
			"The exact native input must produce its independently expected receiver contents.")
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
		ExpectedToken := _KID.Mode == "letter" ? "a" : _KID.Mode == "enter" ? "[ENTER]" : _KID.Mode == "tab" ? "[TAB]" : "[BS]"
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
		try _KID.Window.Destroy()
		Keystats.initialized := false
	}
}

if A_Args.Length != 3 || A_Args[3] != "--allow-explicit-owned-edit-sendevent"
	throw Error("Explicit private receiver native-input opt-in is required.")
if !(A_Args[1] == "letter" || A_Args[1] == "enter" || A_Args[1] == "tab" || A_Args[1] == "backspace")
	throw Error("Unknown native keyboard callback probe.")
global _KSD := {Log: A_Args[2] . "\private.log", Errors: 0, Probes: 0, FlushCalls: 0, LogCalls: 0, Failure: 0}
global _KID := {Mode: A_Args[1], Window: 0, Edit: 0, Active: false, NativeDown: 0, TargetDown: 0,
	CharCalls: 0, CharUnits: "", LastCallback: 0, Failure: 0,
	ExpectedVk: A_Args[1] == "letter" ? 0x41 : A_Args[1] == "enter" ? 0x0D : A_Args[1] == "tab" ? 0x09 : 0x08}
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
