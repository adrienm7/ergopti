; tests/fixtures/uia_suspend_worker_debt_body.ahk

; ==============================================================================
; MODULE: UIA Suspend Worker Debt Child
; DESCRIPTION:
; Runs real UIASW_Start, Stop, cleanup and the complete suspend reactor. Process
; start/termination acknowledgments are controlled ports, not native liveness.
; The actual startup timer is canceled before dispatch under inherited Critical.
; ==============================================================================

#Requires AutoHotkey v2.0

global _USWD_World := 0
global UPDATER_CANCEL_REASON_SUSPEND := "suspend"

_USWD_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_USWD_Pass(Name) {
	global _USWD_World
	_USWD_World.Ports[Name] := _USWD_World.Ports.Get(Name, 0) + 1
	return true
}

; Unrelated desktop teardown ports, excluded from native subsystem proof.
TapHoldReleaseSyntheticKeys() => _USWD_Pass("tap-hold")
SIHO_StopAll() => _USWD_Pass("input-hooks")
TooltipHide(Tag := "?", Force := false) => _USWD_Pass("tooltip")
LLM_Tooltip_Hide(Accepted := false) => _USWD_Pass("llm-tooltip")
LLM_Engine_LiveStop(Reason := "") => _USWD_Pass("live")
LLM_Engine_CancelTimer() => _USWD_Pass("generation-timer")
LLM_Engine_StopGeneration() => _USWD_Pass("generation")
LLM_OllamaCancelWarmupRetry(ResetBackoff := false) => _USWD_Pass("warmup")
_LLM_PointerWatch_Stop() => _USWD_Pass("pointer")
MF_StopFocusRefresh(NativeCancelFn := 0) => _USWD_Pass("focus")
_Updater_CancelAsyncChecks(Reason := "") => _USWD_Pass("updater")
_Updater_QuiesceSelfUpdateForSuspend() => _USWD_Pass("self-update")
StopActivitySimulation(Notify := true) => _USWD_Pass("keep-awake")
GestureReleaseLeftClick(*) => _USWD_Pass("left-hold")
GestureReleaseRightClick(*) => _USWD_Pass("right-hold")

class _USWD_Handle {
	__New(World) {
		this.World := World
	}
	start() {
		_USWD_Require(UIASWState.handle == this,
			"the real Start must publish its exact process owner before starting")
		this.World.Starts += 1
		return true
	}
	terminateAsync() {
		_USWD_Require(this == this.World.Handle,
			"controlled termination may address only the exact admitted process owner")
		this.World.Terminations += 1
		return this.World.Accept
	}
}

_USWD_Spawn(World, Executable, Args, Done) {
	_USWD_Require(Executable == A_AhkPath && Args.Length == 6
		&& Args[4] == "--uia-selection-worker" && Args[5] == A_ScriptHwnd,
		"real Start must use the genuine source worker ABI")
	_USWD_Require(Args[6] == UIASWState.worker_generation && HasMethod(Done, "Call"),
		"the exact completion must be bound to the admitted worker generation")
	World.Spawns += 1
	World.Done := Done
	World.Generation := Args[6]
	World.Handle := _USWD_Handle(World)
	return World.Handle
}

_USWD_Timer(World, Callback, Delay) {
	_USWD_Require(Callback == UIASW_RetryTerminationDebt && Delay < 0,
		"only the real cleanup retry callback may be retained")
	World.TimerArms += 1
	World.Retry := Callback
	return true
}

_USWD_Log(World, Line) {
	if InStr(Line, "all suspend-bypassing subsystems torn down.")
		World.SuccessLogs += 1
}

_USWD_ExactDebt(World) {
	return UIASWState.cleanup_debt.Length == 1
		&& UIASWState.cleanup_debt[1] == World.Handle
		&& UIASWState.process_cleanup_debt.Length == 0
}

_USWD_Main() {
	global _USWD_World, _UserProgramPaused
	_USWD_Require(A_Args.Length == 2, "the private component requires exactly two arguments")
	Mode := A_Args[1]
	_USWD_Require(Mode == "retained" || Mode == "absent" || Mode == "retry", "known authored mode required")
	World := {Ports: Map(), Handle: 0, Done: 0, Retry: 0, Accept: false,
		Spawns: 0, Starts: 0, Terminations: 0, TimerArms: 0, SuccessLogs: 0}
	_USWD_World := World
	_USWD_Require(!A_IsSuspended && !IsObject(UIASWState.handle)
		&& !IsObject(UIASWState.pending) && !IsObject(UIASWState.start_deadline_fn)
		&& UIASWState.cleanup_debt.Length == 0 && UIASWState.process_cleanup_debt.Length == 0
		&& !UIASWState.cleanup_draining && !UIASWState.process_cleanup_draining
		&& !UIASWState.cleanup_retry_armed && KLPFWorker.jobs.Count == 0,
		"the child may not borrow an existing worker or cleanup obligation")
	UIASWState.spawn_fn := _USWD_Spawn.Bind(World)
	UIASWState.cleanup_timer_fn := _USWD_Timer.Bind(World)
	LoggerSetTestSink(_USWD_Log.Bind(World))
	Primary := 0
	PreviousCritical := Critical("On")
	try {
		if Mode != "absent" {
			_USWD_Require(UIASW_Start() == 1 && World.Spawns == 1 && World.Starts == 1
				&& UIASWState.handle == World.Handle && IsObject(UIASWState.start_deadline_fn)
				&& UIASWState.worker_process_handle == 0,
				"the real public Start must admit the exact startup process owner")
		} else
			_USWD_Require(!UIASW_Stop("canceled"), "real Stop reports false on complete absence")
		Suspend(true)
		if Mode == "retry" {
			_USWD_Require(!UIASW_Stop("canceled") && _USWD_ExactDebt(World)
				&& UIASWState.cleanup_retry_armed && World.Retry == UIASW_RetryTerminationDebt,
				"the actual refused Stop must retain exact debt and its canonical retry")
			World.Accept := true
			_USWD_Require(World.Retry.Call() == 1 && UIASWState.cleanup_debt.Length == 0
				&& !UIASWState.cleanup_retry_armed, "the real retry must discharge the exact owner")
			_USWD_Require(!UIASW_Stop("canceled"), "absence remains false after successful retry")
		}
		Result := Ergopti_OnSuspendEnter()
		Debt := LifecycleTransitionDebtSnapshot("suspend")
		Retained := IsObject(World.Handle) && _USWD_ExactDebt(World)
		FileAppend("RECEIPT uia-suspend-worker-debt mode=" . Mode . " result=" . Result
			. " suspended=" . A_IsSuspended . " retained=" . Retained . " debt=" . Debt.Length
			. " ports=" . World.Ports.Count . " spawns=" . World.Spawns . " starts=" . World.Starts
			. " termination_requests=" . World.Terminations . " retry_arms=" . World.TimerArms
			. " success_logs=" . World.SuccessLogs . "`n", "*")
		_USWD_Require(A_IsSuspended && _UserProgramPaused && World.Ports.Count == 15
			&& KLPFWorker.jobs.Count == 0, "the real reactor must reach all fifteen unrelated subsystem ports")
		for Name, Count in World.Ports
			_USWD_Require(Count == 1, "every unrelated subsystem port must run exactly once")
		if Mode == "retained" {
			_USWD_Require(Retained && World.Terminations > 0 && World.TimerArms > 0
				&& UIASWState.cleanup_retry_armed && !IsObject(UIASWState.handle)
				&& !IsObject(UIASWState.start_deadline_fn),
				"the exact startup owner must remain reachable through real cleanup debt")
			Generation := UIASWState.worker_generation
			World.Done.Call(0, "", "")
			_USWD_Require(_USWD_ExactDebt(World) && UIASWState.worker_generation == Generation,
				"the retired completion may not erase the exact retained owner")
			_USWD_Require(!Result && Debt.Length == 1 && Debt[1].owner == "uia-selection-worker"
				&& World.SuccessLogs == 0 && LifecycleTransitionNeedsCompensation("suspend"),
				"retained UIA worker cleanup cannot certify completed suspend teardown")
		} else
			_USWD_Require(Result == 1 && Debt.Length == 0 && World.SuccessLogs == 1
				&& !Retained && UIASWState.cleanup_debt.Length == 0,
				"real absence or acknowledged cleanup retry permits normal completion")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			World.Accept := true
			UIASW_Stop("canceled")
			_USWD_Require(UIASW_RetryTerminationDebt() == 1 && UIASWState.cleanup_debt.Length == 0
				&& UIASWState.process_cleanup_debt.Length == 0 && !IsObject(UIASWState.handle)
				&& !IsObject(UIASWState.start_deadline_fn), "all owned worker capabilities must retire")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if UIASWState.handlers_registered {
				OnMessage(0x004A, UIASW_OnCopyData, 0)
				UIASWState.handlers_registered := false
			}
			UIASWState.spawn_fn := 0, UIASWState.cleanup_timer_fn := 0
			World.Done := 0, World.Retry := 0
			if IsObject(World.Handle)
				World.Handle.World := 0
			World.Handle := 0
			ProgramActions_Stop(false)
			Suspend(false)
			LoggerClearTestSink()
			_USWD_World := 0
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
}

try {
	_USWD_Main()
	FileAppend("PASS uia-suspend-worker-debt " . A_Args[1] . "`n", "*")
	ExitApp(0)
} catch as Failure {
	FileAppend("FAIL uia-suspend-worker-debt type=" . Type(Failure) . " line=" . Failure.Line
		. " reason=" . Failure.Message . "`n", "*")
	ExitApp(1)
}
