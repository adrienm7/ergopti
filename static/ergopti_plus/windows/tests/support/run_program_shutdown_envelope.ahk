; tests/support/run_program_shutdown_envelope.ahk

; Executes extracted production shutdown/reload bodies and actual program
; retirement in an isolated native interpreter. Surrounding owners are explicit
; refusal-envelope doubles; this does not prove physical input or tree retirement.

_RPA_EnvelopeRequire(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_RPA_EnvelopeCount(Name) {
	global _RPA_EnvelopeState
	_RPA_EnvelopeState[Name] := _RPA_EnvelopeState.Get(Name, 0) + 1
	return true
}

class _RPA_EnvelopeHandle {
	__New(Mode) {
		this.Mode := Mode
	}
	terminate() {
		_RPA_EnvelopeCount("terminate")
		if this.Mode == "throw"
			throw Error("exact fixture retirement exception")
		if this.Mode == "settle"
			return true
		return "1"
	}
}

; Timing values are captured from the actual parent driver; source/assignment
; ports below are explicit refusals in this isolated non-configured envelope.
TimingsGet(Section, Key) {
	global _RPA_EnvelopeTimings
	_RPA_EnvelopeRequire(Section == "gestures" && _RPA_EnvelopeTimings.Has(Key),
		"shutdown timer uses only captured native timing keys")
	return _RPA_EnvelopeTimings[Key]
}
ConfigWriteLeaseBusy(*) {
	return false
}
GestureGetActionParameter(*) {
	return ""
}
FSReadUtf8Exact(*) {
	throw Error("shutdown source fixture refuses uncaptured reads")
}

LoggerError(*) {
	return true
}
GestureReleaseLeftClick(*) {
	return _RPA_EnvelopeCount("left")
}
GestureReleaseRightClick(*) {
	return _RPA_EnvelopeCount("right")
}
TapHoldReleaseSyntheticKeys(*) {
	return _RPA_EnvelopeCount("forced-modifier")
}
LLM_NavEventOwner_PrepareShutdown(*) {
	global _RPA_EnvelopeState
	_RPA_EnvelopeRequire(_RPA_EnvelopeState.Get("left", 0) > 0
		&& _RPA_EnvelopeState.Get("right", 0) > 0, "held buttons release before native preflight")
	return _RPA_EnvelopeCount("nav")
}
LLM_NavEventOwner_CancelShutdown(*) {
	return _RPA_EnvelopeCount("nav-cancel")
}
ReloadTerminalHandoffClaim(*) {
	_RPA_EnvelopeCount("claim")
	return false
}
ReloadTerminalHandoffPending(*) {
	return false
}
ConfigTransitionRetainedBarrier(*) {
	return false
}
ConfigWriteAcquireLifecycleBundle(*) {
	return Map("fixture", true)
}
_ConfigWriteTerminalRelease(*) {
	return _RPA_EnvelopeCount("bundle-release")
}
TapHoldShutdownReleaseGate(*) {
	return _RPA_EnvelopeCount("modifier")
}
_ConfigFullSaveSettleTerminal(*) {
	_RPA_EnvelopeCount("full-save")
	return false
}
_Updater_DeferExitIntentRetry(*) {
	return _RPA_EnvelopeCount("exit-retry")
}
_Updater_DeferRecoveryHandoffRetry(*) {
	return _RPA_EnvelopeCount("recovery-retry")
}
UninstallCancel(*) {
	return _RPA_EnvelopeCount("uninstall-cancel")
}
ReloadTerminalHandoffRefuseForShutdown(Reason, Gate) {
	global _RPA_EnvelopeState
	_RPA_EnvelopeRequire(Reason == "Reload", "the current shutdown reason reaches reload compensation")
	_RPA_EnvelopeState["gate"] := Gate
	return _RPA_EnvelopeCount("reload-refuse")
}

_RPA_EnvelopeRun() {
	global _RPA_EnvelopeState, _UserProgramEntries, _UserProgramAcquiring
	global _UserProgramPaused, _UserProgramGeneration, _LifecycleShutdownReason
	global _LifecycleShutdownVetoAttempts, LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS
	global _UserProgramPollOwner
	for Paused in [false, true] {
		Suspend(Paused)
		for Mode in ["acquiring", "throw", "malformed", "later"] {
			_UserProgramEntries := Map()
			_UserProgramAcquiring := Mode == "acquiring" ? Map() : 0
			if Mode == "throw" || Mode == "malformed"
				_UserProgramEntries["gesture__fixture"] := Map("binding", "gesture__fixture",
					"handle", _RPA_EnvelopeHandle(Mode), "cancelled", false)
			try {
				_UserProgramGeneration := 0
				_UserProgramPaused := Paused
				if Mode != "later" {
					_RPA_EnvelopeState := Map()
					ReloadResult := _ReloadPreservingSuspendNonCritical(0, 0, 0, 0)
					_RPA_EnvelopeRequire((ReloadResult is Integer) && ReloadResult == 0,
						"actual reload refuses unretired program debt")
					_RPA_EnvelopeRequire(_UserProgramPaused == Paused,
						"refused reload preserves actual pause posture")
					_RPA_EnvelopeRequire(_UserProgramGeneration == 1,
						"reload preflight actually invalidates program admission")
				}
				_LifecycleShutdownVetoAttempts := 0
				loop LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS {
					_RPA_EnvelopeState := Map()
					_LifecycleShutdownReason := "stale fixture reason"
					BeforeGeneration := _UserProgramGeneration
					Result := Ergopti_OnShutdown("Reload", 0)
					_RPA_EnvelopeRequire((Result is Integer)
						&& Result == (A_Index < LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS ? 1 : 0),
						"actual shutdown must spend its finite veto budget")
					_RPA_EnvelopeRequire(_UserProgramGeneration == BeforeGeneration + 1,
						"actual program retirement runs on each shutdown attempt")
					_RPA_EnvelopeRequire(_UserProgramPaused == Paused && A_IsSuspended == Paused,
						"program and native pause posture survive every refusal")
					_RPA_EnvelopeRequire(_LifecycleShutdownReason == "Reload",
						"program debt cannot precede current reason publication")
					for Name in ["left", "right", "nav", "claim", "modifier", "bundle-release",
							"nav-cancel", "exit-retry", "recovery-retry", "uninstall-cancel"]
						_RPA_EnvelopeRequire(_RPA_EnvelopeState.Get(Name, 0) >= 1,
							"shutdown compensation must run: " . Name)
					_RPA_EnvelopeRequire(_RPA_EnvelopeState.Get("bundle-release", 0) == 1
						&& _RPA_EnvelopeState.Get("nav-cancel", 0) == 1,
						"borrowed ownership is compensated exactly once")
					_RPA_EnvelopeRequire(_RPA_EnvelopeState.Get("full-save", 0) == (Mode == "later" ? 1 : 0),
						"only exact program acknowledgement may reach the next refusal gate")
					if A_Index < LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS {
						_RPA_EnvelopeRequire(_RPA_EnvelopeState.Get("reload-refuse", 0) == 1,
							"honored program debt compensates the pending reload")
						_RPA_EnvelopeRequire(_RPA_EnvelopeState["gate"] == (Mode == "later"
							? "an accepted full configuration save remains non-durable"
							: "a user program tree is still alive"), "refusal reports the exact owner")
					} else
						_RPA_EnvelopeRequire(_RPA_EnvelopeState.Get("forced-modifier", 0) == 1,
							"budget exhaustion reattempts held-input release")
				}
			} finally {
				_UserProgramAcquiring := 0
				for _, Entry in _UserProgramEntries
					Entry["handle"].Mode := "settle"
				CleanupReceipt := ProgramActions_Stop(Paused)
				_RPA_EnvelopeRequire((CleanupReceipt is Integer) && CleanupReceipt == 1,
					"exact controlled program and native callback retire before next mode")
				_RPA_EnvelopeRequire(_UserProgramEntries.Count == 0 && !IsObject(_UserProgramPollOwner),
					"shutdown fixture never abandons a program or timer owner")
			}
		}
	}
	Suspend(false)
}

try {
	_RPA_EnvelopeRun()
	FileAppend("program-shutdown-envelope-ok", "*", "UTF-8-RAW")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message, "**", "UTF-8-RAW")
	ExitApp(1)
}
