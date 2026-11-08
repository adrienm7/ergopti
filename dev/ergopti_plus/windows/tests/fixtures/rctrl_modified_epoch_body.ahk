; tests/fixtures/rctrl_modified_epoch_body.ahk

; The real public RCtrl branch and complete real TextPressKey transaction send
; native keys only into this child's private Edit. Physical held-state and the
; post-commit logger are ports; no physical-key provenance is claimed.
global TEXT_SENDER_SEND_LEVEL := 0
; A real supported setting selects the transaction's reset path, whose actual
; post-commit logger is interruptible. No transaction/effect function is stubbed.
global HSE_ArrowResetsWord := true, HSE_ShortcutResetsWord := true, HSE_TapHoldResetsWord := true
global _RMP := {Mode: A_Args[1], Key: A_Args[3], Window: 0, Edit: 0, Payloads: [], Finishes: [], Interrupts: 0,
	Done: false, InterruptDone: false, Failure: 0, InitialEpoch: _TH_SyntheticEpoch, RetiredEpoch: -1}
global _AHK_SendInput := _RMP_Send
_RMP_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
KS_IsDown(Name) {
	global _RMP
	_RMP_Require(Name == "LShift" || Name == "Shift" || Name == "SC038" || Name == "SC11D", "Only the actual modified branches' modifier guards belong to this port")
	return Name == (_RMP.Key == "left_alt" ? "SC11D" : "SC038")
}
; The child owns no user LCtrl; this is the second isolated held-state port.
TapHoldUserLCtrlHeld() => false
TapHoldEmitKeyTap(*) {
	throw Error("The modified route must not enter its unmodified repeat branch")
}
LoggerDebug(Tag, Message, Args*) {
	global _RMP
	_RMP_Require(Tag == "HotstringBuffers", "Only the real effect-finisher log belongs to this port")
	_RMP.Finishes.Push(A_IsCritical)
	if _RMP.Payloads.Length != 1 || _RMP.Payloads[1] != "{Right}"
		return
	_RMP_Require(!A_IsCritical, "The native lifecycle timer must interrupt only the actual post-send finish boundary")
	SetTimer(_RMP_Interrupt, -1)
	Started := A_TickCount
	while !_RMP.InterruptDone && A_TickCount - Started < 2000
		Sleep(5)
	_RMP_Require(_RMP.InterruptDone, "The reached logger callout must settle its independent native lifecycle timer")
}
_RMP_Target() {
	global _RMP
	_RMP_Require(DllCall("GetForegroundWindow", "Ptr") == _RMP.Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == _RMP.Edit.Hwnd
		&& WinGetPID("ahk_id " . _RMP.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Every key must reach only the child-owned foreground Edit")
}
_RMP_Send(Keys) {
	global _RMP
	_RMP_Target()
	_RMP_Require(A_IsCritical, "Each native key must be admitted through the real HS transaction")
	_RMP.Payloads.Push(Keys)
	SendInput(Keys)
}
_RMP_Interrupt() {
	global _RMP, _TH_SyntheticEpoch
	try {
		_RMP.Interrupts += 1
		if _RMP.Mode == "current"
			return
		Suspend(true)
		_RMP_Require(A_IsSuspended, "The private child must really enter native Suspend")
		_RMP_Require(TapHoldReleaseSyntheticKeys() == true, "The actual empty-ledger cleanup must acknowledge retirement")
		_RMP.RetiredEpoch := _TH_SyntheticEpoch
		_RMP_Require(_RMP.RetiredEpoch == _RMP.InitialEpoch + 1, "Only the real lifecycle cleanup may advance the epoch")
		if _RMP.Mode == "resume"
			Suspend(false)
	} catch as Failure {
		_RMP.Failure := Failure
	} finally _RMP.InterruptDone := true
}
_RMP_RunProducer() {
	global _RMP
	try _BRP_Producer()
	catch as Failure
		_RMP.Failure := Failure
	finally _RMP.Done := true
}
_RMP_Main() {
	global _RMP, TapHold, GESTURE_ACTIONS, _OSRA
	_RMP_Require(A_Args.Length == 3 && (_RMP.Key == "right_ctrl" || _RMP.Key == "left_alt")
		&& (_RMP.Mode == "current" || _RMP.Mode == "paused" || _RMP.Mode == "resume"), "The exact native owner and lifecycle mode are required")
	GESTURE_ACTIONS["backspace"] := {Fn: (*) => true}
	TapHold["keys"][_RMP.Key]["tap_action"] := "backspace"
	Peer := _RMP.Key == "left_alt" ? "right_ctrl" : "left_alt"
	TapHold["keys"][Peer]["tap_action"] := "one_shot_shift"
	_RMP_Require(_BRP_Criterion(), "The real public backspace route must admit this configuration")
	_RMP.Window := Gui(, "Ergopti isolated RCtrl output owner")
	_RMP.Edit := _RMP.Window.AddEdit("w320 r2", "abc")
	try {
		_RMP.Window.Show()
		WinActivate("ahk_id " . _RMP.Window.Hwnd)
		_RMP_Require(WinWaitActive("ahk_id " . _RMP.Window.Hwnd, , 2), "The exact private native receiver must become foreground")
		_RMP.Edit.Focus()
		SendMessage(0xB1, 0, 0, _RMP.Edit.Hwnd)
		_RMP_Target()
		SetTimer(_RMP_RunProducer, -1)
		Started := A_TickCount
		while !_RMP.Done && A_TickCount - Started < 4000
			Sleep(5)
		if IsObject(_RMP.Failure)
			throw _RMP.Failure
		_RMP_Require(_RMP.Done && _RMP.Interrupts == 1, "The actual public producer and independent lifecycle timer must settle exactly once")
		; Drain the private window's actual key messages before reading its text.
		Sleep(30)
		Actual := _RMP.Edit.Value
		FileAppend("OBSERVATION rctrl-modified-epoch key=" . _RMP.Key . " mode=" . _RMP.Mode . " sends=" . _RMP.Payloads.Length
			. " first=" . (_RMP.Payloads.Length ? _RMP.Payloads[1] : "") . " text=" . Actual
			. " initial_epoch=" . _RMP.InitialEpoch . " retired_epoch=" . _RMP.RetiredEpoch
			. " finishes=" . _RMP.Finishes.Length . " errors=" . _OSRA.Errors . "`n", "*")
		_RMP_Require(_OSRA.Errors == 0 && _RMP.Payloads.Length >= 1 && _RMP.Payloads[1] == "{Right}", "The first native caret move must genuinely succeed")
		Expected := _RMP.Mode == "current" ? 2 : 1
		_RMP_Require(_RMP.Payloads.Length == Expected, "A retired RCtrl frame must not send its second key after native pause or resume")
		_RMP_Require(Actual == (_RMP.Mode == "current" ? "bc" : "abc"), "Only an unretired invocation may delete the child-owned first character")
	} finally {
		SetTimer(_RMP_RunProducer, 0)
		SetTimer(_RMP_Interrupt, 0)
		Suspend(false)
		_RMP.Window.Destroy()
	}
}
try {
	_RMP_Main()
	FileAppend("PASS rctrl-modified-epoch " . _RMP.Mode, "*")
	ExitApp(0)
} catch as Failure {
	FileAppend(Failure.Message . "`n" . Failure.Stack, "**")
	ExitApp(1)
}
