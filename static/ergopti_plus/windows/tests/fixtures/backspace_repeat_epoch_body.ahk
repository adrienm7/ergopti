; tests/fixtures/backspace_repeat_epoch_body.ahk

; Real extracted public producer, native AHK timer and Suspend lifecycle.
; Physical held-state and output are isolated ports: no physical-key or keyboard
; injection claim, no user's held key, and no native key edge is emitted.
global _BRP := {Mode: A_Args[1], Key: A_Args[3], Held: true, Emits: 0, Interrupts: 0, Done: false,
	Failure: 0, InitialEpoch: _TH_SyntheticEpoch, RetiredEpoch: -1, SuspendedAtOutput: false}
_BRP_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
KS_IsDown(Name) {
	global _BRP
	if Name == (_BRP.Key == "left_alt" ? "SC038" : "SC11D")
		return _BRP.Held
	_BRP_Require(Name == "LShift" || Name == "SC038", "The real repeat branch may only query its own held key and its two modifier guards.")
	return false
}
BackSpaceLogic(ExpectedEpoch := unset) => false
TapHoldEmitKeyTap(Key, Mods := unset) {
	global _BRP
	_BRP_Require(Key == "BackSpace" && !IsSet(Mods), "Only the producer's unmodified synthetic Backspace belongs to this port.")
	_BRP.Emits += 1
	_BRP.SuspendedAtOutput := _BRP.SuspendedAtOutput || A_IsSuspended
	if _BRP.Emits == 1
		SetTimer(_BRP_Interrupt, -1)
	else
		_BRP.Held := false
	return true
}
_BRP_Interrupt() {
	global _BRP, _TH_SyntheticEpoch
	try {
		_BRP.Interrupts += 1
		if _BRP.Mode == "current"
			return
		Suspend(true)
		_BRP_Require(A_IsSuspended, "The private child must really enter native Suspend.")
		_BRP_Require(TapHoldReleaseSyntheticKeys() == true, "The actual empty-ledger lifecycle cleanup must acknowledge retirement.")
		_BRP.RetiredEpoch := _TH_SyntheticEpoch
		_BRP_Require(_BRP.RetiredEpoch == _BRP.InitialEpoch + 1, "Only genuine lifecycle cleanup may advance this probe's epoch.")
		if _BRP.Mode == "resume"
			Suspend(false)
	} catch as Failure {
		_BRP.Failure := Failure
		_BRP.Held := false
	}
}
_BRP_ForceRelease() {
	global _BRP
	_BRP.Held := false
}
_BRP_RunProducer() {
	global _BRP
	try _BRP_Producer()
	catch as Failure
		_BRP.Failure := Failure
	finally _BRP.Done := true
}
_BRP_Main() {
	global _BRP, TapHold, GESTURE_ACTIONS
	_BRP_Require(A_Args.Length == 3 && (_BRP.Key == "left_alt" || _BRP.Key == "right_ctrl")
		&& (_BRP.Mode == "current" || _BRP.Mode == "paused" || _BRP.Mode == "resume"), "The child requires its exact isolated owner and lifecycle mode.")
	_BRP_Require(KEY_REPEAT_INITIAL_DELAY_MS > 20 && KEY_REPEAT_INITIAL_DELAY_MS < 1000
		&& KEY_REPEAT_INTERVAL_MS > 0 && KEY_REPEAT_INTERVAL_MS < 1000, "The actual repeat timing must fit the bounded private owner lifetime.")
	GESTURE_ACTIONS["backspace"] := {Fn: (*) => true}
	for Id in ["left_alt", "right_ctrl"]
		TapHold["keys"][Id]["tap_action"] := "backspace"
	_BRP_Require(_BRP_Criterion(), "The actual public plain-backspace criterion must admit this unmodified configuration.")
	try {
		SetTimer(_BRP_ForceRelease, -1500)
		SetTimer(_BRP_RunProducer, -1)
		Started := A_TickCount
		while !_BRP.Done && A_TickCount - Started < 3000
			Sleep(5)
		if IsObject(_BRP.Failure)
			throw _BRP.Failure
		_BRP_Require(_BRP.Done && _BRP.Interrupts == 1, "The actual producer and independent native lifecycle timer must each settle once.")
		FileAppend("OBSERVATION backspace-repeat-epoch key=" . _BRP.Key . " mode=" . _BRP.Mode
			. " emits=" . _BRP.Emits . " initial_epoch=" . _BRP.InitialEpoch . " retired_epoch=" . _BRP.RetiredEpoch
			. " suspended_output=" . _BRP.SuspendedAtOutput . " done=" . _BRP.Done . "`n", "*")
		_BRP_Require(!_BRP.SuspendedAtOutput, "No output may occur during native Suspend.")
		_BRP_Require(_BRP.Emits == (_BRP.Mode == "current" ? 2 : 1), "A retired repeat frame must not emit again after pause or resume; an unchanged owner must repeat.")
	} finally {
		_BRP.Held := false
		SetTimer(_BRP_RunProducer, 0)
		SetTimer(_BRP_Interrupt, 0)
		SetTimer(_BRP_ForceRelease, 0)
		Suspend(false)
	}
}
try {
	_BRP_Main()
	FileAppend("PASS backspace-repeat-epoch " . _BRP.Key . " " . _BRP.Mode, "*")
	ExitApp(0)
} catch as Failure {
	FileAppend(Failure.Message . "`n" . Failure.Stack, "**")
	ExitApp(1)
}
