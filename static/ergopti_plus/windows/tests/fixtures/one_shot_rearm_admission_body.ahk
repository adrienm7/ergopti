; tests/fixtures/one_shot_rearm_admission_body.ahk

; Run the two real physical routes in distinct native timer threads, while a
; passive hook Wait pumps messages. Keyboard I/O stays behind observers.
global _SharedDir := A_Args[2], _TapHoldOneShotCache := 0
global ScriptInformation := Map("MagicKey", "★"), OneShotShiftEnabled := false
global LayerEnabled := false, CapsWordEnabled := false
global TAPHOLD_DEFAULT_ACTIVATION_SECONDS := 0.2, TAPHOLD_MAX_ACTIVATION_SECONDS := 10
global TAPHOLD_CANCEL_BY_OTHER_KEY := "another key during hold", TAPHOLD_CANCEL_BY_COMBINATION := "first key of a key combination"
global GESTURE_ACTIONS := Map("one_shot_shift", { Fn: OneShotShift })
global TAP_HOLD_TYPING_TAP_ACTIONS := Map("one_shot_shift", true)
global TapHold := Map("keys", Map())
for _OSRA_Key in ["left_alt", "right_ctrl"]
	TapHold["keys"][_OSRA_Key] := Map("enabled", true, "tap_action", "one_shot_shift", "time_activation_seconds", 0.2, "hold_modifier", "", "hold_layer", "")
global _TH_PressesTakenByCombination := Map(), _TH_TapHoldTrackState := Map(), _TH_LastTapHoldCancelReason := ""
global _TapHoldTapInDispatch := ""
global _OSRA := { Mode: A_Args[1], Hooks: [], Emits: [], Activations: 0, Errors: 0,
	TimerCalls: 0, Done: false, Failure: 0, FirstToken: 0, Successor: 0, SuccessorToken: 0, Released: 0, KeyWaits: 0 }

_OSRA_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

LoggerError(Args*) {
	global _OSRA
	_OSRA.Errors += 1
}

LoggerIsDebugEnabled() {
	return false
}

class HookDispatcher {
	static WasWheelSince(Args*) {
		return false
	}
}

KS_IsDown(Name) {
	_OSRA_Require(Name == "SC11D" || Name == "SC03A" || Name == "LShift" || Name == "LCtrl", "only the real LAlt modifier guard may query physical keys")
	return false
}

TapHoldReleasePhysicalKey(Name) {
	global _OSRA
	_OSRA_Require(Name == "LAlt", "the actual first route must release its physical Alt")
	_OSRA.Released += 1
	return true
}

TapHoldSyntheticKeyDown(Name) {
	_OSRA_Require(Name == "LShift", "the real route must reach its Shift hold boundary")
	return false
}

KeyWait(Name, Options) {
	global _OSRA
	_OSRA_Require(Name == "SC11D" && SubStr(Options, 1, 1) == "T" && Number(SubStr(Options, 2)) == 0.2, "the real second route must use its configured tap deadline")
	_OSRA.KeyWaits += 1
	return true
}

ActivateHotstrings() {
	global _OSRA
	_OSRA.Activations += 1
}

SendNewResult(Text, Args*) {
	global _OSRA
	_OSRA.Emits.Push(Text)
}

class _OSRA_Hook {
	__New(Primary := false) {
		this.Primary := Primary, this.Starts := 0, this.Stops := 0, this.Waits := 0
		this.Input := "", this.EndKey := "", this.EndReason := ""
	}
	KeyOpt(Keys, Options) {
		_OSRA_Require(Keys == "{BackSpace}{Enter}{Delete}" && Options == "E", "the real one-shot control end keys must remain unchanged")
	}
	Start() {
		global _OSRA, OneShotShiftEnabled
		this.Starts += 1
		if !this.Primary
			return
		for Token, Record in _SIHO_Owners
			if Record["hook"] == this
				_OSRA.FirstToken := Token
		_OSRA_Require(_OSRA.FirstToken > 0, "Start must run after actual registry publication")
		if _OSRA.Mode == "paused-during-start"
			Suspend(true)
		else if _OSRA.Mode == "revoked-during-start" || _OSRA.Mode == "successor-disabled-during-start" {
			Suspend(true)
			try {
				_OSRA_Require(SIHO_StopAll() == 1, "Start reentry must retire the exact primary hook")
				OneShotShiftFix()
			} finally Suspend(false)
			if _OSRA.Mode == "successor-disabled-during-start" {
				_OSRA.Successor := _OSRA_Hook()
				_OSRA.SuccessorToken := SIHO_StartOwned(_OSRA.Successor, "fresh-one-shot", true)
				_OSRA_Require(_OSRA.SuccessorToken > _OSRA.FirstToken, "the resumed successor must have a new actual identity")
				OneShotShiftFix()
			}
		}
	}
	Wait() {
		global _OSRA
		this.Waits += 1
		if !this.Primary
			throw Error("a refused second hook must never Wait")
		if InStr(_OSRA.Mode, "incumbent-") == 1 {
			SetTimer(_OSRA_SecondTimer, -1)
			Started := A_TickCount
			while !_OSRA.Done && A_TickCount - Started < 3000
				Sleep(5)
			_OSRA_Require(_OSRA.Done, "the first capture must pump the independent second-route timer")
			if IsObject(_OSRA.Failure)
				throw _OSRA.Failure
		}
		if _OSRA.Mode == "incumbent-special"
			this.EndKey := ".", this.EndReason := "EndKey"
		else
			this.Input := "a", this.EndReason := "Max"
	}
	Stop() {
		this.Stops += 1
		if this.EndReason == ""
			this.EndReason := "Stopped"
	}
}

_OSRA_CreateHook(Options, EndKeys) {
	global _OSRA
	_OSRA_Require(InStr(Options, "L1 T") == 1 && InStr(Options, " E") > 0, "the genuine bounded suppressive options must reach the passive factory")
	_OSRA_Require(InStr(EndKeys, ".") > 0 && InStr(EndKeys, "★") > 0, "the real shared table and chosen magic key must populate the capture")
	Hook := _OSRA_Hook(_OSRA.Hooks.Length == 0)
	_OSRA.Hooks.Push(Hook)
	return Hook
}

_OSRA_SecondTimer() {
	global _OSRA, OneShotShiftEnabled, _TH_TapHoldTrackState
	try {
		_OSRA.TimerCalls += 1
		_OSRA_Require(_OSRA_SecondRouteCriterion(), "the distinct RCtrl hotkey must be admitted by its real criterion")
		if _OSRA.Mode == "incumbent-disabled"
			OneShotShiftFix()
		_OSRA_Require(OneShotShiftEnabled == (_OSRA.Mode != "incumbent-disabled"), "the incumbent logical state must be established before the second route")
		_TH_TapHoldTrackState["right_ctrl"] := Map("down_at", A_TickCount, "canceled_by_activity", false)
		_OSRA_SecondRoute()
		_OSRA_Require(_SIHO_Owners.Has(_OSRA.FirstToken) && _SIHO_Owners[_OSRA.FirstToken]["hook"] == _OSRA.Hooks[1], "the refused route must retain the exact first hook")
		_OSRA_Require(OneShotShiftEnabled == (_OSRA.Mode != "incumbent-disabled"), "a refused rearm must preserve the incumbent's enabled or explicitly disabled state")
		_OSRA_Require(TapHoldTapInDispatch() == "" && !_TH_TapHoldTrackState.Has("right_ctrl"), "the genuine dispatcher must restore provenance and consume its own press")
	} catch as Err {
		_OSRA.Failure := Err
	} finally _OSRA.Done := true
}

_OSRA_Run() {
	global _OSRA, OneShotShiftEnabled, _TapHoldOneShotCache
	_OSRA_Require(_OSRA_FirstRouteCriterion() && _OSRA_SecondRouteCriterion(), "both independently registered physical paths must be active")
	if _OSRA.Mode == "busy-other" {
		_OSRA.Successor := _OSRA_Hook()
		_OSRA.SuccessorToken := SIHO_StartOwned(_OSRA.Successor, "dead-key", true)
		_OSRA_Require(_OSRA.SuccessorToken > 0, "the different exclusive owner must really be registered")
	}
	_OSRA_FirstRoute()
	_OSRA_Require(_TapHoldOneShotCache["results"].Count > 0 && _OSRA.Errors == 0, "the actual shared JSON must be loaded without fallback or hidden errors")
	_OSRA_Require(_OSRA.Released == 1, "the real LAlt callback must reach capture after physical release")
	if _OSRA.Mode == "natural" || InStr(_OSRA.Mode, "incumbent-") == 1 {
		Expected := _OSRA.Mode == "incumbent-special" ? " :" : (_OSRA.Mode == "incumbent-disabled" ? "a" : "A")
		_OSRA_Require(_OSRA.Emits.Length == 1 && _OSRA.Emits[1] == Expected, "the admitted capture must emit the independent expected result: " . Expected)
		_OSRA_Require(_OSRA.Activations == (_OSRA.Mode == "incumbent-special" ? 1 : 0), "only the actual special result activates hotstrings")
		_OSRA_Require(_OSRA.Hooks[1].Starts == 1 && _OSRA.Hooks[1].Waits == 1 && _OSRA.Hooks[1].Stops == 1, "the original capture must start, wait and settle exactly once")
		_OSRA_Require(SIHO_Count() == 0, "normal settlement must retire the original registry entry")
		if _OSRA.Mode != "natural" {
			_OSRA_Require(_OSRA.TimerCalls == 1 && _OSRA.KeyWaits == 1 && _OSRA.Hooks.Length == 2, "one separate native timer must run the genuine RCtrl route")
			_OSRA_Require(_OSRA.Hooks[2].Starts == 0 && _OSRA.Hooks[2].Waits == 0 && _OSRA.Hooks[2].Stops == 0, "refused admission must never arm or settle the second hook")
		}
	} else {
		_OSRA_Require(!OneShotShiftEnabled && _OSRA.Emits.Length == 0 && _OSRA.Activations == 0, "a refused or revoked start must not publish a late shift or emit text")
		ExpectedOwners := _OSRA.Mode == "busy-other" || _OSRA.Mode == "successor-disabled-during-start" ? 1 : 0
		_OSRA_Require(SIHO_Count() == ExpectedOwners, "only the exact preexisting or resumed successor may remain")
		if ExpectedOwners
			_OSRA_Require(_SIHO_Owners.Has(_OSRA.SuccessorToken) && _SIHO_Owners[_OSRA.SuccessorToken]["hook"] == _OSRA.Successor, "stale admission cleanup must preserve the successor object and token")
		if _OSRA.Mode == "busy-other"
			_OSRA_Require(_OSRA.Hooks[1].Starts == 0 && _OSRA.Hooks[1].Waits == 0, "busy admission must never start the proposed capture")
		else
			_OSRA_Require(_OSRA.Hooks[1].Starts == 1 && _OSRA.Hooks[1].Stops == 1 && _OSRA.Hooks[1].Waits == 0, "revoked post-Start admission must retire without waiting")
	}
}

try {
	try _OSRA_Run()
	finally {
		SetTimer(_OSRA_SecondTimer, 0)
		try SIHO_StopAll()
		finally Suspend(false)
	}
	FileAppend("PASS one-shot-rearm-admission", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
