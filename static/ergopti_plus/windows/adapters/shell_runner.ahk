; adapters/shell_runner.ahk

; ==============================================================================
; MODULE: ShellRunner Adapter (AutoHotkey)
; DESCRIPTION:
; Wraps RunWait (synchronous shell) and Run + SetTimer polling (async subprocess)
; behind a stable adapter surface so domain modules can execute shell commands
; and spawn subprocesses without a direct dependency on those AHK primitives.
;
; FEATURES & RATIONALE:
; 1. ShellRunner_Exec(): synchronous shell execution via RunWait + temp file.
;    Returns the stdout string. Best-effort — failures return "".
; 2. ShellRunner_Spawn(): async subprocess via native process-handle polling. Calls
;    OnDone(exit_code, stdout, stderr) when the process exits. OnChunk streaming
;    is unsupported on AHK (no native stdout pipe interception); a nil-check on
;    the callback makes the parameter accepted but silently ignored.
; 3. ShellRunner_SpawnTreeOwned(): async subprocess whose cmd.exe wrapper is
;    assigned to a kill-on-close Job Object before its first instruction. Its
;    exact process HANDLE is reaped before Job accounting is polled;
;    terminate() returns true only after ActiveProcesses reaches zero.
; 4. All Run/RunWait invocations are wrapped in try/catch so a launch failure
;    never propagates to the caller as an unhandled exception.
;
; SYMMETRY NOTE:
; This adapter mirrors macos/adapters/shell_runner.lua (Hammerspoon). The surface
; (exec / spawn + handle.start / handle.terminate) is intentionally identical so
; modules that need to be ported can rely on the same contract. Windows handles
; additionally expose optional detach(), requestTerminate(), and terminateAsync()
; helpers. requestTerminate() keeps completion ownership while asking Windows to
; kill the process tree, which lets a canceled owner reap private staging output
; even when the kill request fails. None is part of the shared surface.
; ShellRunner is an OS-infrastructure helper, not a formal port contract — it has
; no counterpart in _shared/core/ports/ — it wraps Windows-only process spawning.
; ==============================================================================




; ===================================
; ===================================
; ======= 1/ Global State ===========
; ===================================
; ===================================

; Map of task_id => exact state Map for all in-flight legacy async tasks. Every
; registry winner verifies ObjPtr(state) before taking ownership, so a stale
; snapshot cannot retire a successor which happens to reuse the same task ID.
global _SR_ActiveTasks  := Map()

; Terminal claims retain native capabilities until their checked close succeeds
global _SR_LegacyReleaseOwners := Map()

; Completed results awaiting callback admission are independent of native debt
global _SR_PendingCallbacks := Map()

; Monotonic counter used to generate unique per-task IDs and temp-file names.
global _SR_TaskCounter  := 0
global _SR_CaptureSerial := 0

; Whether the global completion-poll timer is currently armed.
global _SR_PollRunning  := false

; Poll interval in ms — fast enough to detect sub-second processes without
; hammering the CPU; 100 ms is the floor for a responsive completion callback.
global _SR_POLL_INTERVAL_MS := 100

; Legacy lifecycle phases and start verdicts. The numeric values are internal;
; named constants keep every transition readable in the state-machine tests.
global SR_LEGACY_PHASE_READY := 0
global SR_LEGACY_PHASE_STARTING := 1
global SR_LEGACY_PHASE_RUNNING := 2
global SR_LEGACY_PHASE_TERMINAL := 3
global SR_LEGACY_START_REFUSED := 0
global SR_LEGACY_START_BEGUN := 1
global SR_LEGACY_START_ALREADY_ACTIVE := 2

; Native tree-owned tasks use a separate registry because their lifetime is
; keyed by exact HANDLEs, not reusable PIDs. The two APIs intentionally coexist:
; latency-sensitive legacy owners still depend on ShellRunner_Spawn's async
; taskkill contract, while screenshot workers require synchronous tree teardown.
global _SR_TreeOwnedTasks := Map()
global _SR_TreePollRunning := false

; Win32 constants used by the Job Object transport. Keep every value named: a
; wrong creation/limit flag silently changes process-lifetime semantics.
global SR_TREE_CREATE_SUSPENDED := 0x00000004
global SR_TREE_CREATE_NO_WINDOW := 0x08000000
global SR_TREE_JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE := 0x00002000
global SR_TREE_JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION := 1
global SR_TREE_JOB_OBJECT_EXTENDED_LIMIT_INFORMATION := 9
global SR_TREE_WAIT_OBJECT_0 := 0
global SR_TREE_WAIT_TIMEOUT := 258
global SR_ERROR_FILE_NOT_FOUND := 2
global SR_ERROR_PATH_NOT_FOUND := 3
global SR_TREE_WAIT_FAILED := 0xFFFFFFFF
global SR_TREE_TERMINATE_EXIT_CODE := 1
global SR_TREE_BASIC_ACCOUNTING_BYTES := 48
global SR_TREE_ACTIVE_PROCESSES_OFFSET := 40
; TerminateJobObject is forceful but completion is asynchronous. Give accounting
; 500 ms to observe ActiveProcesses=0, yielding every 10 ms so keyboard messages
; remain dispatchable. On timeout the kill-on-close handle is closed and the
; caller receives false plus a diagnostic; no unbounded wait is permitted.
global SR_TREE_TERMINATION_CONFIRM_BUDGET_MS := 500
global SR_TREE_TERMINATION_CONFIRM_POLL_MS := 10
global SR_TREE_ACCOUNTING_FAILURE_LIMIT := 2


; ShellRunner is deliberately valid as an isolated adapter file.  The normal
; driver includes logger.ahk before it, but direct /validate with #Warn must not
; report LoggerError as an unassigned local.  Resolve the logger dynamically and
; keep OutputDebug as a non-throwing diagnostic fallback for standalone use.
;
; The resolution is a dynamic variable dereference, NOT Func("LoggerError").
; In AHK v2 Func is the native CLASS, not a name-lookup built-in, so calling it
; raises `ValueError: Invalid base` every single time — measured, not assumed.
; That throw was caught by this helper's own try and fell through to
; OutputDebug, which is invisible without a debugger attached. Every shell_runner
; error the driver has ever produced was therefore discarded, including the ones
; explaining why a shell-out failed.
_SR_LogError(FormatString, Args*) {
	try {
		LoggerFn := %"LoggerError"%
		LoggerFn.Call("adapters.shell_runner", FormatString, Args*)
	} catch as Err {
		try OutputDebug("[adapters.shell_runner] " . Format(FormatString, Args*))
	}
}

; LoggerError force-flushes to disk. A failed fire-and-forget tree-kill launch
; must still be diagnosed, but never by putting FileOpen/FileAppend back on the
; latency-sensitive terminateAsync() stack. SetTimer's negative period queues a
; one-shot callback after the current AHK thread returns to the message loop.
_SR_DeferLogError(FormatString, Args*) {
	try SetTimer(_SR_LogError.Bind(FormatString, Args*), -1)
	catch as Err {
		try OutputDebug("[adapters.shell_runner] failed to defer diagnostic: "
			. Err.Message . " | " . Format(FormatString, Args*))
	}
}





; ====================================
; ====================================
; ======= 2/ Synchronous Shell =======
; ====================================
; ====================================

/**
 * Executes a shell command synchronously and returns its stdout.
 * Stdout and stderr are both captured. The command is executed via cmd.exe.
 * Failures return an empty string — the adapter never raises.
 * @param {string} Cmd Shell command string (passed to cmd.exe /c).
 * @return {string} stdout+stderr output, or "" on any error.
 */
ShellRunner_Exec(Cmd) {
	if (Type(Cmd) != "String" or Cmd = "") {
		return ""
	}

	CaptureDir := ""
	try CaptureDir := _SR_AcquireCaptureDirectory()
	catch as Err {
		_SR_LogError("exec() capture allocation failed: {1}", Err.Message)
		return ""
	}
	TmpFile := CaptureDir . "output.tmp"
	Result := ""

	try {
		; /c closes cmd.exe after the command; "Hide" avoids a console flash.
		; Stdout and stderr are both redirected so callers can inspect errors.
		;
		; The whole "Cmd > TmpFile 2>&1" tail must be wrapped in ONE extra pair
		; of quotes. cmd.exe's /c argument only strips a quote pair when the
		; FIRST and LAST character of the text following /c are both a quote;
		; quoting only Cmd (leaving the redirection outside) makes the last
		; character `1` instead, so the strip never fires and cmd.exe tries to
		; run the literal quoted token as a command name — the redirection is
		; silently never applied and TmpFile is never created (reproduced with
		; a standalone probe: identical RunWait call, only the extra outer
		; quote pair differs between a silent no-op and a working capture).
		RunWait('cmd.exe /c "' . Cmd . ' > "' . TmpFile . '" 2>&1"', , "Hide")
	} catch as Err {
		_SR_LogError("exec() failed for '{1}': {2}", Cmd, Err.Message)
	} finally {
		if FileExist(TmpFile) {
			try Result := FileRead(TmpFile)
			catch as Err
				_SR_LogError("exec() capture read failed: {1}", Err.Message)
			try FileDelete(TmpFile)
			catch as Err
				_SR_LogError("exec() capture deletion failed: {1}", Err.Message)
		}
		try DirDelete(RTrim(CaptureDir, "\\"))
		catch as Err
			_SR_LogError("exec() capture directory cleanup failed: {1}", Err.Message)
	}

	return Trim(Result, "`r`n")
}





; ===================================
; ===================================
; ======= 3/ Async Subprocess =======
; ===================================
; ===================================

/**
 * Spawns an async subprocess and returns an opaque handle.
 * The handle exposes start(), terminate(), and the optional Windows-only
 * processId()/detach()/terminateAsync(); all are safe on a not-yet-started or
 * already-exited process. processId() identifies the native root process while
 * detach() only retires OnDone ownership; the poller still reaps output.
 *
 * Stdout and stderr are captured to a temp file; both are passed to OnDone as
 * the stdout argument (stderr is always "" to match the macOS contract surface).
 *
 * OnChunk streaming is accepted in the signature but silently ignored: AHK has
 * no native mechanism to intercept a subprocess's stdout mid-run without
 * COM-based pipe redirection, which would require a dedicated background thread.
 *
 * Every argument must be single-line. Native inherited handles capture output
 * without interpreting percent variables or shell operators in literal Args.
 *
 * @param {string}        Executable Absolute path to the binary (e.g. "C:\...\curl.exe").
 * @param {Array}         Args       Array of single-line string arguments (no shell expansion).
 * @param {Func|unset}    OnDone     Completion callback: fn(exit_code, stdout, stderr).
 * @param {Func|unset}    OnChunk    Streaming callback (accepted but unused on AHK).
 * @return {Object}       Handle with start() and terminate() methods.
 */
ShellRunner_Spawn(Executable, Args, OnDone?, OnChunk?) {
	global _SR_TaskCounter
	local previous_critical := Critical("On")
	local task_id := 0
	try task_id := ++_SR_TaskCounter
	finally Critical(previous_critical)
	; Index of the first Arg carrying a newline, or 0 when every Arg is single-line.
	local bad_arg_index := 0
	for Arg in Args {
		if (bad_arg_index = 0 and (InStr(Arg, "`n") or InStr(Arg, "`r")))
			bad_arg_index := A_Index
	}
	local command_line := _SR_BuildDirectCommandLine(Executable, Args)

	local state := _SR_LegacyNewState(task_id, "",
		IsSet(OnDone) && IsObject(OnDone) ? OnDone : 0)
	local handle := {}

	; AHK v2 fat-arrow bodies must be a single expression — a multi-statement
	; block after `=>` is a parse error that aborts tokenising the WHOLE
	; compilation unit (ErgoptiPlus.ahk #Includes this adapter). Nested named
	; functions close over the enclosing locals the same way, so start()/
	; terminate() are defined as ordinary nested functions instead.
	_SR_HandleStart(*) {
		; Refuse before allocating a capture owner or spawning anything.
		if bad_arg_index {
			_SR_LogError("spawn() refused for '{1}': argument {2} contains a newline. Native process arguments must be single-line; stage a multi-line payload to a file and pass the path instead.",
				Executable, bad_arg_index)
			return false
		}
		if state["Phase"] = SR_LEGACY_PHASE_READY && !_SR_LegacyDrainReleases()
			return false
		local start_verdict := _SR_LegacyBeginStart(state)
		if start_verdict = SR_LEGACY_START_ALREADY_ACTIVE {
			return true
		}
		if start_verdict = SR_LEGACY_START_REFUSED
			return false

		local spawned_pid := 0
		try {
			state["CaptureDir"] := _SR_AcquireCaptureDirectory()
			state["TmpFile"] := state["CaptureDir"] . "output.tmp"
			_SR_LegacyCreateDirect(Executable, command_line, state["TmpFile"], state)
			spawned_pid := state["Native"]["Pid"]
			local publication := _SR_LegacyPublishStart(state, spawned_pid)
			if !publication["Published"] {
				local cancelled_claim := publication["Claim"]
				if IsObject(cancelled_claim)
					_SR_LegacyTerminateClaim(cancelled_claim, true)
				return false
			}
			_SR_EnsurePoller()
			; requestTerminate() owns completion even when it arrives while Run is
			; pumping. Publish first, then issue the deferred tree-kill request so
			; the ordinary poller can still reap output and invoke OnDone.
			if publication["RequestKill"]
				_SR_LegacyRequestTreeKill(spawned_pid)
			return !publication["StartCanceled"]
		} catch as Err {
			local failed_claim := _SR_LegacyFailStart(state, spawned_pid)
			if IsObject(failed_claim)
				_SR_LegacyTerminateClaim(failed_claim, true)
			_SR_LogError("spawn.start() failed for '{1}': {2}", Executable, Err.Message)
			return false
		}
	}

	_SR_HandleTerminate(*) {
		local claim := _SR_LegacyClaimTerminate(state)
		if !IsObject(claim) {
			if state["Phase"] = SR_LEGACY_PHASE_TERMINAL && state["TerminalOwner"] != "completion"
				claim := state["TerminalClaim"]
			else
				return state["Phase"] = SR_LEGACY_PHASE_READY
		}
		return IsObject(claim) && _SR_LegacyTerminateClaim(claim, true)
	}

	; Retire callback ownership without touching the live process. A caller which
	; holds a native process HANDLE can terminate that exact process without a PID
	; reuse race, then detach the shell callback while the ordinary poller reaps the
	; cmd.exe wrapper and its temp file.
	_SR_HandleDetach(*) {
		return _SR_LegacyClaimDetach(state)
	}

	_SR_HandleProcessId(*) {
		return _SR_LegacyProcessId(state)
	}

	; Ask Windows to terminate the process tree without retiring the task or its
	; OnDone callback. Owners which stage output privately need that callback even
	; after cancellation: taskkill itself can fail, and the naturally completing
	; worker must then be observed so its stage can be removed without publication.
	_SR_HandleRequestTerminate(*) {
		local pid_to_kill := _SR_LegacyClaimRequestTerminate(state)
		return _SR_LegacyRequestTreeKill(pid_to_kill)
	}

	; Fire-and-forget tree kill for latency-sensitive owners. ProcessClose can
	; block inside TerminateProcess when a filter driver stalls; callers such as
	; the keyboard-thread UIA deadline have already retired logical ownership and
	; must not replace a bounded provider wait with an unbounded synchronous kill.
	_SR_HandleTerminateAsync(*) {
		local outcome := _SR_LegacyClaimAsyncTerminate(state)
		if !outcome["Accepted"]
			return false
		return _SR_LegacyRequestTreeKill(outcome["Pid"])
	}

	handle.start          := _SR_HandleStart
	handle.terminate      := _SR_HandleTerminate
	handle.processId      := _SR_HandleProcessId
	handle.detach         := _SR_HandleDetach
	handle.requestTerminate := _SR_HandleRequestTerminate
	handle.terminateAsync := _SR_HandleTerminateAsync

	return handle
}

; Creates the one identity object shared by the handle and registry. A shallow
; registry Clone keeps this exact Map reference, which makes ObjPtr a stable
; stale-snapshot discriminator across every lifecycle callback.
_SR_LegacyNewState(TaskId, TmpFile, OnDone) {
	local callback_token := _SR_CompletionNewToken(OnDone)
	local state := Map(
		"TaskId", TaskId,
		"Identity", 0,
		"Phase", SR_LEGACY_PHASE_READY,
		"Pid", 0,
		"Native", 0,
		"ProcessDiagnostic", "",
		"TerminalClaim", 0,
		"TmpFile", TmpFile,
		"CaptureDir", "",
		"CallbackToken", callback_token,
		"CancelLaunch", false,
		"TerminationRequested", false,
		"AsyncTerminationRequested", false,
		"TerminalOwner", "")
	state["Identity"] := ObjPtr(state)
	return state
}

; Caller owns Critical. Identity is checked both against the state's immutable
; token and the live registry object; copying the token into another Map is not
; sufficient to claim a task.
_SR_LegacyRegistryOwnsLocked(State) {
	if !(State is Map) || ObjPtr(State) != State.Get("Identity", 0)
		return false
	local task_id := State["TaskId"]
	if !_SR_ActiveTasks.Has(task_id)
		return false
	local current := _SR_ActiveTasks[task_id]
	return current is Map
		&& ObjPtr(current) = ObjPtr(State)
		&& current.Get("Identity", 0) = State["Identity"]
}

; The first caller moves READY to STARTING. Re-entrant start() calls which Run
; pumps see STARTING and do not launch a second process.
_SR_LegacyBeginStart(State) {
	local previous_critical := Critical("On")
	try {
		local phase := State["Phase"]
		if phase = SR_LEGACY_PHASE_READY {
			if State["TerminationRequested"]
				return SR_LEGACY_START_REFUSED
			State["Phase"] := SR_LEGACY_PHASE_STARTING
			return SR_LEGACY_START_BEGUN
		}
		if phase = SR_LEGACY_PHASE_STARTING
			|| phase = SR_LEGACY_PHASE_RUNNING
			|| phase = SR_LEGACY_PHASE_TERMINAL
			return SR_LEGACY_START_ALREADY_ACTIVE
		return SR_LEGACY_START_REFUSED
	} finally {
		Critical(previous_critical)
	}
}

; Caller owns Critical. Non-completion claims retire the callback immediately;
; completion keeps one shared revocation token reachable from both state and
; claim until callback dispatch takes its own final ownership transition.
_SR_LegacyBuildClaimLocked(State, Pid, FireDone, Owner) {
	local callback_token := State["CallbackToken"]
	if !FireDone
		_SR_LegacyDetachCallbackLocked(State)
	State["Phase"] := SR_LEGACY_PHASE_TERMINAL
	State["Pid"] := 0
	State["TerminalOwner"] := Owner
	local claim := Map(
		"TaskId", State["TaskId"],
		"Identity", State["Identity"],
		"Pid", Pid,
		"TmpFile", State["TmpFile"],
		"CaptureDir", State.Get("CaptureDir", ""),
		"Owner", Owner,
		"Native", State["Native"],
		"ReleaseRequested", false,
		"ReleaseBusy", false,
		"ReleaseDiagnostic", "",
		"ReleaseArmDiagnostic", "",
		"CapturePending", State["TmpFile"] != "" || State.Get("CaptureDir", "") != "",
		"TeardownRequested", false,
		"TeardownComplete", false,
		"CleanupBusy", false,
		"ProcessExited", false,
		"TreeKillAccepted", false,
		"DirectKillAccepted", false,
		"UseDirectFallback", false,
		"TreeKillFn", 0,
		"DirectKillFn", 0,
		"CleanupDiagnostics", Map())
	_SR_CompletionInitClaim(claim, callback_token)
	State["Native"] := 0
	State["TerminalClaim"] := claim
	if IsObject(claim["Native"]) || claim["CapturePending"]
		_SR_LegacyReleaseOwners[ObjPtr(claim)] := claim
	return claim
}

; Publishes a completed native launch atomically. Synchronous cancellation which arrived
; while Run pumped messages wins a private claim; async cancellation is instead
; published detached so no blocking teardown returns to the interrupted stack.
_SR_LegacyPublishStart(State, Pid) {
	local previous_critical := Critical("On")
	try {
		if State["Phase"] != SR_LEGACY_PHASE_STARTING
			return Map("Published", false, "Claim", 0,
				"RequestKill", false, "StartCanceled", false)
		if State["CancelLaunch"] || Pid = 0 {
			local cancelled_claim := _SR_LegacyBuildClaimLocked(
				State, Pid, false, "launch_cancelled")
			return Map("Published", false, "Claim", cancelled_claim,
				"RequestKill", false, "StartCanceled", false)
		}
		local task_id := State["TaskId"]
		if _SR_ActiveTasks.Has(task_id) {
			local collision_claim := _SR_LegacyBuildClaimLocked(
				State, Pid, false, "identity_collision")
			return Map("Published", false, "Claim", collision_claim,
				"RequestKill", false, "StartCanceled", false)
		}
		State["Pid"] := Pid
		State["Phase"] := SR_LEGACY_PHASE_RUNNING
		_SR_ActiveTasks[task_id] := State
		local start_cancelled := State["AsyncTerminationRequested"]
		return Map("Published", true, "Claim", 0,
			"RequestKill", State["TerminationRequested"] || start_cancelled,
			"StartCanceled", start_cancelled)
	} finally {
		Critical(previous_critical)
	}
}

; Claims a launch which threw, including the narrow case where publication won
; but arming the poller failed. No cleanup starts until the registry entry and
; callback have been retired under Critical.
_SR_LegacyFailStart(State, SpawnedPid) {
	local previous_critical := Critical("On")
	try {
		local phase := State["Phase"]
		if phase = SR_LEGACY_PHASE_RUNNING {
			if !_SR_LegacyRegistryOwnsLocked(State)
				return 0
			_SR_ActiveTasks.Delete(State["TaskId"])
			return _SR_LegacyBuildClaimLocked(State,
				State["Pid"], false, "start_failed")
		}
		if phase = SR_LEGACY_PHASE_STARTING
			return _SR_LegacyBuildClaimLocked(State,
				State["Pid"] != 0 ? State["Pid"] : SpawnedPid, false, "start_failed")
		return 0
	} finally {
		Critical(previous_critical)
	}
}

; terminate() before start is deliberately a no-op. Once Run is in flight it
; records a launch cancellation; once published it atomically wins the exact
; registry entry before any process or filesystem work begins.
_SR_LegacyClaimTerminate(State) {
	local previous_critical := Critical("On")
	try {
		local phase := State["Phase"]
		if phase = SR_LEGACY_PHASE_READY
			return 0
		if phase = SR_LEGACY_PHASE_STARTING {
			State["CancelLaunch"] := true
			_SR_LegacyDetachCallbackLocked(State)
			State["TerminalOwner"] := "terminate_pending_launch"
			return 0
		}
		if phase = SR_LEGACY_PHASE_TERMINAL {
			_SR_LegacyDetachCallbackLocked(State)
			return 0
		}
		if phase != SR_LEGACY_PHASE_RUNNING
			return 0
		if !_SR_LegacyRegistryOwnsLocked(State)
			return 0
		_SR_ActiveTasks.Delete(State["TaskId"])
		return _SR_LegacyBuildClaimLocked(State,
			State["Pid"], false, "terminate")
	} finally {
		Critical(previous_critical)
	}
}

; Completion owns the same exact-identity transition as terminate(). The winner
; removes the task before FileRead, FileDelete, or callback dispatch.
_SR_LegacyClaimCompletion(TaskId, SnapshotState) {
	local previous_critical := Critical("On")
	try {
		if !(SnapshotState is Map)
			return 0
		if SnapshotState["TaskId"] != TaskId
			return 0
		if SnapshotState["Phase"] != SR_LEGACY_PHASE_RUNNING
			return 0
		if !_SR_LegacyRegistryOwnsLocked(SnapshotState)
			return 0
		_SR_ActiveTasks.Delete(TaskId)
		return _SR_LegacyBuildClaimLocked(SnapshotState,
			SnapshotState["Pid"], true, "completion")
	} finally {
		Critical(previous_critical)
	}
}

; Caller owns Critical. The callback token stays reachable through State after a
; completion claim leaves the registry, so detach/terminate can still revoke a
; callback which has not crossed its final dispatch linearization point.
_SR_LegacyDetachCallbackLocked(State) {
	local token := State["CallbackToken"]
	if token["Detached"]
		return true
	if token["DispatchClaimed"]
		return false
	token["Detached"] := true
	token["Callback"] := 0
	return true
}

; Detach is remembered before start and is exact after publication. A stale
; handle cannot clear a successor's callback under a reused task ID.
_SR_LegacyClaimDetach(State) {
	local previous_critical := Critical("On")
	try {
		if State["Phase"] = SR_LEGACY_PHASE_RUNNING
			&& !_SR_LegacyRegistryOwnsLocked(State)
			return false
		return _SR_LegacyDetachCallbackLocked(State)
	} finally {
		Critical(previous_critical)
	}
}

; requestTerminate() deliberately differs from terminate(): before start it
; makes the later start refuse, and after publication it retains OnDone so the
; owner can observe a naturally completing worker when taskkill fails.
_SR_LegacyClaimRequestTerminate(State) {
	local previous_critical := Critical("On")
	try {
		local phase := State["Phase"]
		if phase = SR_LEGACY_PHASE_READY {
			State["TerminationRequested"] := true
			return 0
		}
		if phase = SR_LEGACY_PHASE_STARTING {
			; Run already owns a launch. Publication will preserve this request and
			; hand the returned PID back to start() for a deferred tree kill.
			State["TerminationRequested"] := true
			return 0
		}
		if phase != SR_LEGACY_PHASE_RUNNING
			return 0
		if !_SR_LegacyRegistryOwnsLocked(State)
			return 0
		State["TerminationRequested"] := true
		return State["Pid"]
	} finally {
		Critical(previous_critical)
	}
}

; Async termination retires callback ownership but leaves the exact state in
; the registry so the ordinary poller can delete captured output off the caller's
; latency-sensitive stack.
_SR_LegacyClaimAsyncTerminate(State) {
	local previous_critical := Critical("On")
	try {
		local outcome := Map("Accepted", false, "Pid", 0)
		local phase := State["Phase"]
		if phase = SR_LEGACY_PHASE_READY {
			outcome["Accepted"] := true
			return outcome
		}
		if phase = SR_LEGACY_PHASE_STARTING {
			; Unlike synchronous terminate(), keep the returning PID poller-owned.
			; start() will publish this detached state, launch taskkill, and return
			; false without ProcessClose or filesystem work on its resumed stack.
			State["AsyncTerminationRequested"] := true
			outcome["Accepted"] := _SR_LegacyDetachCallbackLocked(State)
			return outcome
		}
		if phase = SR_LEGACY_PHASE_TERMINAL {
			outcome["Accepted"] := _SR_LegacyDetachCallbackLocked(State)
			return outcome
		}
		if phase != SR_LEGACY_PHASE_RUNNING
			return outcome
		if !_SR_LegacyRegistryOwnsLocked(State)
			return outcome
		State["TerminationRequested"] := true
		State["AsyncTerminationRequested"] := true
		outcome["Accepted"] := _SR_LegacyDetachCallbackLocked(State)
		if outcome["Accepted"]
			outcome["Pid"] := State["Pid"]
		return outcome
	} finally {
		Critical(previous_critical)
	}
}

_SR_LegacyProcessId(State) {
	local previous_critical := Critical("On")
	try return State["Phase"] = SR_LEGACY_PHASE_RUNNING
		&& _SR_LegacyRegistryOwnsLocked(State) ? State["Pid"] : 0
	finally Critical(previous_critical)
}

_SR_LegacyRequestTreeKill(Pid) {
	if Pid = 0
		return true
	try {
		Run("taskkill.exe /PID " . Pid . " /T /F", , "Hide")
		return true
	} catch as Err {
		_SR_DeferLogError("process-tree termination request failed for PID {1}: {2}",
			Pid, Err.Message)
		return false
	}
}

_SR_CompletionNewToken(Callback) {
	return Map("Callback", IsObject(Callback) ? Callback : 0,
		"Detached", false, "DispatchClaimed", false)
}

_SR_CompletionInitClaim(Claim, Token) {
	local previous_critical := Critical("On")
	try {
		if Claim.Has("ClaimIdentity")
			throw Error("Completion claim is already initialized.")
		Claim["ClaimIdentity"] := ObjPtr(Claim)
		Claim["CallbackToken"] := Token
		Claim["Finished"] := false
		Claim["CompletionBusy"] := false
		Claim["CompletionResult"] := 0
	} finally {
		Critical(previous_critical)
	}
}

; Finalization is claimed before diagnostics or capture I/O can yield
_SR_CompletionBegin(Claim) {
	if !(Claim is Map)
		return false
	local previous_critical := Critical("On")
	try {
		if ObjPtr(Claim) != Claim["ClaimIdentity"] || Claim["Finished"]
			return false
		Claim["Finished"] := true
		Claim["CompletionBusy"] := true
		return true
	} finally {
		Critical(previous_critical)
	}
}

; Takes callback ownership immediately before dispatch. Detach remains able to
; clear the shared token while completion performs exit lookup or file I/O, but
; loses explicitly once this short Critical transition claims dispatch.
_SR_CompletionClaimCallback(Claim, &Callback) {
	Callback := 0
	local previous_critical := Critical("On")
	try {
		if A_IsSuspended || !(Claim is Map) || !Claim["Finished"]
			return false
		local token := Claim["CallbackToken"]
		if token["Detached"] || token["DispatchClaimed"]
			return false
		if !IsObject(token["Callback"]) {
			token["Detached"] := true
			return false
		}
		token["DispatchClaimed"] := true
		Callback := token["Callback"]
		token["Callback"] := 0
		return true
	} finally {
		Critical(previous_critical)
	}
}

; Terminal teardown runs only after a state-machine winner has removed shared
; ownership. The direct fallback preserves the original terminate() contract;
; terminateAsync() never calls this path.
_SR_LegacyTerminateClaim(Claim, UseDirectFallback, TreeKillFn := 0, DirectKillFn := 0) {
	if !_SR_LegacyBeginTeardown(Claim, UseDirectFallback, TreeKillFn, DirectKillFn)
		return Claim["TeardownComplete"]
	try {
		if !_SR_LegacyObserveTeardownExit(Claim) {
			_SR_LegacyRequestTeardown(Claim)
			if !_SR_LegacyObserveTeardownExit(Claim)
				return false
		}
		if !_SR_LegacyCleanupCaptureDirectory(Claim)
			return false
		if !_SR_LegacyReleaseProcess(Claim)
			return false
		Claim["Finished"] := true
		Claim["TeardownComplete"] := true
		Claim["TreeKillFn"] := 0
		Claim["DirectKillFn"] := 0
		return true
	} catch as Err {
		_SR_LegacyCleanupError(Claim, "teardown", Err.Message)
		return false
	} finally {
		Claim["CleanupBusy"] := false
		if !Claim["TeardownComplete"]
			_SR_LegacyArmCleanupRetry(Claim)
	}
}

; Logical callback retirement and physical teardown have independent receipts
_SR_LegacyBeginTeardown(Claim, UseDirectFallback, TreeKillFn, DirectKillFn) {
	local previous_critical := Critical("On")
	try {
		if ObjPtr(Claim) != Claim["ClaimIdentity"]
			|| Claim["TeardownComplete"] || Claim["CleanupBusy"]
			|| (Claim["Finished"] && !Claim["TeardownRequested"])
			return false
		_SR_LegacyDetachCallbackLocked(Claim)
		_SR_LegacyReleaseOwners[ObjPtr(Claim)] := Claim
		Claim["TeardownRequested"] := true
		Claim["CleanupBusy"] := true
		Claim["UseDirectFallback"] := UseDirectFallback
		Claim["TreeKillFn"] := TreeKillFn
		Claim["DirectKillFn"] := DirectKillFn
		return true
	} finally {
		Critical(previous_critical)
	}
}

_SR_LegacyObserveTeardownExit(Claim) {
	if Claim["ProcessExited"]
		return true
	local native := Claim["Native"]
	if !IsObject(native) {
		if Claim["Pid"] != 0
			throw Error("Legacy teardown lost its process capability.")
		Claim["ProcessExited"] := true
		return true
	}
	local diagnostic := ""
	if !_SR_TreeProcessHasExited(native["ProcessHandle"], &diagnostic) {
		if diagnostic != ""
			throw Error(diagnostic)
		return false
	}
	Claim["ProcessExited"] := true
	return true
}

; Preserve the legacy asynchronous tree request, but terminate the exact root
; capability rather than reopening a PID. Acceptance is not proof of exit
_SR_LegacyRequestTeardown(Claim) {
	if !Claim["TreeKillAccepted"] {
		try {
			local accepted := IsObject(Claim["TreeKillFn"])
				? Claim["TreeKillFn"].Call(Claim["Pid"])
				: _SR_LegacyRequestTreeKill(Claim["Pid"])
			if !accepted
				throw Error("Legacy tree termination request was refused.")
			Claim["TreeKillAccepted"] := true
		} catch as Err {
			_SR_LegacyCleanupError(Claim, "tree termination", Err.Message)
		}
	}
	if Claim["UseDirectFallback"] && !Claim["DirectKillAccepted"] {
		try {
			local process_handle := Claim["Native"]["ProcessHandle"]
			local accepted := IsObject(Claim["DirectKillFn"])
				? Claim["DirectKillFn"].Call(process_handle)
				: DllCall("Kernel32\TerminateProcess", "Ptr", process_handle,
					"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int")
			if !accepted
				throw Error("TerminateProcess failed (Win32 " . A_LastError . ").")
			Claim["DirectKillAccepted"] := true
		} catch as Err {
			_SR_LegacyCleanupError(Claim, "direct termination", Err.Message)
		}
	}
}

_SR_LegacyCleanupError(Claim, Operation, Diagnostic) {
	local previous_critical := Critical("On")
	try {
		local diagnostics := Claim["CleanupDiagnostics"]
		if diagnostics.Get(Operation, "") = Diagnostic
			return
		diagnostics[Operation] := Diagnostic
	} finally {
		Critical(previous_critical)
	}
	_SR_LogError("Legacy task {1} retains {2} cleanup debt: {3}", Claim["TaskId"], Operation, Diagnostic)
}

; Completion capture is deliberately downstream of the atomic task claim. The
; claim becomes one-shot before FileRead, while callback ownership is delayed
; until after I/O so detach can still revoke a not-yet-dispatched completion.
_SR_LegacyFinishCompletion(Claim, ExitCode, ReadFn := 0) {
	if !_SR_CompletionBegin(Claim)
		return false
	try {
		local stdout := "", stderr := ""
		try {
			try {
				local tmp_file := Claim["TmpFile"]
				if FileExist(tmp_file) {
					local output := IsObject(ReadFn) ? ReadFn.Call(tmp_file) : FileRead(tmp_file)
					stdout := Trim(output, "`r`n")
				}
			} catch as Err {
				stderr := Err.Message
				_SR_LegacyCleanupError(Claim, "output read", Err.Message)
			}
			_SR_LegacyCleanupCaptureDirectory(Claim)
		} finally {
			_SR_LegacyReleaseProcess(Claim)
		}
		_SR_CompletionQueue(Claim, ExitCode, stdout, stderr)
	} finally {
		Claim["CompletionBusy"] := false
		if _SR_LegacyReleaseOwners.Has(ObjPtr(Claim))
			_SR_LegacyArmCleanupRetry(Claim)
	}
	_SR_CompletionDispatch(Claim)
	return true
}

_SR_CompletionQueue(Claim, ExitCode, Stdout, Stderr) {
	local previous_critical := Critical("On")
	try {
		local identity := ObjPtr(Claim)
		if identity != Claim["ClaimIdentity"] || IsObject(Claim["CompletionResult"])
			throw Error("Completion result ownership is invalid.")
		Claim["CompletionResult"] := [ExitCode, Stdout, Stderr]
		_SR_PendingCallbacks[identity] := Claim
	} finally {
		Critical(previous_critical)
	}
	try _SR_EnsurePoller()
	catch as Err
		_SR_LogError("Task {1} completion retry timer failed: {2}", Claim["TaskId"], Err.Message)
}

; Admission is atomic, but arbitrary client callbacks never run under our lock
_SR_CompletionDispatch(Claim) {
	local callback := 0, result := 0
	local previous_critical := Critical("On")
	try {
		local identity := ObjPtr(Claim)
		if !_SR_PendingCallbacks.Has(identity)
			|| ObjPtr(_SR_PendingCallbacks[identity]) != identity
			|| Claim["CompletionBusy"]
			return false
		local token := Claim["CallbackToken"]
		if token["Detached"] || token["DispatchClaimed"] || !IsObject(token["Callback"]) {
			_SR_PendingCallbacks.Delete(identity)
			Claim["CompletionResult"] := 0
			return false
		}
		if !_SR_CompletionClaimCallback(Claim, &callback)
			return false
		result := Claim["CompletionResult"]
		_SR_PendingCallbacks.Delete(identity)
		Claim["CompletionResult"] := 0
	} finally {
		Critical(previous_critical)
	}
	try callback.Call(result*)
	catch as Err
		_SR_LogError("Task {1} on_done callback threw: {2}", Claim["TaskId"], Err.Message)
	return true
}

_SR_CompletionDrain() {
	local snapshot := 0
	local previous_critical := Critical("On")
	try snapshot := _SR_PendingCallbacks.Clone()
	finally Critical(previous_critical)
	for identity, claim in snapshot
		_SR_CompletionDispatch(claim)
}

_SR_LegacyCleanupCaptureDirectory(Claim) {
	try {
		for operation, capture_path in Map("DeleteFileW", Claim["TmpFile"],
			"RemoveDirectoryW", Claim.Get("CaptureDir", "")) {
			if capture_path = ""
				continue
			if !DllCall("Kernel32\" . operation, "WStr", capture_path, "Int") {
				local native_error := A_LastError
				if native_error != SR_ERROR_FILE_NOT_FOUND && native_error != SR_ERROR_PATH_NOT_FOUND
					throw Error(operation . " failed (Win32 " . native_error . ").")
			}
		}
		Claim["CapturePending"] := false
		return true
	} catch as Err {
		_SR_LegacyCleanupError(Claim, "capture", Err.Message)
		return false
	}
}

; Legacy callers own the root PID, not a kill-on-close job. Reuse the native
; stream setup while leaving descendant lifetime to their existing contract.
_SR_LegacyCreateDirect(Executable, CommandLine, CapturePath, State, ResumeFn := 0, ThreadCloseFn := 0) {
	local native := _SR_TreeCreateSuspended(Executable,
		CommandLine, CapturePath, false)
	local previous_critical := Critical("On")
	try {
		State["Native"] := native
		State["Pid"] := native["Pid"]
		local resumed := IsObject(ResumeFn) ? ResumeFn.Call(native["ThreadHandle"])
			: DllCall("Kernel32\ResumeThread", "Ptr", native["ThreadHandle"], "UInt")
		if resumed = 0xFFFFFFFF
			throw Error("ResumeThread failed (Win32 " . A_LastError . ").")
		local closed := IsObject(ThreadCloseFn) ? ThreadCloseFn.Call(native["ThreadHandle"])
			: DllCall("Kernel32\CloseHandle", "Ptr", native["ThreadHandle"], "Int")
		if !closed
			throw Error("CloseHandle(ThreadHandle) failed (Win32 " . A_LastError . ").")
		native["ThreadHandle"] := 0
		return native
	} finally {
		Critical(previous_critical)
	}
}






; ================================================
; ====== 3.1) Native process-tree ownership ======
; ================================================

_SR_QuoteCreateProcessArgument(Value) {
	Text := Value . ""
	Result := '"'
	BackslashCount := 0
	Loop Parse Text {
		Character := A_LoopField
		if (Character == "\") {
			BackslashCount += 1
			continue
		}
		if (Character == '"') {
			Loop BackslashCount * 2 + 1
				Result .= "\"
			Result .= '"'
			BackslashCount := 0
			continue
		}
		Loop BackslashCount
			Result .= "\"
		BackslashCount := 0
		Result .= Character
	}
	Loop BackslashCount * 2
		Result .= "\"
	return Result . '"'
}

_SR_BuildDirectCommandLine(Executable, Args) {
	CommandLine := _SR_QuoteCreateProcessArgument(Executable)
	for Arg in Args
		CommandLine .= " " . _SR_QuoteCreateProcessArgument(Arg)
	return CommandLine
}

_SR_AcquireCaptureDirectory() {
	global _SR_CaptureSerial
	OwnerPid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	loop 128 {
		_SR_CaptureSerial += 1
		Candidate := A_Temp . "\ergopti_sr_capture_" . OwnerPid . "_"
			. _SR_CaptureSerial
		if DllCall("Kernel32\CreateDirectoryW", "Str", Candidate, "Ptr", 0, "Int")
			return Candidate . "\"
		if (A_LastError != 183)
			throw OSError(A_LastError, "CreateDirectoryW")
	}
	throw Error("unable to acquire an exclusive shell capture directory")
}

_SR_ResolveExecutableForCreateProcess(Executable) {
	if FileExist(Executable)
		return Executable
	BufferChars := 32768
	PathBuffer := Buffer(BufferChars * 2, 0)
	FoundChars := DllCall("Kernel32\SearchPathW", "Ptr", 0,
		"Str", Executable, "Ptr", 0, "UInt", BufferChars,
		"Ptr", PathBuffer.Ptr, "Ptr", 0, "UInt")
	if (FoundChars = 0 || FoundChars >= BufferChars)
		throw Error("SearchPathW could not resolve executable '" . Executable . "'.")
	return StrGet(PathBuffer, "UTF-16")
}

_SR_QuoteArgument(Arg) {
	; cmd.exe needs doubled quotes; the child's argv parser needs doubled final
	; backslashes so a directory separator cannot escape the closing quote.
	Escaped := StrReplace(Arg, '"', '""')
	Escaped := RegExReplace(Escaped, "(\\+)$", "$1$1")
	return '"' . Escaped . '"'
}

/**
 * Validates a spawn request and composes the quoted inner command line.
 *
 * Extracted from ShellRunner_SpawnTreeOwned so callers can be pinned against
 * the exact refusal the spawn boundary applies. Every argument must already be
 * a String: a command line has no other type, and a caller that hands over an
 * Integer (a timing constant, a byte budget) is refused before any process is
 * created (keylogger-worker-timings-must-be-strings).
 *
 * @param Executable {String} Absolute path to the child executable.
 * @param Args {Array} Argument vector; every element must be a String.
 * @returns {Map} "error" (empty when admissible), "bad_arg_index" (first
 *   newline-bearing argument, 0 when none) and "inner_cmd" (the quoted line).
 */
ShellRunner_ValidateSpawnArgs(Executable, Args) {
	local inner_cmd := ""
	local bad_arg_index := 0
	local validation_error := ""
	if Type(Executable) != "String" or Executable = "" {
		validation_error := "Executable must be a non-empty string."
	} else if !(Args is Array) {
		validation_error := "Args must be an Array."
	} else {
		inner_cmd := '"' . Executable . '"'
		for Arg in Args {
			if Type(Arg) != "String" {
				validation_error := "Argument " . A_Index . " must be a string."
				break
			}
			if (bad_arg_index = 0 and (InStr(Arg, "`n") or InStr(Arg, "`r")))
				bad_arg_index := A_Index
			inner_cmd .= " " . _SR_QuoteArgument(Arg)
		}
	}
	return Map("error", validation_error, "bad_arg_index", bad_arg_index,
		"inner_cmd", inner_cmd)
}

/**
 * Builds a lazily-started async subprocess whose complete descendant tree is
 * owned by a Windows Job Object.
 *
 * CreateProcessW creates the cmd.exe wrapper suspended. The wrapper is assigned
 * to a JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE job before ResumeThread, so there is
 * no launch window in which its PowerShell child can escape the owner. Polling
 * and teardown use the exact process/job HANDLEs; a recycled PID can neither be
 * mistaken for completion nor killed accidentally.
 *
 * terminate() and requestTerminate() synchronously request tree termination.
 * True means ActiveProcesses=0 was confirmed before return; false also covers
 * an accepted STARTING cancellation whose private suspended handles must be
 * finalized by the interrupted start stack. requestTerminate() retains the
 * completion callback contract needed by staging owners; terminate() suppresses
 * it. detach() only retires an unclaimed callback.
 * BeforeNativeAdoptFn is a deterministic regression seam invoked only after Job
 * assignment; production callers omit it. CaptureOutput=false redirects the
 * child tree to NUL so a long-lived task whose output is unused cannot grow an
 * unbounded staging file.
 */
ShellRunner_SpawnTreeOwned(Executable, Args, OnDone?, OnChunk?,
		BeforeNativeAdoptFn?, MaxOutputBytes := 0, CaptureOutput := true) {
	global _SR_TaskCounter
	local previous_critical := Critical("On")
	local task_id := 0
	try task_id := ++_SR_TaskCounter
	finally Critical(previous_critical)

	local capture_output := !!CaptureOutput
	local validation := ShellRunner_ValidateSpawnArgs(Executable, Args)
	local bad_arg_index := validation["bad_arg_index"]
	local validation_error := validation["error"]

	; This API receives an executable and argv, never shell syntax. Launch it
	; directly: cmd.exe expands %VAR% before the child can parse argv, even when
	; the argument is quoted. stdout/stderr capture is attached natively below.
	local cmd := _SR_BuildDirectCommandLine(Executable, Args)
	local state := Map(
		"TaskId", task_id,
		"Executable", Executable,
		"Command", cmd,
		"TmpFile", "",
		"CaptureDir", "",
		"CaptureOutput", capture_output,
		"MaxOutputBytes", Max(0, Integer(MaxOutputBytes)),
		"BadArgIndex", bad_arg_index,
		"ValidationError", validation_error,
		"OnDone", IsSet(OnDone) && IsObject(OnDone) ? OnDone : 0,
		"BeforeNativeAdopt", IsSet(BeforeNativeAdoptFn)
			&& IsObject(BeforeNativeAdoptFn) ? BeforeNativeAdoptFn : 0,
		"Starting", false,
		"Started", false,
		"TerminationRequested", false,
		"PendingTerminationCallback", 0,
		"TerminalClaimed", false,
		"TerminalClaim", 0,
		"TreeQuiesced", false,
		"FinalizationPending", false,
		"AccountingDiagnosticLogged", false,
		"AccountingFailureCount", 0,
		"RootReaped", false,
		"ExitQueryDiagnostic", "",
		"ExitCode", 0,
		"Detached", false,
		"ProcessHandle", 0,
		"ThreadHandle", 0,
		"JobHandle", 0,
		"Pid", 0)
	local handle := {}

	_SR_TreeOwnedStart(*) {
		return _SR_TreeHandleStart(state)
	}
	_SR_TreeOwnedTerminate(*) {
		return _SR_TreeHandleTerminate(state, false)
	}
	_SR_TreeOwnedRequestTerminate(*) {
		return _SR_TreeHandleTerminate(state, true)
	}
	_SR_TreeOwnedProcessId(*) {
		return _SR_TreeHandleProcessId(state)
	}
	_SR_TreeOwnedDetach(*) {
		return _SR_TreeHandleDetach(state)
	}

	handle.start := _SR_TreeOwnedStart
	handle.terminate := _SR_TreeOwnedTerminate
	handle.processId := _SR_TreeOwnedProcessId
	handle.detach := _SR_TreeOwnedDetach
	handle.requestTerminate := _SR_TreeOwnedRequestTerminate
	; A tree-owned termination cannot honestly be fire-and-forget: its defining
	; contract is that no descendant exists on return. Keep the optional method
	; for handle-shape compatibility, but route it through the same hard fence.
	handle.terminateAsync := _SR_TreeOwnedTerminate
	return handle
}

_SR_TreeHandleStart(State) {
	local validation_error := State["ValidationError"]
	local bad_arg_index := State["BadArgIndex"]
	if validation_error != "" {
		local invalid_claim := _SR_TreeClaimTask(State, false)
		_SR_TreeQuiesceNative(invalid_claim, true)
		_SR_TreeRecordQuiesced(State, invalid_claim)
		_SR_TreeFinishClaim(invalid_claim)
		_SR_LogError("tree-owned spawn() refused for '{1}': {2}",
			State["Executable"], validation_error)
		return false
	}
	if bad_arg_index {
		local newline_claim := _SR_TreeClaimTask(State, false)
		_SR_TreeQuiesceNative(newline_claim, true)
		_SR_TreeRecordQuiesced(State, newline_claim)
		_SR_TreeFinishClaim(newline_claim)
		_SR_LogError("tree-owned spawn() refused for '{1}': argument {2} contains a newline. The cmd.exe /c transport truncates at the first newline; stage a multi-line payload to a file and pass its path instead.",
			State["Executable"], bad_arg_index)
		return false
	}

	local previous_critical := Critical("On")
	try {
		if State["TerminalClaimed"] or State["TerminationRequested"]
			return false
		if State["Started"]
			return true
		if State["Starting"]
			return false
		State["Starting"] := true
	} finally {
		Critical(previous_critical)
	}

	if State["CaptureOutput"] {
		try {
			State["CaptureDir"] := _SR_AcquireCaptureDirectory()
			State["TmpFile"] := State["CaptureDir"] . "output.tmp"
		} catch as Err {
			previous_critical := Critical("On")
			try State["Starting"] := false
			finally Critical(previous_critical)
			_SR_LogError("tree-owned capture allocation failed for '{1}': {2}",
				State["Executable"], Err.Message)
			return false
		}
	}

	local native := 0
	try native := _SR_TreeCreateSuspended(State["Executable"], State["Command"],
		State["TmpFile"])
	catch as Err {
		previous_critical := Critical("On")
		try State["Starting"] := false
		finally Critical(previous_critical)
		local failed_claim := _SR_TreeClaimTask(State, false)
		_SR_TreeQuiesceNative(failed_claim, true)
		_SR_TreeRecordQuiesced(State, failed_claim)
		_SR_TreeFinishClaim(failed_claim)
		_SR_LogError("tree-owned spawn.start() failed for '{1}': {2}",
			State["Executable"], Err.Message)
		return false
	}
	local before_adopt_failed := false
	local before_adopt_error := ""
	local before_adopt := State["BeforeNativeAdopt"]
	State["BeforeNativeAdopt"] := 0
	if IsObject(before_adopt) {
		try before_adopt.Call(State, native)
		catch Any as Err {
			before_adopt_failed := true
			if Err is Error
				before_adopt_error := Err.Message != "" ? Err.Message : "no message"
			else if Err is String
				before_adopt_error := Err != "" ? Err : "empty String"
			else
				before_adopt_error := "thrown value type " . Type(Err)
		}
	}
	if before_adopt_failed {
		previous_critical := Critical("On")
		try {
			if !State["TerminationRequested"] {
				State["TerminationRequested"] := true
				State["FinalizationPending"] := true
				State["PendingTerminationCallback"] := 0
				State["OnDone"] := 0
			}
		} finally {
			Critical(previous_critical)
		}
	}

	local canceled_before_resume := false
	local canceled_claim := 0
	local resume_claim := 0
	local resume_error := ""
	local thread_close_error := ""
	previous_critical := Critical("On")
	try {
		if State["TerminalClaimed"] {
			State["Starting"] := false
			canceled_before_resume := true
		} else {
			; Ownership transfer is take-and-zero: after this block, either State
			; owns each native value or native does, never both. Starting remains
			; true through the transfer, so an emergency callback can only latch a
			; pending cancellation, never claim a half-populated State.
			State["ProcessHandle"] := native["ProcessHandle"]
			native["ProcessHandle"] := 0
			State["ThreadHandle"] := native["ThreadHandle"]
			native["ThreadHandle"] := 0
			State["JobHandle"] := native["JobHandle"]
			native["JobHandle"] := 0
			State["Pid"] := native["Pid"]
			native["Pid"] := 0
			State["Starting"] := false

			if State["TerminationRequested"] {
				; STARTING request/terminate/detach calls already resolved the
				; still-unclaimed callback disposition. Claim the complete suspended
				; bundle without publishing it or allowing the wrapper to execute.
				canceled_claim := _SR_TreeClaimTaskLocked(State, false, false)
			} else {
				State["Started"] := true
				_SR_TreeOwnedTasks[State["TaskId"]] := State

				local resume_result := SR_TREE_WAIT_FAILED
				try resume_result := DllCall("Kernel32\ResumeThread",
					"Ptr", State["ThreadHandle"], "UInt")
				catch as Err
					resume_error := "ResumeThread threw: " . Err.Message
				if resume_result = SR_TREE_WAIT_FAILED {
					if resume_error = ""
						resume_error := "ResumeThread failed (Win32 " . A_LastError . ")."
					resume_claim := _SR_TreeClaimTaskLocked(State, false, false)
				} else {
					; The primary thread HANDLE is unnecessary after resume. Zero it
					; before CloseHandle so no interrupt can acquire the same owner.
					local thread_handle := State["ThreadHandle"]
					State["ThreadHandle"] := 0
					if thread_handle {
						try {
							if !DllCall("Kernel32\CloseHandle",
									"Ptr", thread_handle, "Int")
								thread_close_error := "CloseHandle(thread) failed (Win32 "
									. A_LastError . ")."
						} catch as Err {
							thread_close_error := "CloseHandle(thread) threw: " . Err.Message
						}
					}
				}
			}
		}
	} finally {
		Critical(previous_critical)
	}

	if canceled_before_resume {
		; A cancellation may interrupt the native setup between its fast Win32
		; calls. The wrapper is still suspended, hence it has created no child;
		; this owner now kills and closes the unpublished handles exactly once.
		_SR_TreeQuiesceNative(native, true)
		for NativeError in native["NativeErrors"]
			_SR_LogError("tree-owned canceled-start cleanup warning for '{1}': {2}",
				State["Executable"], NativeError)
		if before_adopt_failed
			_SR_LogError("tree-owned before-adopt hook failed for '{1}': {2}",
				State["Executable"], before_adopt_error)
		return false
	}
	if IsObject(canceled_claim) {
		_SR_TreeQuiesceNative(canceled_claim, true)
		_SR_TreeRecordQuiesced(State, canceled_claim)
		_SR_TreeFinishClaim(canceled_claim)
		if before_adopt_failed
			_SR_LogError("tree-owned before-adopt hook failed for '{1}': {2}",
				State["Executable"], before_adopt_error)
		return false
	}
	if IsObject(resume_claim) {
		_SR_TreeQuiesceNative(resume_claim, true)
		_SR_TreeRecordQuiesced(State, resume_claim)
		_SR_TreeFinishClaim(resume_claim)
		_SR_LogError("tree-owned spawn.start() failed for '{1}': {2}",
			State["Executable"], resume_error)
		return false
	}
	if thread_close_error != ""
		_SR_LogError("tree-owned spawn.start() cleanup warning for '{1}': {2}",
			State["Executable"], thread_close_error)
	_SR_TreeEnsurePoller()
	return true
}

_SR_TreeHandleTerminate(State, FireDone) {
	local claim := 0
	local already_quiesced := false
	local finalization_pending := false
	local starting_pending := false
	local previous_critical := Critical("On")
	try {
		if !FireDone
			_SR_TreeHandleDetach(State)
		if State["Starting"] && !State["TerminalClaimed"] {
			if !State["TerminationRequested"] {
				State["TerminationRequested"] := true
				State["FinalizationPending"] := true
				State["PendingTerminationCallback"] := FireDone
					&& !State["Detached"] && IsObject(State["OnDone"])
					? State["OnDone"] : 0
				State["OnDone"] := 0
			}
			if !FireDone
				State["PendingTerminationCallback"] := 0
			starting_pending := true
		} else {
			State["TerminationRequested"] := true
			claim := _SR_TreeClaimTaskLocked(State, FireDone, false)
			if !IsObject(claim) {
				already_quiesced := State["TreeQuiesced"]
				finalization_pending := State["FinalizationPending"]
			}
		}
	} finally {
		Critical(previous_critical)
	}
	if starting_pending
		return false
	if IsObject(claim) {
		; TerminateJobObject completion is asynchronous. Confirm the exact job's
		; ActiveProcesses count outside Critical with a small bounded/yielding
		; poll; never wait on the job HANDLE, which is not generally signaled.
		_SR_TreeQuiesceNative(claim, true)
		_SR_TreeRecordQuiesced(State, claim)
		_SR_TreeFinishClaim(claim)
		return claim["TreeQuiesced"]
	}
	if finalization_pending
		_SR_LogError("tree-owned task {1} termination is already being finalized; returning false instead of claiming an unverified empty tree.",
			State["TaskId"])
	return already_quiesced
}

_SR_TreeHandleDetach(State) {
	local previous_critical := Critical("On")
	try {
		State["Detached"] := true
		State["OnDone"] := 0
		State["PendingTerminationCallback"] := 0
		local terminal_claim := State.Get("TerminalClaim", 0)
		if IsObject(terminal_claim) {
			terminal_claim["CallbackToken"]["Detached"] := true
			terminal_claim["CallbackToken"]["Callback"] := 0
		}
		; Every registry access is inside the same non-yielding window as the
		; State mutation. Poll completion can therefore win before or after
		; detach, but can never observe a half-detached task Map.
		local task_id := State["TaskId"]
		if _SR_TreeOwnedTasks.Has(task_id)
			_SR_TreeOwnedTasks[task_id]["OnDone"] := 0
		return true
	} finally {
		Critical(previous_critical)
	}
}

_SR_TreeHandleProcessId(State) {
	local previous_critical := Critical("On")
	try return State["Pid"]
	finally Critical(previous_critical)
}

; Returns {ProcessHandle, ThreadHandle, JobHandle, Pid, Assigned}. On every
; failure the exact handles acquired so far are terminated/closed before the
; exception escapes. CreateProcessW requires a mutable UTF-16 command buffer.
_SR_TreeCreateSuspended(Executable, CommandLine, CapturePath, OwnTree := true,
		CreateFn := PLC_CreateProcessWithInheritedHandles,
		CloseStreamFn := _SR_TreeCloseLaunchStream) {
	if !HasMethod(CreateFn, "Call") || !HasMethod(CloseStreamFn, "Call")
		throw TypeError("Native launch ports must be callable")
	local job_handle := 0
	local process_handle := 0
	local thread_handle := 0
	local input_handle := 0
	local output_handle := 0
	local pid := 0
	local assigned := false
	try {
		if OwnTree {
			job_handle := DllCall("Kernel32\CreateJobObjectW", "Ptr", 0,
				"Ptr", 0, "Ptr")
			if !job_handle
				throw Error("CreateJobObjectW failed (Win32 " . A_LastError . ").")

			local extended_bytes := (A_PtrSize = 8) ? 144 : 112
			local limit_info := Buffer(extended_bytes, 0)
			; LimitFlags follows two LARGE_INTEGER fields on both architectures
			NumPut("UInt", SR_TREE_JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
				limit_info, 16)
			if !DllCall("Kernel32\SetInformationJobObject",
					"Ptr", job_handle,
					"Int", SR_TREE_JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
					"Ptr", limit_info.Ptr,
					"UInt", limit_info.Size,
					"Int")
				throw Error("SetInformationJobObject failed (Win32 " . A_LastError . ").")
		}

		local startup_bytes := (A_PtrSize = 8) ? 104 : 68
		local startup_info := Buffer(startup_bytes, 0)
		NumPut("UInt", startup_info.Size, startup_info, 0)
		local security := Buffer((A_PtrSize = 8) ? 24 : 12, 0)
		NumPut("UInt", security.Size, security, 0)
		NumPut("Int", true, security, (A_PtrSize = 8) ? 16 : 8)
		local invalid_handle := -1
		input_handle := DllCall("Kernel32\CreateFileW", "Str", "NUL",
			"UInt", 0x80000000, "UInt", 3, "Ptr", security.Ptr,
			"UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		if (input_handle = invalid_handle)
			throw Error("CreateFileW(NUL input) failed (Win32 " . A_LastError . ").")
		local output_target := CapturePath != "" ? CapturePath : "NUL"
		local output_disposition := CapturePath != "" ? 1 : 3
		output_handle := DllCall("Kernel32\CreateFileW", "Str", output_target,
			"UInt", 0x40000000, "UInt", 3, "Ptr", security.Ptr,
			"UInt", output_disposition, "UInt", 0x80, "Ptr", 0, "Ptr")
		if (output_handle = invalid_handle)
			throw Error("CreateFileW(capture output) failed (Win32 " . A_LastError . ").")
		NumPut("UInt", 0x00000100, startup_info, 60)
		NumPut("Ptr", input_handle, startup_info, (A_PtrSize = 8) ? 80 : 56)
		NumPut("Ptr", output_handle, startup_info, (A_PtrSize = 8) ? 88 : 60)
		NumPut("Ptr", output_handle, startup_info, (A_PtrSize = 8) ? 96 : 64)
		local process_info := Buffer(2 * A_PtrSize + 8, 0)
		local command_buffer := Buffer(StrPut(CommandLine, "UTF-16") * 2, 0)
		StrPut(CommandLine, command_buffer, "UTF-16")
		local creation_flags := SR_TREE_CREATE_SUSPENDED | SR_TREE_CREATE_NO_WINDOW
		local application_path := _SR_ResolveExecutableForCreateProcess(Executable)
		CreateFn.Call(application_path, command_buffer,
			creation_flags, startup_info, process_info)
		; Cleanup must own the successful creation before any stream close can fail.
		process_handle := NumGet(process_info, 0, "Ptr")
		thread_handle := NumGet(process_info, A_PtrSize, "Ptr")
		pid := NumGet(process_info, 2 * A_PtrSize, "UInt")
		if !CloseStreamFn.Call(input_handle)
			throw Error("CloseHandle(input) failed (Win32 " . A_LastError . ").")
		input_handle := 0
		if !CloseStreamFn.Call(output_handle)
			throw Error("CloseHandle(output) failed (Win32 " . A_LastError . ").")
		output_handle := 0

		if OwnTree {
			if !DllCall("Kernel32\AssignProcessToJobObject",
					"Ptr", job_handle, "Ptr", process_handle, "Int")
				throw Error("AssignProcessToJobObject failed (Win32 " . A_LastError . ").")
			assigned := true
		}
		local owned := Map(
			"ProcessHandle", process_handle,
			"ThreadHandle", thread_handle,
			"JobHandle", job_handle,
			"Pid", pid,
			"Assigned", assigned)
		process_handle := 0
		thread_handle := 0
		job_handle := 0
		return owned
	} catch as Err {
		if input_handle && input_handle != -1
			try DllCall("Kernel32\CloseHandle", "Ptr", input_handle, "Int")
		if output_handle && output_handle != -1
			try DllCall("Kernel32\CloseHandle", "Ptr", output_handle, "Int")
		local partial := Map(
			"ProcessHandle", process_handle,
			"ThreadHandle", thread_handle,
			"JobHandle", job_handle,
			"Pid", pid,
			"Assigned", assigned)
		process_handle := 0
		thread_handle := 0
		job_handle := 0
		_SR_TreeQuiesceNative(partial, true)
		throw Err
	}
}

_SR_TreeCloseLaunchStream(Handle) {
	return DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int")
}

_SR_TreeClaimTask(State, FireDone, AccountingConfirmedZero := false) {
	local previous_critical := Critical("On")
	try return _SR_TreeClaimTaskLocked(State, FireDone, AccountingConfirmedZero)
	finally Critical(previous_critical)
}

; Caller owns Critical. Every HANDLE is copied and zeroed in one atomic step;
; the returned claim becomes their sole owner until _SR_TreeQuiesceNative.
_SR_TreeClaimTaskLocked(State, FireDone, AccountingConfirmedZero) {
	if State["TerminalClaimed"]
		return 0
	State["TerminalClaimed"] := true
	State["FinalizationPending"] := true
	State["Starting"] := false
	local task_id := State["TaskId"]
	if _SR_TreeOwnedTasks.Has(task_id)
		_SR_TreeOwnedTasks.Delete(task_id)
	local pending_callback := State["PendingTerminationCallback"]
	local callback := IsObject(pending_callback) ? pending_callback
		: (FireDone && !State["Detached"] && IsObject(State["OnDone"])
			? State["OnDone"] : 0)
	State["PendingTerminationCallback"] := 0
	State["OnDone"] := 0
	local claim := Map(
		"TaskId", task_id,
		"Executable", State["Executable"],
		"TmpFile", State["TmpFile"],
		"CaptureDir", State.Get("CaptureDir", ""),
		"MaxOutputBytes", State.Get("MaxOutputBytes", 0),
		"AccountingConfirmedZero", AccountingConfirmedZero,
		"ProcessHandle", State["ProcessHandle"],
		"ThreadHandle", State["ThreadHandle"],
		"JobHandle", State["JobHandle"],
		"Assigned", State["JobHandle"] != 0,
		"ExitCode", State["ExitCode"],
		"TreeQuiesced", false,
		"NativeErrors", Array())
	_SR_CompletionInitClaim(claim, _SR_CompletionNewToken(callback))
	State["TerminalClaim"] := claim
	State["ProcessHandle"] := 0
	State["ThreadHandle"] := 0
	State["JobHandle"] := 0
	State["Pid"] := 0
	return claim
}

; Returns the exact number of processes still assigned to JobHandle, or -1 on
; failure. QueryInformationJobObject is non-blocking; a job HANDLE itself is not
; a general completion event and must never be passed to an infinite wait.
_SR_TreeActiveProcessCount(JobHandle, &Diagnostic) {
	Diagnostic := ""
	try {
		local accounting := Buffer(SR_TREE_BASIC_ACCOUNTING_BYTES, 0)
		if !DllCall("Kernel32\QueryInformationJobObject",
				"Ptr", JobHandle,
				"Int", SR_TREE_JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION,
				"Ptr", accounting.Ptr,
				"UInt", accounting.Size,
				"Ptr", 0,
				"Int") {
			Diagnostic := "QueryInformationJobObject failed (Win32 "
				. A_LastError . ")."
			return -1
		}
		return NumGet(accounting, SR_TREE_ACTIVE_PROCESSES_OFFSET, "UInt")
	} catch as Err {
		Diagnostic := "QueryInformationJobObject threw: " . Err.Message
		return -1
	}
}

; TerminateJobObject queues forced termination; accounting is the completion
; predicate. This bounded poll runs only outside Critical and uses AHK Sleep so
; other driver threads remain dispatchable during the 500 ms maximum budget.
_SR_TreeConfirmJobEmpty(JobHandle, Errors) {
	local attempts := Floor(SR_TREE_TERMINATION_CONFIRM_BUDGET_MS
		/ SR_TREE_TERMINATION_CONFIRM_POLL_MS) + 1
	local active_processes := -1
	loop attempts {
		local diagnostic := ""
		active_processes := _SR_TreeActiveProcessCount(JobHandle, &diagnostic)
		if active_processes = 0
			return true
		if active_processes < 0 {
			errors.Push(diagnostic)
			return false
		}
		if A_Index < attempts
			Sleep(SR_TREE_TERMINATION_CONFIRM_POLL_MS)
	}
	errors.Push("Job still reports " . active_processes . " active process(es) after the bounded "
		. SR_TREE_TERMINATION_CONFIRM_BUDGET_MS . " ms termination confirmation budget.")
	return false
}

_SR_TreeProcessHasExited(ProcessHandle, &Diagnostic) {
	Diagnostic := ""
	try {
		local wait_result := DllCall("Kernel32\WaitForSingleObject",
			"Ptr", ProcessHandle, "UInt", 0, "UInt")
		if wait_result = SR_TREE_WAIT_OBJECT_0
			return true
		if wait_result = SR_TREE_WAIT_FAILED
			Diagnostic := "WaitForSingleObject(process) failed (Win32 "
				. A_LastError . ")."
		return false
	} catch as Err {
		Diagnostic := "WaitForSingleObject(process) threw: " . Err.Message
		return false
	}
}

; Callers confirm this exact handle has signaled: 259 is then a valid exit code,
; not evidence that the process is still running.
_SR_TreeReadExitCode(ProcessHandle, &ExitCode, &Diagnostic) {
	ExitCode := 0
	Diagnostic := ""
	try {
		local code := 0
		if !DllCall("Kernel32\GetExitCodeProcess", "Ptr", ProcessHandle,
				"UInt*", &code, "Int") {
			Diagnostic := "GetExitCodeProcess failed (Win32 "
				. A_LastError . ")."
			return false
		}
		ExitCode := code
		return true
	} catch as Err {
		Diagnostic := "GetExitCodeProcess threw: " . Err.Message
		return false
	}
}

; Used only for a suspended root whose Job assignment failed. It has no child,
; but TerminateProcess completion is still confirmed with the same finite budget.
_SR_TreeConfirmProcessExit(ProcessHandle, Errors) {
	local attempts := Floor(SR_TREE_TERMINATION_CONFIRM_BUDGET_MS
		/ SR_TREE_TERMINATION_CONFIRM_POLL_MS) + 1
	loop attempts {
		local diagnostic := ""
		if _SR_TreeProcessHasExited(ProcessHandle, &diagnostic)
			return true
		if diagnostic != "" {
			errors.Push(diagnostic)
			return false
		}
		if A_Index < attempts
			Sleep(SR_TREE_TERMINATION_CONFIRM_POLL_MS)
	}
	errors.Push("Process did not exit within the bounded "
		. SR_TREE_TERMINATION_CONFIRM_BUDGET_MS . " ms confirmation budget.")
	return false
}

; Native-only teardown. Always call outside Critical: forced termination uses a
; bounded, yielding accounting poll. The natural-completion path never kills;
; it trusts the zero accounting snapshot atomically captured by _SR_TreePoll.
; No filesystem access, logging, or callback occurs here.
_SR_TreeQuiesceNative(Claim, TerminateTree) {
	if !IsObject(Claim)
		return false
	; Natural polling must retain query authority until the root code is known
	if !TerminateTree && Claim["ProcessHandle"]
		throw Error("Natural tree quiescence requires a reaped root; native ownership was retained")
	local process_handle := Claim["ProcessHandle"]
	local thread_handle := Claim["ThreadHandle"]
	local job_handle := Claim["JobHandle"]
	local assigned := Claim["Assigned"]
	; Take-and-zero before the first close: even an exception cannot expose a
	; second owner through Claim.
	Claim["ProcessHandle"] := 0
	Claim["ThreadHandle"] := 0
	Claim["JobHandle"] := 0
	local errors := Claim.Get("NativeErrors", Array())
	Claim["NativeErrors"] := errors
	local exit_code := TerminateTree ? SR_TREE_TERMINATE_EXIT_CODE
		: Claim.Get("ExitCode", 0)
	local job_empty := (job_handle = 0 || !assigned)
	local process_exited := (process_handle = 0)

	try {
		if job_handle && assigned {
			if TerminateTree {
				try {
					if !DllCall("Kernel32\TerminateJobObject", "Ptr", job_handle,
							"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int")
						errors.Push("TerminateJobObject failed (Win32 " . A_LastError . ").")
				} catch as Err {
					errors.Push("TerminateJobObject threw: " . Err.Message)
				}
				; ActiveProcesses cannot reach zero while this adapter retains its
				; process/thread references. Capture an already-available exit code,
				; then release both exact HANDLEs before consulting job accounting.
				if process_handle {
					local termination_exit_diagnostic := ""
					if _SR_TreeProcessHasExited(process_handle,
							&termination_exit_diagnostic) {
						local termination_observed_code := 0
						if _SR_TreeReadExitCode(process_handle,
								&termination_observed_code,
								&termination_exit_diagnostic)
							exit_code := termination_observed_code
						else
							errors.Push(termination_exit_diagnostic)
					} else if termination_exit_diagnostic != "" {
						errors.Push(termination_exit_diagnostic)
					}
				}
				_SR_TreeCloseNativeHandle("thread", thread_handle, errors)
				thread_handle := 0
				_SR_TreeCloseNativeHandle("process", process_handle, errors)
				process_handle := 0
				process_exited := true
				job_empty := _SR_TreeConfirmJobEmpty(job_handle, errors)
			} else {
				job_empty := Claim.Get("AccountingConfirmedZero", false)
				if !job_empty
					errors.Push("Natural completion lacked an atomic ActiveProcesses=0 claim; refusing to report completion.")
			}
		} else if process_handle && TerminateTree {
			; CreateProcessW succeeded but assignment failed. The suspended root
			; has no descendants yet, so terminating that exact HANDLE is complete.
			try {
				if !DllCall("Kernel32\TerminateProcess", "Ptr", process_handle,
						"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int")
					errors.Push("TerminateProcess failed (Win32 " . A_LastError . ").")
			} catch as Err {
				errors.Push("TerminateProcess threw: " . Err.Message)
			}
		}

		if process_handle {
			local process_diagnostic := ""
			if TerminateTree && !assigned {
				process_exited := _SR_TreeConfirmProcessExit(process_handle, errors)
			} else {
				process_exited := _SR_TreeProcessHasExited(process_handle,
					&process_diagnostic)
				if process_diagnostic != ""
					errors.Push(process_diagnostic)
				else if !process_exited
					errors.Push("Process HANDLE was not signaled after accounting reached zero.")
			}
			if process_exited {
				local final_observed_code := 0
				local final_exit_diagnostic := ""
				if _SR_TreeReadExitCode(process_handle, &final_observed_code,
						&final_exit_diagnostic)
					exit_code := final_observed_code
				else
					errors.Push(final_exit_diagnostic)
			}
		}
		if TerminateTree && job_handle && assigned && !job_empty
			errors.Push("Closing the kill-on-close Job Object after bounded accounting confirmation failed; terminate() returns false.")
	} finally {
		_SR_TreeCloseNativeHandle("thread", thread_handle, errors)
		_SR_TreeCloseNativeHandle("process", process_handle, errors)
		_SR_TreeCloseNativeHandle("job", job_handle, errors)
	}
	local tree_quiesced := job_empty && process_exited
	Claim["ExitCode"] := exit_code
	Claim["TreeQuiesced"] := tree_quiesced
	return tree_quiesced
}

_SR_TreeCloseNativeHandle(Kind, NativeHandle, Errors) {
	if !NativeHandle
		return true
	try {
		if DllCall("Kernel32\CloseHandle", "Ptr", NativeHandle, "Int")
			return true
		Errors.Push("CloseHandle(" . Kind . ") failed (Win32 "
			. A_LastError . ").")
	} catch as Err {
		Errors.Push("CloseHandle(" . Kind . ") threw: " . Err.Message)
	}
	return false
}

_SR_TreeRecordQuiesced(State, Claim) {
	if !IsObject(Claim)
		return
	local previous_critical := Critical("On")
	try {
		State["TreeQuiesced"] := Claim["TreeQuiesced"]
		State["FinalizationPending"] := false
	}
	finally Critical(previous_critical)
}

; Filesystem capture and callbacks are intentionally separated from the native
; ownership fence so neither can run while Critical.
_SR_TreeFinishClaim(Claim, ReadFn := 0) {
	if !_SR_CompletionBegin(Claim)
		return false
	try {
		for NativeError in Claim["NativeErrors"]
			_SR_LogError("tree-owned task {1} teardown warning: {2}",
				Claim["TaskId"], NativeError)
		local stdout := ""
		local tmp_file := Claim["TmpFile"]
		try {
			if tmp_file != "" && FileExist(tmp_file) {
				local max_output_bytes := Claim.Get("MaxOutputBytes", 0)
				local output_bytes := FileGetSize(tmp_file)
				if max_output_bytes > 0 && output_bytes > max_output_bytes {
					Claim["ExitCode"] := 63
					_SR_LogError("tree-owned task {1} output exceeded its {2}-byte ceiling; body was not read.",
						Claim["TaskId"], max_output_bytes)
				} else {
					local output := IsObject(ReadFn) ? ReadFn.Call(tmp_file) : FileRead(tmp_file)
					stdout := Trim(output, "`r`n")
				}
			}
		} catch as Err {
			_SR_LogError("tree-owned task {1} output cleanup failed: {2}",
				Claim["TaskId"], Err.Message)
		} finally {
			try {
				if tmp_file != "" && FileExist(tmp_file)
					FileDelete(tmp_file)
				local capture_dir := Claim.Get("CaptureDir", "")
				if capture_dir != "" && DirExist(capture_dir)
					DirDelete(RTrim(capture_dir, "\\"))
			} catch as Err {
				_SR_LogError("tree-owned task {1} output deletion failed: {2}",
					Claim["TaskId"], Err.Message)
			}
		}
		_SR_CompletionQueue(Claim, Claim["ExitCode"], stdout, "")
	} finally {
		Claim["CompletionBusy"] := false
	}
	_SR_CompletionDispatch(Claim)
	return true
}

; Caller owns Critical. Applying the timer before publishing its logical flag
; makes the two states one transaction: a failing SetTimer cannot commit a lie,
; and an old empty tick cannot disarm a newly published owner's poller.
_SR_TreeSetPollerRunningLocked(Desired, ApplyTimer := 0) {
	global _SR_TreePollRunning, _SR_POLL_INTERVAL_MS
	if !A_IsCritical
		throw Error("tree-owned poller transition requires Critical")
	local period := Desired ? _SR_POLL_INTERVAL_MS : 0
	if IsObject(ApplyTimer)
		ApplyTimer.Call(period)
	else if Desired
		SetTimer(_SR_TreePoll, _SR_POLL_INTERVAL_MS)
	else
		SetTimer(_SR_TreePoll, 0)
	_SR_TreePollRunning := Desired
}

_SR_TreeEnsurePoller(ApplyTimer := 0) {
	global _SR_TreePollRunning
	local previous_critical := Critical("On")
	try {
		if !_SR_TreePollRunning
			_SR_TreeSetPollerRunningLocked(true, ApplyTimer)
	} finally {
		Critical(previous_critical)
	}
}

; Poll exact process HANDLEs. ProcessExist(PID) is forbidden here: PID reuse can
; keep a completed task alive or make teardown target an unrelated process.
_SR_TreePoll(ApplyTimer := 0) {
	_SR_CompletionDrain()
	local snapshot := 0
	local previous_critical := Critical("On")
	try {
		if _SR_TreeOwnedTasks.Count = 0 {
			_SR_TreeSetPollerRunningLocked(false, ApplyTimer)
			return
		} else if A_IsSuspended {
			return
		} else {
			snapshot := _SR_TreeOwnedTasks.Clone()
		}
	} finally {
		Critical(previous_critical)
	}
	if !IsObject(snapshot)
		return

	for task_id, state in snapshot {
		local claim := 0
		local poll_diagnostic := ""
		local force_terminate := false
		previous_critical := Critical("On")
		try {
			if A_IsSuspended || state["TerminalClaimed"]
				continue

			; Root reap: once the exact root HANDLE signals, capture its exit code,
			; take-and-zero it, then close it. Job accounting cannot decrement
			; ActiveProcesses while this retained process reference still exists.
			if !state["RootReaped"] {
				local process_handle := state["ProcessHandle"]
				if !process_handle
					continue
				local wait_diagnostic := ""
				if _SR_TreeProcessHasExited(process_handle, &wait_diagnostic) {
					local observed_exit_code := 0
					local exit_diagnostic := ""
					if _SR_TreeReadExitCode(process_handle, &observed_exit_code,
							&exit_diagnostic) {
						state["ExitCode"] := observed_exit_code
						state["ExitQueryDiagnostic"] := ""
						state["ProcessHandle"] := 0
						state["Pid"] := 0
						state["RootReaped"] := true
						local close_errors := Array()
						_SR_TreeCloseNativeHandle("process", process_handle, close_errors)
						if close_errors.Length > 0
							poll_diagnostic := close_errors[1]
					} else if state["ExitQueryDiagnostic"] != exit_diagnostic {
						; A signaled process can still refuse a code query. Preserve its
						; exact handle for retry instead of publishing the default zero
						state["ExitQueryDiagnostic"] := exit_diagnostic
						poll_diagnostic := exit_diagnostic . " Native ownership retained for retry."
					}
				} else if wait_diagnostic != "" {
					poll_diagnostic := wait_diagnostic
					force_terminate := true
					claim := _SR_TreeClaimTaskLocked(state, true, false)
					if IsObject(claim)
						claim["NativeErrors"].Push(wait_diagnostic)
				} else {
					continue
				}
			}

			; Tree drain: retain the JobHandle and task registry entry while any
			; descendant remains. Natural completion never terminates that valid
			; survivor; OnDone becomes claimable only at ActiveProcesses == 0.
			if !IsObject(claim) && state["RootReaped"] {
				local accounting_diagnostic := ""
				local active_processes := _SR_TreeActiveProcessCount(
					state["JobHandle"], &accounting_diagnostic)
				if active_processes = 0 {
					state["AccountingDiagnosticLogged"] := false
					state["AccountingFailureCount"] := 0
					claim := _SR_TreeClaimTaskLocked(state, true, true)
				} else if active_processes < 0 {
					state["AccountingFailureCount"] += 1
					if !state["AccountingDiagnosticLogged"] {
						poll_diagnostic := accounting_diagnostic
						state["AccountingDiagnosticLogged"] := true
					}
					if state["AccountingFailureCount"] >= SR_TREE_ACCOUNTING_FAILURE_LIMIT {
						force_terminate := true
						claim := _SR_TreeClaimTaskLocked(state, true, false)
						if IsObject(claim)
							claim["NativeErrors"].Push("Repeated job-accounting failure forced fail-closed teardown: "
								. accounting_diagnostic)
					}
				} else {
					state["AccountingDiagnosticLogged"] := false
					state["AccountingFailureCount"] := 0
				}
			}
		} finally {
			Critical(previous_critical)
		}
		if poll_diagnostic != ""
			_SR_LogError("tree-owned task {1} poll diagnostic: {2}",
				task_id, poll_diagnostic)
		if IsObject(claim) {
			_SR_TreeQuiesceNative(claim, force_terminate)
			_SR_TreeRecordQuiesced(state, claim)
			_SR_TreeFinishClaim(claim)
		}
	}
}






; =============================================
; =============================================
; ======= 3.2) Legacy completion poller =======
; =============================================
; =============================================

; Ensures the global completion-poll timer is running.
; Called lazily when the first task is spawned.
_SR_EnsurePoller() {
	; Assigned below (line "_SR_PollRunning := true"), so without this
	; declaration AHK v2 treats the name as a function-local for the WHOLE
	; function body — the read on the very next line then throws "This local
	; variable has not been assigned a value" instead of seeing the module
	; global's current state.
	global _SR_PollRunning
	local previous_critical := Critical("On")
	try {
		if !_SR_PollRunning {
			SetTimer(_SR_Poll, _SR_POLL_INTERVAL_MS)
			_SR_PollRunning := true
		}
	} finally {
		Critical(previous_critical)
	}
}

; Periodic timer: checks every active task and fires OnDone when the process exits.
; Self-disarms when no tasks remain so it consumes no CPU at idle.
_SR_Poll() {
	; Same auto-local shadowing hazard as _SR_EnsurePoller() above — this
	; function also assigns _SR_PollRunning.
	global _SR_PollRunning
	_SR_LegacyDrainReleases()
	_SR_CompletionDrain()
	local snapshot := 0
	local previous_critical := Critical("On")
	try {
		if _SR_ActiveTasks.Count = 0 && _SR_LegacyReleaseOwners.Count = 0
			&& _SR_PendingCallbacks.Count = 0 {
			; Disarming under the same Critical span closes the empty->new-task race:
			; an intervening start cannot arm the timer and then have this tick erase it.
			_SR_PollRunning := false
			SetTimer(_SR_Poll, 0)
			return
		}

		; This periodic SetTimer bypasses native Suspend() (only Hotkeys/Hotstrings
		; are disarmed) — skip firing OnDone callbacks while paused. Tasks stay in
		; _SR_ActiveTasks and the next tick after resume picks them back up.
		if A_IsSuspended
			return
		snapshot := _SR_ActiveTasks.Clone()
	} finally {
		Critical(previous_critical)
	}

	; The Clone is shallow: task remains the exact state Map whose ObjPtr was
	; published. Every terminal path must win _SR_LegacyClaimCompletion first.
	for task_id, task in snapshot {
		local claim := 0
		try claim := _SR_LegacyObserveCompletion(task_id, task)
		catch as Err {
			if task["ProcessDiagnostic"] != Err.Message {
				task["ProcessDiagnostic"] := Err.Message
				_SR_LogError("Legacy task {1} exit observation failed: {2}", task_id, Err.Message)
			}
			continue
		}
		if !IsObject(claim)
			continue
		_SR_LegacyFinishCompletion(claim, claim["ExitCode"])
	}
}

; Observe and claim under one non-yielding identity fence. Never reopen a PID:
; the original process handle remains valid even after Windows collects the PID
_SR_LegacyObserveCompletion(TaskId, State, ReadFn := 0) {
	local previous_critical := Critical("On")
	try {
		if A_IsSuspended || !(State is Map) || State["TaskId"] != TaskId
			|| State["Phase"] != SR_LEGACY_PHASE_RUNNING
			|| !_SR_LegacyRegistryOwnsLocked(State)
			return 0
		local native := State["Native"]
		if !(native is Map) || !native["ProcessHandle"]
			throw Error("Legacy process capability is missing.")
		local wait_result := DllCall("Kernel32\WaitForSingleObject",
			"Ptr", native["ProcessHandle"], "UInt", 0, "UInt")
		if wait_result = SR_TREE_WAIT_TIMEOUT
			return 0
		if wait_result != SR_TREE_WAIT_OBJECT_0
			throw Error("WaitForSingleObject failed (Win32 " . A_LastError . ").")
		local code := IsObject(ReadFn) ? ReadFn.Call(native["ProcessHandle"])
			: _SR_LegacyReadExitCode(native["ProcessHandle"])
		local claim := _SR_LegacyClaimCompletion(TaskId, State)
		claim["ExitCode"] := code
		return claim
	} finally {
		Critical(previous_critical)
	}
}

; The caller first proves the handle signaled, so 259 is a legitimate exit code
_SR_LegacyReadExitCode(ProcessHandle) {
	local code := 0
	if !DllCall("Kernel32\GetExitCodeProcess", "Ptr", ProcessHandle, "UInt*", &code, "Int")
		throw Error("GetExitCodeProcess failed (Win32 " . A_LastError . ").")
	return code
}

; A refused close retains the exact claim independently of logical completion.
; Retry only native release, never output capture or the one-shot callback
_SR_LegacyReleaseProcess(Claim, CloseFn := 0, ArmFn := 0) {
	local diagnostic := "", released := false
	local previous_critical := Critical("On")
	try {
		if Claim["TeardownRequested"] && !Claim["ProcessExited"]
			return false
		local native := Claim.Get("Native", 0)
		local identity := ObjPtr(Claim)
		if !IsObject(native) {
			Claim["ReleaseRequested"] := true
			if Claim["CapturePending"]
				return false
			if _SR_LegacyReleaseOwners.Has(identity)
				_SR_LegacyReleaseOwners.Delete(identity)
			return true
		}
		if !_SR_LegacyReleaseOwners.Has(identity)
			|| ObjPtr(_SR_LegacyReleaseOwners[identity]) != identity
			throw Error("Legacy native release owner is missing.")
		Claim["ReleaseRequested"] := true
		if Claim["ReleaseBusy"]
			return false
		Claim["ReleaseBusy"] := true
		try {
			for key in ["ThreadHandle", "ProcessHandle"] {
				local native_handle := native.Get(key, 0)
				if !native_handle
					continue
				local accepted := IsObject(CloseFn) ? CloseFn.Call(native_handle)
					: DllCall("Kernel32\CloseHandle", "Ptr", native_handle, "Int")
				if !accepted
					throw Error("CloseHandle(" . key . ") failed (Win32 " . A_LastError . ").")
				native[key] := 0
			}
			Claim["Native"] := 0
			released := !Claim["CapturePending"]
			if released
				_SR_LegacyReleaseOwners.Delete(identity)
		} catch as Err {
			if Claim["ReleaseDiagnostic"] != Err.Message {
				Claim["ReleaseDiagnostic"] := Err.Message
				diagnostic := Err.Message
			}
		} finally {
			Claim["ReleaseBusy"] := false
		}
	} finally {
		Critical(previous_critical)
	}
	if diagnostic != ""
		_SR_LogError("Legacy task {1} retains native release debt: {2}", Claim["TaskId"], diagnostic)
	if !released
		_SR_LegacyArmCleanupRetry(Claim, ArmFn)
	return released
}

_SR_LegacyArmCleanupRetry(Claim, ArmFn := 0) {
	try {
		if IsObject(ArmFn)
			ArmFn.Call()
		else
			_SR_EnsurePoller()
	} catch as Err {
		; Keep the retry owner reachable without suppressing terminal notification
		if Claim["ReleaseArmDiagnostic"] != Err.Message {
			Claim["ReleaseArmDiagnostic"] := Err.Message
			_SR_LogError("Legacy task {1} release retry timer failed: {2}", Claim["TaskId"], Err.Message)
		}
	}
}

; New launches cannot accumulate native close debt indefinitely
_SR_LegacyDrainReleases() {
	local snapshot := 0
	local previous_critical := Critical("On")
	try snapshot := _SR_LegacyReleaseOwners.Clone()
	finally Critical(previous_critical)
	local released := true
	for identity, claim in snapshot {
		if claim["TeardownRequested"] {
			if !_SR_LegacyTerminateClaim(claim, claim["UseDirectFallback"],
				claim["TreeKillFn"], claim["DirectKillFn"])
				released := false
			continue
		}
		if claim["CompletionBusy"] {
			if claim["ReleaseRequested"]
				released := false
			continue
		}
		if claim["Finished"] && claim["CapturePending"] {
			if !_SR_LegacyCleanupCaptureDirectory(claim)
				released := false
		}
		if claim["ReleaseRequested"] && !_SR_LegacyReleaseProcess(claim)
			released := false
	}
	return released
}
