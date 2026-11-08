; tests/fixtures/scalar_nontext_receiving_body.ahk

; The real OneShotShift/DeadKey/SIHO owners run unchanged. Native SendEvent input is
; restricted to this child's verified foreground Edit; output transport is passive.
if A_Args.Length != 4 || A_Args[1] != "--allow-explicit-owned-edit-scalar-nontext"
	throw Error("Explicit owned-Edit keyboard input opt-in is required.")
if !(A_Args[2] == "one-shot" || A_Args[2] == "dead-key") || !(A_Args[3] == "letter" || A_Args[3] == "enter" || A_Args[3] == "backspace")
	throw Error("Unknown scalar native receiving probe.")
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 2
global _SharedDir := A_Args[4], _TapHoldOneShotCache := 0, _TH_SyntheticEpoch := 0
global ScriptInformation := Map("MagicKey", Chr(0x2605)), OneShotShiftEnabled := false, InDeadKeySequence := false
global _SNR := {Owner: A_Args[2], Mode: A_Args[3], Window: 0, Edit: 0, Sends: [], Controls: [], Keys: [], Logs: [], Delivered: 0, Failure: 0, ReadyAt: 0, ReadyRetries: 0, Hook: 0}

_SNR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerError(Args*) {
	global _SNR
	_SNR.Logs.Push(Args)
}
ActivateHotstrings(*) => 0
LoggerWarn(Args*) {
	global _SNR
	_SNR.Logs.Push(Args)
}
SendNewResult(Text, Args*) {
	global _SNR
	if Text != ""
		_SNR.Sends.Push(Text)
	return true
}
Send(Keys) {
	global _SNR
	_SNR.Controls.Push(Keys)
}

_SNR_KeyMessage(WParam, LParam, Message, Hwnd) {
	global _SNR
	if IsObject(_SNR.Edit) && Hwnd == _SNR.Edit.Hwnd
		_SNR.Keys.Push(WParam)
}
_SNR_Target() {
	global _SNR
	_SNR_Require(DllCall("GetForegroundWindow", "Ptr") == _SNR.Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == _SNR.Edit.Hwnd
		&& WinGetPID("ahk_id " . _SNR.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Keyboard input must remain confined to the child-owned foreground Edit.")
	for Name in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
		_SNR_Require(!GetKeyState(Name, "P"), "Release physical modifiers before native delivery.")
}
_SNR_Send() {
	global _SNR
	PreviousLevel := A_SendLevel
	try {
		_SNR_Target()
		ExpectedOwner := _SNR.Owner == "one-shot" ? "one-shot-shift" : "dead-key"
		Active := 0
		for Token, Record in _SIHO_Owners {
			if Record["owner"] == ExpectedOwner && Record["hook"].InProgress {
				Active += 1
				_SNR.Hook := Record["hook"]
			}
		}
		if Active == 0 && A_TickCount - _SNR.ReadyAt < 1500 {
			_SNR.ReadyRetries += 1
			SetTimer(_SNR_Send, -5)
			return
		}
		_SNR_Require(Active == 1, "Original input requires the exact admitted, InProgress scalar hook within the bounded readiness window.")
		SendLevel(0)
		SendEvent(_SNR.Mode == "letter" ? "a" : (_SNR.Mode == "enter" ? "{Enter}" : "{BackSpace}"))
		_SNR.Delivered += 1
	} catch as Err {
		_SNR.Failure := Err
		SIHO_StopAll()
	} finally {
		SendLevel(PreviousLevel)
	}
}
_SNR_Main() {
	global _SNR
	_SNR.Window := Gui(, "Ergopti scalar native receiving probe")
	_SNR.Edit := _SNR.Window.AddEdit("w320 r3", _SNR.Mode == "backspace" ? "keepX" : "")
	try {
		_SNR.Window.Show()
		WinActivate("ahk_id " . _SNR.Window.Hwnd)
		_SNR_Require(WinWaitActive("ahk_id " . _SNR.Window.Hwnd, , 2), "The private target must acquire focus.")
		_SNR.Edit.Focus()
		_SNR_Target()
		DllCall("SendMessageW", "Ptr", _SNR.Edit.Hwnd, "UInt", 0xB1, "Ptr", -1, "Ptr", -1)
		OnMessage(0x100, _SNR_KeyMessage)
		; Production boot prewarms both canonical tables before capture can run.
		; The isolated child must do the same before arming original injection.
		_SIHO_ScalarEndKeys()
		_TapHoldOneShotTable()
		_SNR.ReadyAt := A_TickCount
		SetTimer(_SNR_Send, -1)
		if _SNR.Owner == "one-shot"
			OneShotShift()
		else
			DeadKey(Map("a", Chr(0x00E4), " ", Chr(0x00A8)))
		if IsObject(_SNR.Failure)
			throw _SNR.Failure
		Sleep(30)
		_SNR_Target()
		_SNR_Require(_SNR.Delivered == 1, "One native batch must reach the genuine scalar capture.")
		FileAppend("OBSERVATION scalar-nontext owner=" . _SNR.Owner . " mode=" . _SNR.Mode . " original_keydowns=" . _SNR.Keys.Length
			. " ready_retries=" . _SNR.ReadyRetries . " end_reason=" . (IsObject(_SNR.Hook) ? _SNR.Hook.EndReason : "none")
			. " end_key=" . (IsObject(_SNR.Hook) ? _SNR.Hook.EndKey : "none") . " first_output=" . (_SNR.Sends.Length ? _SNR.Sends[1] : "none")
			. " first_control=" . (_SNR.Controls.Length ? _SNR.Controls[1] : "none") . " edit_length=" . StrLen(_SNR.Edit.Value) . " outputs=" . _SNR.Sends.Length . " controls=" . _SNR.Controls.Length . "`n", "*")
		ExpectedKey := _SNR.Mode == "letter" ? "a" : (_SNR.Mode == "enter" ? "Enter" : "Backspace")
		if _SNR.Owner == "one-shot" {
			Expected := _SNR.Mode == "letter" ? "A" : "{" . ExpectedKey . "}"
			_SNR_Require(_SNR.Sends.Length == 1 && _SNR.Sends[1] == Expected && _SNR.Controls.Length == 0,
				"The actual one-shot owner must admit its one expected output.")
		} else {
			Expected := _SNR.Mode == "letter" ? Chr(0x00E4) : Chr(0x00A8)
			_SNR_Require(_SNR.Sends.Length >= 1 && _SNR.Sends[1] == Expected,
				"The actual dead-key owner must admit its mapped letter or base character.")
			; The ending control is replayed through the result sender, with its
			; held modifiers, as OneShotShift does (OSW-001).
			_SNR_Require(_SNR.Sends.Length == (_SNR.Mode == "letter" ? 1 : 2) && _SNR.Controls.Length == 0,
				"The actual dead-key control replay must be retained exactly once.")
			if _SNR.Mode != "letter"
				_SNR_Require(_SNR.Sends[2] == "{" . ExpectedKey . "}", "The consumed named key must be replayed unchanged.")
		}

		_SNR_Require(_SNR.Keys.Length == 0, "The original unmodified key must be suppressed before its scalar replay.")
		_SNR_Require(_SNR.Edit.Value == (_SNR.Mode == "backspace" ? "keepX" : ""),
			"The captured original key must not modify the owned Edit before scalar output.")
		_SNR_Require(SIHO_Count() == 0 && _SNR.Logs.Length == 0, "The actual capture must settle without hidden registry errors.")
	} finally {
		SetTimer(_SNR_Send, 0)
		try SIHO_StopAll()
		finally {
			OnMessage(0x100, _SNR_KeyMessage, 0)
			_SNR.Window.Destroy()
		}
	}
}
try {
	_SNR_Main()
	FileAppend("PASS scalar-nontext " . _SNR.Owner . " " . _SNR.Mode, "*")
	ExitApp(0)
} catch as MainErr {
	FileAppend(MainErr.Message . "`n" . MainErr.Stack, "**")
	ExitApp(1)
}
