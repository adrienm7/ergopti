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
; 2. ShellRunner_Spawn(): async subprocess via Run + PID-poll timer. Calls
;    OnDone(exit_code, stdout, stderr) when the process exits. OnChunk streaming
;    is unsupported on AHK (no native stdout pipe interception); a nil-check on
;    the callback makes the parameter accepted but silently ignored.
; 3. All Run/RunWait invocations are wrapped in try/catch so a launch failure
;    never propagates to the caller as an unhandled exception.
;
; SYMMETRY NOTE:
; This adapter mirrors macos/adapters/shell_runner.lua (Hammerspoon). The surface
; (exec / spawn + handle.start / handle.terminate) is intentionally identical so
; modules that need to be ported can rely on the same contract.
; ShellRunner is an OS-infrastructure helper, not a formal port contract — it has
; no counterpart in _shared/core/ports/. See M6 in docs/REFACTOR_GUIDE.md.
; ==============================================================================




; ===================================
; ===================================
; ======= 1/ Global State ===========
; ===================================
; ===================================

; Map of task_id => {Pid, TmpFile, OnDone} for all in-flight async tasks.
; Kept alive so the GC-equivalent is explicit: Remove() on completion.
global _SR_ActiveTasks  := Map()

; Monotonic counter used to generate unique per-task IDs and temp-file names.
global _SR_TaskCounter  := 0

; Whether the global completion-poll timer is currently armed.
global _SR_PollRunning  := false

; Poll interval in ms — fast enough to detect sub-second processes without
; hammering the CPU; 100 ms is the floor for a responsive completion callback.
global _SR_POLL_INTERVAL_MS := 100




; ===================================
; ===================================
; ======= 2/ Synchronous Shell ======
; ===================================
; ===================================

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

	TmpFile := A_Temp . "\ergopti_sr_" . A_TickCount . ".tmp"

	try {
		; /c closes cmd.exe after the command; "Hide" avoids a console flash.
		; Stdout and stderr are both redirected so callers can inspect errors.
		RunWait('cmd.exe /c "' . Cmd . '" > "' . TmpFile . '" 2>&1', , "Hide")
	} catch as Err {
		LoggerError("adapters.shell_runner", "exec() failed for '%s': %s", Cmd, Err.Message)
		return ""
	}

	Result := ""
	try {
		if FileExist(TmpFile) {
			Result := FileRead(TmpFile)
			FileDelete(TmpFile)
		}
	} catch {
		; Best-effort cleanup — ignore read/delete failures.
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
 * The handle exposes start() and terminate() — both are safe to call multiple
 * times and on a not-yet-started or already-exited process.
 *
 * Stdout and stderr are captured to a temp file; both are passed to OnDone as
 * the stdout argument (stderr is always "" to match the macOS contract surface).
 *
 * OnChunk streaming is accepted in the signature but silently ignored: AHK has
 * no native mechanism to intercept a subprocess's stdout mid-run without
 * COM-based pipe redirection, which would require a dedicated background thread.
 *
 * @param {string}        Executable Absolute path to the binary (e.g. "C:\...\curl.exe").
 * @param {Array}         Args       Array of string arguments (no shell expansion).
 * @param {Func|unset}    OnDone     Completion callback: fn(exit_code, stdout, stderr).
 * @param {Func|unset}    OnChunk    Streaming callback (accepted but unused on AHK).
 * @return {Object}       Handle with start() and terminate() methods.
 */
ShellRunner_Spawn(Executable, Args, OnDone?, OnChunk?) {
	local task_id := ++_SR_TaskCounter
	local tmp_file := A_Temp . "\ergopti_sr_" . task_id . ".tmp"

	; Build the command line with quoted arguments.
	local cmd := '"' . Executable . '"'
	for Arg in Args {
		cmd .= ' "' . StrReplace(Arg, '"', '`"') . '"'
	}
	cmd .= ' > "' . tmp_file . '" 2>&1'

	local started   := false
	local pid       := 0
	local handle    := {}

	handle.start := () => {
		if started {
			return
		}
		started := true
		try {
			Run(cmd, , "Hide", &pid)
			_SR_ActiveTasks[task_id] := Map(
				"Pid",     pid,
				"TmpFile", tmp_file,
				"OnDone",  IsSet(OnDone) ? OnDone : unset
			)
			_SR_EnsurePoller()
		} catch as Err {
			LoggerError("adapters.shell_runner", "spawn.start() failed for '%s': %s", Executable, Err.Message)
			; Clean up temp file if Run threw before creating the process.
			try FileDelete(tmp_file)
		}
	}

	handle.terminate := () => {
		if pid != 0 {
			try ProcessClose(pid)
			pid := 0
		}
		_SR_ActiveTasks.Delete(task_id)
		try FileDelete(tmp_file)
	}

	return handle
}


; ===================================
; ===== 3.1) Completion Poller ======
; ===================================

; Ensures the global completion-poll timer is running.
; Called lazily when the first task is spawned.
_SR_EnsurePoller() {
	if !_SR_PollRunning {
		_SR_PollRunning := true
		SetTimer(_SR_Poll, _SR_POLL_INTERVAL_MS)
	}
}

; Periodic timer: checks every active task and fires OnDone when the process exits.
; Self-disarms when no tasks remain so it consumes no CPU at idle.
_SR_Poll() {
	if _SR_ActiveTasks.Count = 0 {
		_SR_PollRunning := false
		SetTimer(_SR_Poll, 0)
		return
	}

	; Iterate over a snapshot so callbacks that add new tasks don't affect this pass.
	for task_id, task in _SR_ActiveTasks.Clone() {
		if ProcessExist(task["Pid"]) {
			continue
		}

		; Process has exited — read stdout and fire the callback.
		local stdout := ""
		local exit_code := _SR_GetExitCode(task["Pid"])

		try {
			local tmp := task["TmpFile"]
			if FileExist(tmp) {
				stdout := Trim(FileRead(tmp), "`r`n")
				FileDelete(tmp)
			}
		} catch {
			; Best-effort — missing temp file is not fatal.
		}

		_SR_ActiveTasks.Delete(task_id)

		if task.Has("OnDone") and IsObject(task["OnDone"]) {
			try {
				task["OnDone"].Call(exit_code, stdout, "")
			} catch as Err {
				LoggerError("adapters.shell_runner", "on_done callback threw: %s", Err.Message)
			}
		}
	}
}

; Retrieves the exit code of a process that has already exited via OpenProcess +
; GetExitCodeProcess. Returns 0 when the handle cannot be opened (process
; already collected by the OS or PID recycled).
_SR_GetExitCode(Pid) {
	; PROCESS_QUERY_LIMITED_INFORMATION = 0x1000 — minimum rights for exit code.
	local h := DllCall("OpenProcess", "UInt", 0x1000, "Int", false, "UInt", Pid, "Ptr")
	if !h {
		return 0
	}
	local code := 0
	DllCall("GetExitCodeProcess", "Ptr", h, "UInt*", &code)
	DllCall("CloseHandle", "Ptr", h)
	; STILL_ACTIVE (259) means the process is still running; treat as 0.
	return (code = 259) ? 0 : code
}
