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
; no counterpart in _shared/core/ports/ — it wraps Windows-only process spawning.
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
		LoggerError("adapters.shell_runner", "exec() failed for '{1}': {2}", Cmd, Err.Message)
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
	; ++ is a read-modify-write; without this declaration AHK v2 defaults the
	; assigned name to a function-local (shadowing the module global), which
	; starts unassigned and throws on the pre-increment.
	global _SR_TaskCounter
	local task_id := ++_SR_TaskCounter
	local tmp_file := A_Temp . "\ergopti_sr_" . task_id . ".tmp"

	; Build the inner "Executable Arg1 Arg2 ..." command with quoted arguments.
	; A literal double-quote inside an Arg must be escaped by DOUBLING it.
	; A backtick-quote escape is a no-op inside a single-quoted AHK v2 string
	; literal (the backtick is discarded, leaving a bare quote behind — the
	; previous StrReplace(Arg, '"', '`"') call never actually changed Arg,
	; confirmed empirically by comparing StrLen before/after). Doubling is
	; also the form Run() itself needs: it launches via ShellExecute rather
	; than a raw CreateProcess argv split, and a backslash-quote escape was
	; empirically swallowed by Run(), silently aborting the spawn entirely.
	local inner_cmd := '"' . Executable . '"'
	for Arg in Args {
		inner_cmd .= ' "' . StrReplace(Arg, '"', '""') . '"'
	}

	; Route through A_ComSpec /c so the redirection tokens are interpreted by
	; a real shell instead of becoming literal argv noise passed straight to
	; Executable via ShellExecute (the bug this fix addresses: Run(cmd, ...)
	; with no shell in the picture never redirects anything for a genuine
	; external program). Mirrors ShellRunner_Exec just above: the WHOLE tail
	; (inner_cmd AND the redirection) must be wrapped in one more outer quote
	; pair, because cmd.exe's /c only strips a wrapping quote pair when the
	; FIRST and LAST character after /c are both a quote — leaving the
	; redirection outside that pair makes the last character `1` instead and
	; the strip never fires.
	local cmd := A_ComSpec . ' /c "' . inner_cmd . ' > "' . tmp_file . '" 2>&1"'

	local started   := false
	local pid       := 0
	local handle    := {}

	; AHK v2 fat-arrow bodies must be a single expression — a multi-statement
	; block after `=>` is a parse error that aborts tokenising the WHOLE
	; compilation unit (ErgoptiPlus.ahk #Includes this adapter). Nested named
	; functions close over the enclosing locals the same way, so start()/
	; terminate() are defined as ordinary nested functions instead.
	_SR_HandleStart(*) {
		if started {
			return true
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
			return true
		} catch as Err {
			LoggerError("adapters.shell_runner", "spawn.start() failed for '{1}': {2}", Executable, Err.Message)
			; Clean up temp file if Run threw before creating the process.
			try FileDelete(tmp_file)
			return false
		}
	}

	_SR_HandleTerminate(*) {
		if pid != 0 {
			; ShellRunner launches through cmd.exe for redirection. Killing only that
			; shell can orphan a child PowerShell worker after Suspend, so terminate
			; the complete process tree before the best-effort direct fallback.
			try Run(A_ComSpec . " /c taskkill /pid " . pid . " /t /f >nul 2>&1", , "Hide")
			try ProcessClose(pid)
			pid := 0
		}
		; Map.Delete() throws "Item has no value" on a key that was never
		; inserted — terminate() must stay a no-op when start() never ran.
		if _SR_ActiveTasks.Has(task_id) {
			_SR_ActiveTasks.Delete(task_id)
		}
		try FileDelete(tmp_file)
	}

	handle.start     := _SR_HandleStart
	handle.terminate := _SR_HandleTerminate

	return handle
}


; ===================================
; ===== 3.1) Completion Poller ======
; ===================================

; Ensures the global completion-poll timer is running.
; Called lazily when the first task is spawned.
_SR_EnsurePoller() {
	; Assigned below (line "_SR_PollRunning := true"), so without this
	; declaration AHK v2 treats the name as a function-local for the WHOLE
	; function body — the read on the very next line then throws "This local
	; variable has not been assigned a value" instead of seeing the module
	; global's current state.
	global _SR_PollRunning
	if !_SR_PollRunning {
		_SR_PollRunning := true
		SetTimer(_SR_Poll, _SR_POLL_INTERVAL_MS)
	}
}

; Periodic timer: checks every active task and fires OnDone when the process exits.
; Self-disarms when no tasks remain so it consumes no CPU at idle.
_SR_Poll() {
	; Same auto-local shadowing hazard as _SR_EnsurePoller() above — this
	; function also assigns _SR_PollRunning.
	global _SR_PollRunning
	if _SR_ActiveTasks.Count = 0 {
		_SR_PollRunning := false
		SetTimer(_SR_Poll, 0)
		return
	}

	; This periodic SetTimer bypasses native Suspend() (only Hotkeys/Hotstrings
	; are disarmed) — skip firing OnDone callbacks while paused. Tasks stay in
	; _SR_ActiveTasks and the next tick after resume picks them back up; the
	; timer itself is left armed (unlike the empty-queue branch above) since
	; there is still work pending.
	if A_IsSuspended
		return

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
				LoggerError("adapters.shell_runner", "on_done callback threw: {1}", Err.Message)
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
