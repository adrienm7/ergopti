; tests/fixtures/suspend_prefetch_receipt_body.ahk

; ==============================================================================
; MODULE: Suspend Prefetch Receipt Composition Child
; DESCRIPTION:
; Calls real Ergopti_OnSuspendEnter and real KLPF request/cancel/retry owners.
; Passive subsystem ports explicitly exclude their physical teardown from this
; component proof. A false process receipt is uncertainty, not an alive claim.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LCPC_World := 0
; This constant belongs to the passive updater port, not a loaded updater.
global UPDATER_CANCEL_REASON_SUSPEND := "suspend"

_LCPC_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_LCPC_Pass(Name) {
	global _LCPC_World
	_LCPC_World.Ports[Name] := _LCPC_World.Ports.Get(Name, 0) + 1
	return true
}

; Explicit ports for unrelated teardown only. No production reactor, ledger,
; navigation, program, filesystem, request or cancellation body is copied.
TapHoldReleaseSyntheticKeys() => _LCPC_Pass("tap-hold")
SIHO_StopAll() => _LCPC_Pass("input-hooks")
TooltipHide(Tag := "?", Force := false) => _LCPC_Pass("tooltip")
LLM_Tooltip_Hide(Accepted := false) => _LCPC_Pass("llm-tooltip")
LLM_Engine_LiveStop(Reason := "") => _LCPC_Pass("live")
LLM_Engine_CancelTimer() => _LCPC_Pass("generation-timer")
LLM_Engine_StopGeneration() => _LCPC_Pass("generation")
LLM_OllamaCancelWarmupRetry(ResetBackoff := false) => _LCPC_Pass("warmup")
_LLM_PointerWatch_Stop() => _LCPC_Pass("pointer")
MF_StopFocusRefresh(NativeCancelFn := 0) => _LCPC_Pass("focus")
_Updater_CancelAsyncChecks(Reason := "") => _LCPC_Pass("updater")
_Updater_QuiesceSelfUpdateForSuspend() => _LCPC_Pass("self-update")
UIASW_Stop(Status := "canceled") => _LCPC_Pass("uia")
StopActivitySimulation(Notify := true) => _LCPC_Pass("keep-awake")
GestureReleaseLeftClick(*) => _LCPC_Pass("left-hold")
GestureReleaseRightClick(*) => _LCPC_Pass("right-hold")

class _LCPC_Handle {
	__New(World, Done) {
		this.World := World, this.Done := Done
	}
	start() {
		this.World.Starts += 1
		return true
	}
	terminate() {
		this.World.Terminations += 1
		return this.World.AllowRetirement
	}
}

_LCPC_Spawn(World, Executable, Args, Done) {
	_LCPC_Require(Executable == A_AhkPath && Args is Array && Args.Length == (World.Client == "range:typing" ? 18 : 15),
		"the actual request must provide its process ABI")
	_LCPC_Require(Args[4] == "--keylogger-prefetch-worker" && Args[5] == (World.Client == "apps" ? "apps" : "typing")
		&& Args[6] == World.Directory && Args[7] == (World.Client == "range:typing" ? "range" : "full"),
		"the actual client and mode must own the request")
	for Arg in Args
		_LCPC_Require(Arg is String, "every real worker argument must be a string")
	World.Spawns += 1
	World.Handle := _LCPC_Handle(World, Done)
	return World.Handle
}

_LCPC_Schedule(World, Callback, Delay) {
	global _KLPF_CLEANUP_TIMER
	World.Timers.Push({ Callback: Callback, Delay: Delay, Token: _KLPF_CLEANUP_TIMER })
	return true
}

_LCPC_Terminal(World, Status, Stage) {
	World.Terminals.Push(Status)
	World.TerminalStages.Push(Stage)
}

_LCPC_Log(World, Line) {
	if InStr(Line, "all suspend-bypassing subsystems torn down.")
		World.SuccessLogs += 1
}

_LCPC_AssertRetained(World, Job) {
	global _KLPF_CLEANUP_TIMER
	_LCPC_Require(KLPFWorker.jobs.Has(World.Client) && KLPFWorker.jobs[World.Client] == Job,
		"uncertain retirement retains the exact reserved job")
	_LCPC_Require(Job["handle"] == World.Handle && Job.Get("cancel_requested", false)
		&& Job.Get("terminal_claimed", false) && Job.Get("cancel_retry_pending", false),
		"the actual cancellation must retain its exact handle and retry debt")
	_LCPC_Require(FSStrictExists(Job["stage"]) && World.Terminals.Length == 0
		&& World.Terminations == 1, "no stage or terminal can retire without a strict receipt")
	_LCPC_Require(World.Timers.Length == 1 && _KLPF_CLEANUP_TIMER is Map
		&& _KLPF_CLEANUP_TIMER["callback"] == World.Timers[1].Callback
		&& World.Timers[1].Delay == -KLPF_CLEANUP_RETRY_MS,
		"one exact canonical cleanup callback must own the retry")
}

_LCPC_Retry(World, Job) {
	global _KLPF_CLEANUP_TIMER, _KLPF_CLEANUP_DEBTS
	World.AllowRetirement := true
	_LCPC_Require(World.Timers[1].Callback.Call(), "the actual cleanup callback must accept the later receipt")
	_LCPC_Require(KLPFWorker.jobs.Count == 0 && !FSStrictExists(Job["stage"])
		&& World.Terminations == 2 && World.Terminals.Length == 1 && World.Terminals[1] == "canceled"
		&& World.TerminalStages.Length == 1 && World.TerminalStages[1] == "",
		"retry must physically retire this fixture's stage and deliver one real terminal")
	_LCPC_Require(!IsObject(_KLPF_CLEANUP_TIMER) && _KLPF_CLEANUP_DEBTS.Count == 0,
		"the exact target cleanup debts must be discharged")
	_LCPC_Require(!World.Timers[1].Callback.Call() && World.Terminations == 2,
		"the retired cleanup token cannot retry the handle again")
	World.Handle.Done.Call(0, "", "")
	_LCPC_Require(KLPFWorker.jobs.Count == 0 && World.Terminals.Length == 1,
		"a late real worker completion cannot resurrect the canceled owner")
}

_LCPC_Main() {
	global _LCPC_World, _ConfigDir, _UserProgramPaused
	global _KLPF_CLEANUP_TIMER, _KLPF_CLEANUP_DEBTS
	_LCPC_Require(A_Args.Length == 4, "the private component requires exactly four arguments")
	Client := A_Args[1], Mode := A_Args[2], Directory := A_Args[3]
	_LCPC_Require(Client == "typing" || Client == "apps" || Client == "range:typing", "known client required")
	_LCPC_Require(Mode == "absent" || Mode == "retained" || Mode == "retry-ack", "known authored mode required")
	World := { Client: Client, Mode: Mode, Directory: Directory, Ports: Map(), Timers: [], Terminals: [], TerminalStages: [],
		Spawns: 0, Starts: 0, Terminations: 0, SuccessLogs: 0, Handle: 0, AllowRetirement: false }
	_LCPC_World := World
	_ConfigDir := Directory
	TimingsLoadShared(A_Args[4])
	KeyloggerWalkerLoadTimings()
	LoggerSetTestSink(_LCPC_Log.Bind(World))
	_LCPC_Require(!A_IsSuspended && KLPFWorker.jobs.Count == 0 && _KLPF_CLEANUP_DEBTS.Count == 0
		&& !IsObject(_KLPF_CLEANUP_TIMER), "the child may not borrow a worker or cleanup timer")
	KLPFWorker.spawn_fn := _LCPC_Spawn.Bind(World)
	KLPFWorker.cleanup_schedule_fn := _LCPC_Schedule.Bind(World)
	Job := 0, Primary := 0
	try {
		if Mode != "absent" {
			Terminal := _LCPC_Terminal.Bind(World)
			if Client == "range:typing" {
				Query := Map("apps", [], "start_date", "2026-01-01", "end_date", "2026-01-02")
				Requested := KLPF_RequestRange("typing", Directory, Query, 71, Terminal)
			} else
				Requested := KLPF_RequestBuild(Client, Directory, "full", 71, Terminal)
			_LCPC_Require(Requested && World.Spawns == 1 && World.Starts == 1 && KLPFWorker.jobs.Has(Client),
				"the genuine scheduler must reserve and start the exact target")
			Job := KLPFWorker.jobs[Client]
			_LCPC_Require(Job["handle"] == World.Handle && !Job.Get("terminal_claimed", false),
				"the worker transport must be the real published reservation")
			_LCPC_Require(FSWriteCreateDurable(Job["stage"], "owned cancellation stage") == 1,
				"the fixture's exact stage requires an exclusive durable creation receipt")
		} else
			_LCPC_Require(KLPF_CancelBuild(Client) == 1, "absence is a true acknowledgment, not false debt")
		Suspend(true)
		if Mode == "retry-ack" {
			_LCPC_Require(!KLPF_CancelBuild(Client), "the first real process receipt must refuse retirement")
			_LCPC_AssertRetained(World, Job)
			_LCPC_Retry(World, Job)
		}
		Result := Ergopti_OnSuspendEnter()
		Debt := LifecycleTransitionDebtSnapshot("suspend")
		ExpectedOwner := Client == "range:typing" ? "keylogger-prefetch-range" : "keylogger-prefetch-" . Client
		Retained := IsObject(Job) && KLPFWorker.jobs.Has(Client) && KLPFWorker.jobs[Client] == Job
		FileAppend("RECEIPT suspend-prefetch " . Client . " " . Mode
			. " result=" . Result . " native_suspended=" . A_IsSuspended . " retained=" . Retained
			. " debt=" . Debt.Length . " ports=" . World.Ports.Count . " spawns=" . World.Spawns
			. " starts=" . World.Starts . " terminate_calls=" . World.Terminations
			. " terminals=" . World.Terminals.Length . " retry_callbacks=" . World.Timers.Length
			. " success_logs=" . World.SuccessLogs . "`n", "*")
		_LCPC_Require(A_IsSuspended && _UserProgramPaused && World.Ports.Count == 16,
			"real suspend entry must pass all sixteen explicit unrelated subsystem ports")
		for Name, Count in World.Ports
			_LCPC_Require(Count == 1, "each unrelated subsystem port must be called exactly once")
		if Mode == "retained" {
			_LCPC_AssertRetained(World, Job)
			_LCPC_Require(!Result && Debt.Length == 1 && Debt[1].owner == ExpectedOwner,
				"the real suspend transaction cannot finish while its target retirement remains unacknowledged")
			_LCPC_Require(LifecycleTransitionNeedsCompensation("suspend") && World.SuccessLogs == 0,
				"an uncertain worker forbids the all-owners-quiescent success claim")
			_LCPC_Retry(World, Job)
		} else {
			_LCPC_Require(Result == 1 && Debt.Length == 0 && World.SuccessLogs == 1,
				"true absence or confirmed retirement permits normal suspend completion")
			_LCPC_Require(!LifecycleTransitionNeedsCompensation("suspend") && KLPFWorker.jobs.Count == 0,
				"a fully acknowledged transition leaves no invented compensation debt")
		}
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			World.AllowRetirement := true
			_LCPC_Require(KLPF_CancelAll() == 1 && KLPFWorker.jobs.Count == 0,
				"cleanup must obtain strict logical retirement of the private passive worker")
			if IsObject(_KLPF_CLEANUP_TIMER)
				_LCPC_Require(World.Timers[World.Timers.Length].Callback.Call(),
					"the exact armed cleanup token must drain before child exit")
			_LCPC_Require(_KLPF_CLEANUP_DEBTS.Count == 0 && !IsObject(_KLPF_CLEANUP_TIMER),
				"no target file or retry owner may survive cleanup")
			if IsObject(Job)
				_LCPC_Require(!FSStrictExists(Job["stage"]), "the exact private stage must be gone")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			Suspend(false)
			ProgramActions_Stop(false)
			KLPFWorker.spawn_fn := 0, KLPFWorker.cleanup_schedule_fn := 0
			LoggerClearTestSink()
			if IsObject(World.Handle) {
				World.Handle.Done := 0, World.Handle.World := 0
				World.Handle := 0
			}
			for Timer in World.Timers
				if Timer.Token is Map && Timer.Token.Has("callback")
					Timer.Token.Delete("callback")
			World.Timers := [], _LCPC_World := 0
		}
	}
	if IsObject(Primary)
		throw Primary
}

try {
	_LCPC_Main()
	FileAppend("PASS suspend-prefetch " . A_Args[1] . " " . A_Args[2] . "`n", "*")
	ExitApp(0)
} catch as Failure {
	FileAppend("FAIL suspend-prefetch type=" . Type(Failure) . " line=" . Failure.Line
		. " reason=" . Failure.Message . "`n", "*")
	ExitApp(1)
}
