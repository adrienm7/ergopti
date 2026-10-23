; tests/fixtures/keepawake_suspend_owner_body.ahk

; ==============================================================================
; MODULE: Keep-Awake Suspend Ownership Child
; DESCRIPTION:
; Composes real Enter with the whole keep-awake implementation and a real
; non-consuming InputHook. Only its first Stop exception is explicitly modeled;
; retry calls the real native Stop. No claim that the OS produced that error.
; ==============================================================================

#Requires AutoHotkey v2.0

global _KASO_World := 0
global UPDATER_CANCEL_REASON_SUSPEND := "suspend"
; The disabled feature branch does not initialize session state. This private
; component owns an idle simulation plus its genuine cancellation observer.
global ActivitySimulation := false, AwakeInputHook := ""
global _ALTGR_KANA_FIXUP := false

_KASO_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_KASO_Pass(Name) {
	global _KASO_World
	_KASO_World.Ports[Name] := _KASO_World.Ports.Get(Name, 0) + 1
	return true
}

; Unrelated desktop teardown ports, explicitly excluded from physical proof.
TapHoldReleaseSyntheticKeys() => _KASO_Pass("tap-hold")
SIHO_StopAll() => _KASO_Pass("input-hooks")
TooltipHide(Tag := "?", Force := false) => _KASO_Pass("tooltip")
LLM_Tooltip_Hide(Accepted := false) => _KASO_Pass("llm-tooltip")
LLM_Engine_LiveStop(Reason := "") => _KASO_Pass("live")
LLM_Engine_CancelTimer() => _KASO_Pass("generation-timer")
LLM_Engine_StopGeneration() => _KASO_Pass("generation")
LLM_OllamaCancelWarmupRetry(ResetBackoff := false) => _KASO_Pass("warmup")
_LLM_PointerWatch_Stop() => _KASO_Pass("pointer")
MF_StopFocusRefresh(NativeCancelFn := 0) => _KASO_Pass("focus")
_Updater_CancelAsyncChecks(Reason := "") => _KASO_Pass("updater")
_Updater_QuiesceSelfUpdateForSuspend() => _KASO_Pass("self-update")
UIASW_Stop(Status := "canceled") => _KASO_Pass("uia")
GestureReleaseLeftClick(*) => _KASO_Pass("left-hold")
GestureReleaseRightClick(*) => _KASO_Pass("right-hold")

_KASO_Log(World, Line) {
	if InStr(Line, "all suspend-bypassing subsystems torn down.")
		World.SuccessLogs += 1
	if InStr(Line, "Could not stop the keep-awake keypress observer; cleanup ownership was retained:")
		World.RefusalLogs += 1
}

_KASO_RefuseStop(World, Hook) {
	World.StopAttempts += 1
	_KASO_Require(Hook == World.Hook, "the controlled refusal must address only the exact native observer")
	throw Error("Explicitly modeled native Stop refusal")
}

_KASO_Main() {
	global _KASO_World, ActivitySimulation, AwakeInputHook, _UserProgramPaused
	_KASO_Require(A_Args.Length == 2, "the private component requires exactly two arguments")
	Mode := A_Args[1]
	_KASO_Require(Mode == "retained" || Mode == "absent" || Mode == "retry", "known authored mode required")
	World := { Ports: Map(), Hook: 0, StopAttempts: 0, SuccessLogs: 0, RefusalLogs: 0 }
	_KASO_World := World
	_KASO_Require(!A_IsSuspended && !ActivitySimulation && !IsObject(AwakeInputHook)
		&& KLPFWorker.jobs.Count == 0, "no simulation or native observer may be borrowed")
	LoggerSetTestSink(_KASO_Log.Bind(World))
	Primary := 0
	try {
		if Mode != "absent" {
			; No cursor movement, cancellation hotkey registration or injected input.
			; Arm the actual observer and enter native pause in one short transaction.
			PreviousCritical := Critical("On")
			try {
				World.Hook := AwakeCreateCancellationHook()
				AwakeInputHook := World.Hook
				World.Hook.Start()
				_KASO_Require(World.Hook is InputHook && World.Hook.InProgress,
					"the prerequisite must be a genuinely armed native observer")
				World.Hook.DefineProp("Stop", {Call: _KASO_RefuseStop.Bind(World)})
				Suspend(true)
			} finally Critical(PreviousCritical)
		} else {
			_KASO_Require(AwakeStopCancellationHook() == 1,
				"real absence is an acknowledgment rather than a false refusal")
			Suspend(true)
		}
		if Mode == "retry" {
			_KASO_Require(!AwakeStopCancellationHook() && AwakeInputHook == World.Hook
				&& World.Hook.InProgress && World.StopAttempts == 1,
				"the actual helper must retain the exact native observer after the modeled exception")
			World.Hook.DeleteProp("Stop")
			_KASO_Require(AwakeStopCancellationHook() == 1 && !World.Hook.InProgress
				&& !IsObject(AwakeInputHook), "the second call must perform the real native Stop")
		}
		Result := Ergopti_OnSuspendEnter()
		Debt := LifecycleTransitionDebtSnapshot("suspend")
		Retained := IsObject(World.Hook) && AwakeInputHook == World.Hook
		Running := IsObject(World.Hook) ? World.Hook.InProgress : false
		FileAppend("RECEIPT keepawake-suspend mode=" . Mode . " result=" . Result
			. " suspended=" . A_IsSuspended . " retained=" . Retained . " running=" . Running
			. " debt=" . Debt.Length . " ports=" . World.Ports.Count
			. " modeled_stop_attempts=" . World.StopAttempts . " refusal_logs=" . World.RefusalLogs
			. " success_logs=" . World.SuccessLogs . "`n", "*")
		_KASO_Require(A_IsSuspended && _UserProgramPaused && !ActivitySimulation
			&& World.Ports.Count == 15 && KLPFWorker.jobs.Count == 0,
			"the genuine complete reactor must reach all fifteen passive unrelated subsystem ports")
		for Name, Count in World.Ports
			_KASO_Require(Count == 1, "each unrelated subsystem port must run exactly once")
		if Mode == "retained" {
			_KASO_Require(World.StopAttempts == 1 && World.RefusalLogs == 1 && Retained && Running,
				"the modeled Stop exception must leave the exact actual hook registered and running")
			_KASO_Require(!Result && Debt.Length == 1 && Debt[1].owner == "keep-awake"
				&& World.SuccessLogs == 0 && LifecycleTransitionNeedsCompensation("suspend"),
				"an unretired keep-awake observer cannot certify completed suspend teardown")
		} else {
			_KASO_Require(Result == 1 && Debt.Length == 0 && World.SuccessLogs == 1
				&& !Retained && !Running && !IsObject(AwakeInputHook),
				"real absence or confirmed native retry permits normal suspend completion")
		}
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(World.Hook) && World.Hook.HasOwnProp("Stop")
				World.Hook.DeleteProp("Stop")
			_KASO_Require(AwakeStopCancellationHook() == 1 && !IsObject(AwakeInputHook),
				"cleanup must obtain the real native hook retirement receipt")
			if IsObject(World.Hook)
				_KASO_Require(!World.Hook.InProgress, "the exact native observer must be stopped before child exit")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			ProgramActions_Stop(false)
			Suspend(false)
			LoggerClearTestSink()
			World.Hook := 0, _KASO_World := 0
		}
	}
	if IsObject(Primary)
		throw Primary
}

try {
	_KASO_Main()
	FileAppend("PASS keepawake-suspend " . A_Args[1] . "`n", "*")
	ExitApp(0)
} catch as Failure {
	FileAppend("FAIL keepawake-suspend type=" . Type(Failure) . " line=" . Failure.Line
		. " reason=" . Failure.Message . "`n", "*")
	ExitApp(1)
}
