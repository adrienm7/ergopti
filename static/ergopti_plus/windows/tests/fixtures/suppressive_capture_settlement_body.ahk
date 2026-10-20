; tests/fixtures/suppressive_capture_settlement_body.ahk

; The real capture functions and registry run with a passive InputHook object.
; No hook is armed and both emitters are observers only. Stop preserves a
; completed reason, matching native InputHook; a live capture ends as Stopped.
global _SharedDir := A_Args[3], _TapHoldOneShotCache := 0
global ScriptInformation := Map("MagicKey", "★")
global OneShotShiftEnabled := false, InDeadKeySequence := false
global _SIC_Mode := A_Args[2], _SIC_Emits := [], _SIC_Activations := 0
global _SIC_Hook := 0, _SIC_Successor := 0, _SIC_SuccessorToken := 0

_SIC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

LoggerError(Args*) {
}

ActivateHotstrings() {
	global _SIC_Activations
	_SIC_Activations += 1
}

SendNewResult(Text, Args*) {
	global _SIC_Emits
	_SIC_Emits.Push(Text)
}

Send(Keys) {
	global _SIC_Emits
	_SIC_Emits.Push(Keys)
}

class _SIC_CaptureHook {
	__New(Mode) {
		this.Mode := Mode
		this.Input := Mode == "text" || Mode == "completed-revoked" || Mode == "stop-reentrant" || Mode == "stop-refusal" ? "a" : ""
		this.EndKey := Mode == "end-key" ? "Enter" : ""
		this.EndReason := Mode == "timeout" ? "Timeout" : (Mode == "end-key" ? "EndKey" : "Max")
		if Mode == "stopped-resumed"
			this.EndReason := ""
		this.Starts := 0, this.Stops := 0
	}
	KeyOpt(Keys, Options) {
		_SIC_Require(Keys == "{BackSpace}{Enter}{Delete}" && Options == "E", "one-shot keeps its real control end keys")
	}
	Start() {
		this.Starts += 1
	}
	Wait() {
		if this.Mode == "stopped-resumed" || this.Mode == "completed-revoked"
			_SIC_Revoke(this.Mode == "completed-revoked")
	}
	Stop() {
		this.Stops += 1
		if this.Mode == "stop-refusal" && this.Stops == 1
			throw Error("injected native Stop refusal")
		if this.Mode == "stop-reentrant" && this.Stops == 1
			_SIC_Revoke(false)
		if this.EndReason == ""
			this.EndReason := "Stopped"
	}
}

InputHook(Options, EndKeys := "") {
	global _SIC_Hook, _SIC_Mode
	_SIC_Require(InStr(Options, "L1") > 0 && InStr(Options, "T") > 0, "the real bounded capture options must reach the constructor")
	_SIC_Hook := _SIC_CaptureHook(_SIC_Mode)
	return _SIC_Hook
}

_SIC_Revoke(WithSuccessor) {
	global OneShotShiftEnabled, _SIC_Successor, _SIC_SuccessorToken
	; Use the actual lifecycle registry, not a fabricated ownership boolean.
	Suspend(true)
	try {
		_SIC_Require(SIHO_StopAll() == 1, "lifecycle must retire the exact pending capture")
		OneShotShiftEnabled := false
	} finally Suspend(false)
	if WithSuccessor {
		_SIC_Successor := _SIC_CaptureHook("text")
		_SIC_SuccessorToken := SIHO_StartOwned(_SIC_Successor, "fresh-capture", true)
		_SIC_Require(_SIC_SuccessorToken > 0, "a fresh resumed capture must acquire its own identity")
		OneShotShiftEnabled := true
	}
}

_SIC_Run() {
	global _SIC_Hook, _SIC_Mode, _SIC_Emits, _SIC_Activations, OneShotShiftEnabled
	global _SIC_Successor, _SIC_SuccessorToken, InDeadKeySequence
	Owner := A_Args[1]
	if Owner == "one-shot"
		OneShotShift()
	else {
		_SIC_Require(Owner == "dead-key", "the authored capture owner must be known")
		DeadKey(Map("a", "ä", " ", "¨"))
	}
	_SIC_Require(_SIC_Hook.Starts == 1, "the real capture must start exactly once")
	_SIC_Require(_SIC_Hook.Stops == (_SIC_Mode == "stop-reentrant" ? 2 : 1), "only the exact terminal or lifecycle cleanup may stop the capture")
	_SIC_Require(!A_IsSuspended && !InDeadKeySequence, "capture unwind must leave resumed and clear its own sequence flag")
	Expected := []
	if _SIC_Mode == "text"
		Expected := [Owner == "one-shot" ? "A" : "ä"]
	else if _SIC_Mode == "end-key"
		Expected := Owner == "one-shot" ? ["{Enter}"] : ["¨", "", "{Enter}"]
	else if _SIC_Mode == "timeout" && Owner == "dead-key"
		Expected := ["¨"]
	_SIC_Require(_SIC_Emits.Length == Expected.Length, "only a settled current capture may emit, including an empty send")
	for Index, Text in Expected
		_SIC_Require(_SIC_Emits[Index] == Text, "the genuine capture result must remain exact at " . Index)
	_SIC_Require(_SIC_Activations == 0, "none of these controls should activate a special-character hotstring")
	ExpectedOwners := _SIC_Mode == "stop-refusal" || _SIC_Mode == "completed-revoked" ? 1 : 0
	_SIC_Require(SIHO_Count() == ExpectedOwners, "only a refused cleanup or fresh successor may remain owned")
	if _SIC_Mode == "completed-revoked" {
		_SIC_Require(_SIHO_Owners.Has(_SIC_SuccessorToken), "the stale finally must retain the successor's exact token")
		_SIC_Require(OneShotShiftEnabled, "the stale finally must not clear a successor's logical shift")
	}
	if _SIC_Mode == "stopped-resumed"
		_SIC_Require(_SIC_Hook.EndReason == "Stopped" && _SIC_Hook.Input == "", "the stopped empty capture is distinct from timeout")
	SIHO_StopAll()
	_SIC_Require(SIHO_Count() == 0, "the child must retire every exact hook before completion")
}

try {
	_SIC_Run()
	FileAppend("PASS suppressive-capture-settlement", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
