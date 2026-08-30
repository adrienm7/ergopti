; modules/llm/api_ollama/ollama_http.ahk

; ==============================================================================
; MODULE: Ollama API — Sync HTTP Client
; DESCRIPTION:
; Synchronous and asynchronous HTTP helpers for the Ollama inference server.
; Covers the reachability probe, model listing, model deletion, and the core
; async generation dispatch / polling loop used by the prediction engine.
; ==============================================================================

; =====================================
; =====================================
; ======= 2/ Sync HTTP Client =========
; =====================================
; =====================================

_LLM_CurlTerminalPaths(BasePath) {
	return Map("status", BasePath . ".status", "exit", BasePath . ".exit")
}

; One retry owner retains both private curl artifacts and exact process handles.
; Callers may retire immediately without turning a transient delete, terminate
; or close refusal into an unowned file, credential or child-process leak.
global _LLM_CurlCleanupDebt := Map()
global _LLM_CurlCleanupDebtCounter := 0
global _LLM_CurlCleanupRetryTimer := 0
global LLM_CURL_CLEANUP_RETRY_MS := 50

_LLM_CurlTryCleanupPaths(Paths, DeleteFn) {
	Pending := []
	for Path in Paths {
		if !(Path is String) or Path == ""
			continue
		Deleted := false
		try Deleted := DeleteFn.Call(Path) == true
		catch
			try LoggerWarn("LLM.transport", "Private curl artifact cleanup attempt raised an error.")
		if !Deleted
			Pending.Push(Path)
	}
	return Pending
}

_LLM_CurlScheduleCleanupRetry() {
	global _LLM_CurlCleanupRetryTimer, LLM_CURL_CLEANUP_RETRY_MS
	PreviousCritical := Critical("On")
	try {
		if HasMethod(_LLM_CurlCleanupRetryTimer, "Call")
			return true
		RetryTimer := (*) => LLM_CurlRetryCleanupDebt()
		_LLM_CurlCleanupRetryTimer := RetryTimer
	} finally Critical(PreviousCritical)
	try {
		SetTimer(RetryTimer, -LLM_CURL_CLEANUP_RETRY_MS)
		return true
	} catch as Err {
		PreviousCritical := Critical("On")
		try {
			if (_LLM_CurlCleanupRetryTimer == RetryTimer)
				_LLM_CurlCleanupRetryTimer := 0
		} finally Critical(PreviousCritical)
		try LoggerError("LLM.transport", "Could not schedule curl cleanup retry: {1}.", Err.Message)
		return false
	}
}

_LLM_CurlRetainCleanupDebt(Paths, DeleteFn) {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupDebtCounter
	PreviousCritical := Critical("On")
	try {
		_LLM_CurlCleanupDebtCounter += 1
		DebtId := _LLM_CurlCleanupDebtCounter
		_LLM_CurlCleanupDebt[DebtId] := Map(
			"kind", "paths", "paths", Paths, "delete", DeleteFn,
			"running", false)
	} finally Critical(PreviousCritical)
	try LoggerWarn("LLM.transport", "Retaining private curl artifacts for cleanup retry.")
	_LLM_CurlScheduleCleanupRetry()
	return false
}

_LLM_CurlClaimProcessCleanupDebt(ProcessOwner, Terminate, Port) {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupDebtCounter
	AlreadyRetained := false
	PreviousCritical := Critical("On")
	try {
		DebtId := ProcessOwner.Get("cleanup_debt_id", 0)
		if DebtId && _LLM_CurlCleanupDebt.Has(DebtId) {
			Record := _LLM_CurlCleanupDebt[DebtId]
			if (Record.Get("kind", "") == "process"
					&& ObjPtr(Record["owner"]) == ObjPtr(ProcessOwner)) {
				Record["terminate"] := Record["terminate"] || Terminate
				AlreadyRetained := true
			}
		}
		if !AlreadyRetained {
			_LLM_CurlCleanupDebtCounter += 1
			DebtId := _LLM_CurlCleanupDebtCounter
			ProcessOwner["cleanup_debt_id"] := DebtId
			_LLM_CurlCleanupDebt[DebtId] := Map(
				"kind", "process", "owner", ProcessOwner,
				"terminate", Terminate, "port", Port, "running", false)
		}
	} finally Critical(PreviousCritical)
	return !AlreadyRetained
}

_LLM_CurlRetireProcessCleanupDebt(ProcessOwner) {
	global _LLM_CurlCleanupDebt
	PreviousCritical := Critical("On")
	try {
		DebtId := ProcessOwner.Get("cleanup_debt_id", 0)
		if DebtId && _LLM_CurlCleanupDebt.Has(DebtId) {
			Record := _LLM_CurlCleanupDebt[DebtId]
			if (Record.Get("kind", "") == "process"
					&& ObjPtr(Record["owner"]) == ObjPtr(ProcessOwner))
				_LLM_CurlCleanupDebt.Delete(DebtId)
		}
		ProcessOwner["cleanup_debt_id"] := 0
	} finally Critical(PreviousCritical)
}

; Transfers any failed deletion into a process-owned retry debt. The caller may
; safely retire its request entry immediately because the debt owns the paths.
LLM_CurlCleanupPaths(Paths, DeleteFn := 0) {
	if !(Paths is Array)
		return true
	if !HasMethod(DeleteFn, "Call")
		DeleteFn := FSDelete
	Pending := _LLM_CurlTryCleanupPaths(Paths, DeleteFn)
	if Pending.Length == 0
		return true
	return _LLM_CurlRetainCleanupDebt(Pending, DeleteFn)
}

_LLM_CurlRetryCleanupRecord(DebtId, ExpectedRecord) {
	global _LLM_CurlCleanupDebt
	PreviousCritical := Critical("On")
	try {
		if !_LLM_CurlCleanupDebt.Has(DebtId)
			return false
		Record := _LLM_CurlCleanupDebt[DebtId]
		if ObjPtr(Record) != ObjPtr(ExpectedRecord) or Record["running"]
			return false
		Record["running"] := true
	} finally Critical(PreviousCritical)
	Kind := Record.Get("kind", "paths")
	if Kind == "process" {
		Complete := _LLM_CurlTryReleaseProcess(Record["owner"],
			Record["terminate"], Record["port"])
	} else {
		Pending := _LLM_CurlTryCleanupPaths(Record["paths"], Record["delete"])
		Complete := Pending.Length == 0
	}
	PreviousCritical := Critical("On")
	try {
		if _LLM_CurlCleanupDebt.Has(DebtId)
				and ObjPtr(_LLM_CurlCleanupDebt[DebtId]) == ObjPtr(Record) {
			if Complete {
				_LLM_CurlCleanupDebt.Delete(DebtId)
				if Kind == "process"
					Record["owner"]["cleanup_debt_id"] := 0
			} else {
				if Kind == "paths"
					Record["paths"] := Pending
				Record["running"] := false
			}
		}
	} finally Critical(PreviousCritical)
	return Complete
}

LLM_CurlRetryCleanupDebt() {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupRetryTimer
	PreviousCritical := Critical("On")
	try {
		_LLM_CurlCleanupRetryTimer := 0
		Snapshot := _LLM_CurlCleanupDebt.Clone()
	} finally Critical(PreviousCritical)
	for DebtId, Record in Snapshot
		_LLM_CurlRetryCleanupRecord(DebtId, Record)
	PreviousCritical := Critical("On")
	try Pending := _LLM_CurlCleanupDebt.Count > 0
	finally Critical(PreviousCritical)
	if Pending
		_LLM_CurlScheduleCleanupRetry()
	return !Pending
}

_LLM_CurlArtifactPortFn(Port, Name, DefaultFn) {
	if !(Port is Map) or !Port.Has(Name)
		return DefaultFn
	Candidate := Port[Name]
	if !HasMethod(Candidate, "Call")
		throw TypeError("curl artifact port '" . Name . "' must be callable")
	return Candidate
}

_LLM_OllamaAuxOwner(Owner, Kind, Identity := "") {
	global LLM_OLLAMA_BASE_URL
	if Owner is Map
		return Owner
	return LLM_AuxBegin(Kind, Map(
		"backend", "ollama",
		"endpoint", LLM_OLLAMA_BASE_URL,
		"identity", Identity))
}

_LLM_OllamaInvokeAuxResult(Owner, Callback, Value) {
	if !LLM_AuxIsCurrent(Owner)
		return false
	try _LLM_InvokeCallback(Callback, "on_result", Value)
	finally LLM_AuxFinish(Owner)
	return true
}

_LLM_OllamaAuxDeletePaths(Paths, DeleteFn := 0) {
	; The shared cleanup debt now owns any locked artifact, so the auxiliary
	; lifecycle must not keep a second finalizer that duplicates each retry.
	LLM_CurlCleanupPaths(Paths, DeleteFn)
	return true
}

_LLM_CurlArtifactRun(Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	; CreateProcessW returns the process HANDLE in the same successful native call
	; that creates the child. There is no post-launch OpenProcess gap in which a
	; live curl child can exist without a cancellable exact-object receipt.
	CommandBuffer := Buffer((StrLen(Command) + 1) * 2, 0)
	StrPut(Command, CommandBuffer, "UTF-16")
	StartupInfo := Buffer(A_PtrSize == 8 ? 104 : 68, 0)
	NumPut("UInt", StartupInfo.Size, StartupInfo, 0)
	ProcessInfo := Buffer(A_PtrSize == 8 ? 24 : 16, 0)
	if !DllCall("Kernel32\CreateProcessW",
			"Ptr", 0, "Ptr", CommandBuffer.Ptr,
			"Ptr", 0, "Ptr", 0, "Int", false,
			"UInt", 0x08000000, "Ptr", 0,
			"Ptr", WorkingDir == "" ? 0 : StrPtr(WorkingDir),
			"Ptr", StartupInfo.Ptr, "Ptr", ProcessInfo.Ptr, "Int")
		throw Error("CreateProcessW failed (Win32 " . A_LastError . ").")
	ProcessHandle := NumGet(ProcessInfo, 0, "Ptr")
	ThreadHandle := NumGet(ProcessInfo, A_PtrSize, "Ptr")
	Pid := NumGet(ProcessInfo, A_PtrSize * 2, "UInt")
	try {
		if !ProcessHandle or !IsInteger(Pid) or Pid <= 0
			throw Error("CreateProcessW returned an invalid curl owner receipt.")
		ProcessOwner := Map("pid", Pid, "handle", ProcessHandle,
			"released", false, "releasing", false,
			"cleanup_debt_id", 0)
		ProcessHandle := 0
	} finally {
		if ThreadHandle
			DllCall("Kernel32\CloseHandle", "Ptr", ThreadHandle)
		if ProcessHandle {
			DllCall("Kernel32\TerminateProcess", "Ptr", ProcessHandle, "UInt", 1)
			DllCall("Kernel32\CloseHandle", "Ptr", ProcessHandle)
		}
	}
}

_LLM_CurlRunOwned(RunFn, Command, WorkingDir, Options, &Pid, Port := 0) {
	ProcessOwner := 0
	try RunFn.Call(Command, WorkingDir, Options, &Pid, &ProcessOwner)
	catch as Err {
		if ProcessOwner is Map
			_LLM_CurlReleaseProcess(ProcessOwner, true, Port)
		throw Err
	}
	if !(ProcessOwner is Map) or ProcessOwner.Get("released", true)
			or !ProcessOwner.Get("handle", 0)
		throw Error("Curl launcher returned without an exact process owner.")
	if ProcessOwner.Get("pid", 0) != Pid {
		_LLM_CurlReleaseProcess(ProcessOwner, true, Port)
		throw Error("Curl launcher returned mismatched process ownership.")
	}
	return ProcessOwner
}

_LLM_CurlArtifactTick(*) {
	return A_TickCount
}

_LLM_CurlOwnedCommand(CurlCommand, StatusPath, ExitPath) {
	return A_ComSpec . ' /D /V:ON /S /C ""' . CurlCommand
		. ' --write-out "%{http_code}" > ' . _Q(StatusPath)
		. ' & set "_ergopti_ec=!errorlevel!"'
		. ' & > ' . _Q(ExitPath) . ' echo !_ergopti_ec!'
		. ' & exit /b !_ergopti_ec!"'
}

_LLM_CurlOpenProcessExact(Pid) {
	; A retained process HANDLE identifies the exact kernel object even after its
	; numeric PID is recycled. PROCESS_TERMINATE is the only destructive right;
	; SYNCHRONIZE lets future owners wait on this exact object without reopening it.
	return DllCall("Kernel32\OpenProcess", "UInt", 0x00100001,
		"Int", false, "UInt", Pid, "Ptr")
}

_LLM_CurlTerminateProcessExact(Handle) {
	return DllCall("Kernel32\TerminateProcess", "Ptr", Handle,
		"UInt", 1, "Int") != 0
}

_LLM_CurlWaitProcessExact(Handle) {
	return DllCall("Kernel32\WaitForSingleObject", "Ptr", Handle,
		"UInt", 0, "UInt")
}

_LLM_CurlCloseProcessExact(Handle) {
	return DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int") != 0
}

_LLM_CurlAdoptProcess(Pid, Port := 0) {
	OpenFn := _LLM_CurlArtifactPortFn(Port, "open_process", _LLM_CurlOpenProcessExact)
	if !IsInteger(Pid) or Pid <= 0
		throw ValueError("Cannot adopt curl without a positive process id.", -1, Pid)
	try Handle := OpenFn.Call(Pid)
	catch as Err {
		try LoggerError("LLM.transport",
			"Failed to retain the exact curl process handle for PID {1}: {2}.",
			Pid, Err.Message)
		throw Error("Failed to retain the exact curl process handle for PID "
			. Pid . ".", -1, Err.Message)
	}
	if !Handle {
		try LoggerError("LLM.transport",
			"Failed to retain the exact curl process handle for PID {1} (win32={2}).",
			Pid, A_LastError)
		throw Error("Failed to retain the exact curl process handle for PID "
			. Pid . ".", -1, "win32=" . A_LastError)
	}
	return Map("pid", IsInteger(Pid) ? Pid : 0,
		"handle", Handle, "released", false,
		"releasing", false, "cleanup_debt_id", 0)
}

_LLM_CurlTryReleaseProcess(ProcessOwner, Terminate := false, Port := 0) {
	if !(ProcessOwner is Map)
		return true
	Handle := 0
	PreviousCritical := Critical("On")
	try {
		if ProcessOwner.Get("released", false)
			return true
		if ProcessOwner.Get("releasing", false)
			return false
		Handle := ProcessOwner.Get("handle", 0)
		if !Handle
			return false
		ProcessOwner["releasing"] := true
	} finally Critical(PreviousCritical)
	try {
		if Terminate {
			TerminateFn := _LLM_CurlArtifactPortFn(Port,
				"terminate_process", _LLM_CurlTerminateProcessExact)
			Terminated := false
			try Terminated := TerminateFn.Call(Handle) == true
			if !Terminated {
				WaitFn := _LLM_CurlArtifactPortFn(Port,
					"wait_process", _LLM_CurlWaitProcessExact)
				try Terminated := WaitFn.Call(Handle) = 0
			}
			if !Terminated
				return false
		}
		CloseFn := _LLM_CurlArtifactPortFn(Port,
			"close_process", _LLM_CurlCloseProcessExact)
		Closed := false
		try Closed := CloseFn.Call(Handle) == true
		if !Closed
			return false
		PreviousCritical := Critical("On")
		try {
			ProcessOwner["handle"] := 0
			ProcessOwner["released"] := true
		} finally Critical(PreviousCritical)
		return true
	} finally {
		PreviousCritical := Critical("On")
		try ProcessOwner["releasing"] := false
		finally Critical(PreviousCritical)
	}
}

_LLM_CurlReleaseProcess(ProcessOwner, Terminate := false, Port := 0) {
	if !(ProcessOwner is Map)
		return true
	; Keep failure-to-debt transfer atomic against another AHK thread. Native
	; operations here are non-blocking: TerminateProcess, zero-time wait and close.
	NewDebt := false
	PreviousCritical := Critical("On")
	try {
		if _LLM_CurlTryReleaseProcess(ProcessOwner, Terminate, Port) {
			_LLM_CurlRetireProcessCleanupDebt(ProcessOwner)
			return true
		}
		NewDebt := _LLM_CurlClaimProcessCleanupDebt(
			ProcessOwner, Terminate, Port)
	} finally Critical(PreviousCritical)
	if NewDebt
		try LoggerWarn("LLM.transport",
			"Retaining an exact curl process handle for cleanup retry.")
	_LLM_CurlScheduleCleanupRetry()
	return false
}

_LLM_CurlReleaseEntryProcess(Entry, Terminate := false, Port := 0) {
	if !(Entry is Map) or !Entry.Has("process_owner")
		return true
	return _LLM_CurlReleaseProcess(Entry["process_owner"], Terminate, Port)
}

_LLM_CurlProcessExited(ProcessOwner, Port := 0) {
	if !(ProcessOwner is Map) or ProcessOwner.Get("released", false)
		return true
	Handle := ProcessOwner.Get("handle", 0)
	if !Handle
		return false
	WaitFn := _LLM_CurlArtifactPortFn(Port,
		"wait_process", _LLM_CurlWaitProcessExact)
	try Result := WaitFn.Call(Handle)
	catch
		return false
	; WAIT_OBJECT_0 is the sole proof that this exact retained process exited.
	return Result = 0
}

_LLM_CurlMaxFileSizeArg(CurlExe := "", VersionFn := 0) {
	global HTTP_CURL_MAX_RESPONSE_BYTES
	if CurlExe == ""
		CurlExe := A_WinDir . "\System32\curl.exe"
	if !_HTTP_CurlRuntimeLimitSupported(CurlExe, VersionFn)
		throw Error("curl cannot enforce the live response-size limit.")
	return "--max-filesize " . HTTP_CURL_MAX_RESPONSE_BYTES . " "
}

_LLM_CurlReadTerminal(StatusPath, ExitPath, BodyPath, MaxBodyBytes := 0,
		ReadFn := 0, SizeFn := 0) {
	global HTTP_CURL_MAX_RESPONSE_BYTES
	if !IsObject(ReadFn)
		ReadFn := FileRead
	if !IsObject(SizeFn)
		SizeFn := FileGetSize
	if MaxBodyBytes <= 0
		MaxBodyBytes := HTTP_CURL_MAX_RESPONSE_BYTES
	Result := Map("complete", false, "exit", -1,
		"status", 0, "body_read", false, "oversize", false, "body", "")
	try {
		ExitText := Trim(ReadFn.Call(ExitPath, "UTF-8-RAW"))
		if RegExMatch(ExitText, "^-?\d+$") {
			Result["exit"] := Integer(ExitText)
			; _LLM_CurlOwnedCommand writes this file last. A valid integer is the
			; durable commit receipt; PID liveness is only advisory and can be stale.
			Result["complete"] := true
		}
	}
	if !Result["complete"]
		return Result
	try {
		StatusText := Trim(ReadFn.Call(StatusPath, "UTF-8-RAW"))
		if RegExMatch(StatusText, "^\d{3}$")
			Result["status"] := Integer(StatusText)
	}
	try {
		if SizeFn.Call(BodyPath) > MaxBodyBytes {
			Result["oversize"] := true
			return Result
		}
		Result["body"] := ReadFn.Call(BodyPath, "UTF-8-RAW")
		Result["body_read"] := true
	}
	return Result
}

_LLM_CurlTerminalComplete(Result) {
	if !(Result is Map)
		return false
	; Preserve deterministic legacy fixtures which predate the explicit field.
	return Result.Get("complete", false)
		or (Result.Has("exit") and Result["exit"] != -1)
}

_LLM_CurlTerminalOk(Result) {
	return Result is Map and Result["exit"] = 0 and Result["body_read"]
		and Result["status"] >= 200 and Result["status"] < 300
}

_LLM_OllamaPingTerminalOk(ExitCode, HttpStatus, BodyRead, Body) {
	if (ExitCode != 0 or HttpStatus < 200 or HttpStatus >= 300 or !BodyRead)
		return false
	try Root := JsonParse(Body)
	catch
		return false
	return Root is Map and Root.Has("version") and Type(Root["version"]) = "String"
		and Root["version"] != ""
}

_LLM_OllamaDeleteTerminalOk(ExitCode, HttpStatus, BodyRead, Body) {
	return ExitCode = 0 and HttpStatus >= 200 and HttpStatus < 300 and BodyRead
}

_LLM_OllamaFinishDelete(Terminal, tag, on_result, SuccessFn := LoggerSuccess, WarnFn := LoggerWarn) {
	ok := _LLM_OllamaDeleteTerminalOk(
		Terminal["exit"], Terminal["status"], Terminal["body_read"], Terminal["body"])
	try {
		if ok
			SuccessFn.Call("LLM.ollama", "Deleted Ollama model '{1}'.", tag)
		else
			WarnFn.Call("LLM.ollama", "Ollama delete '{1}' failed (exit={2}, status={3}, body_chars={4}).",
				tag, Terminal["exit"], Terminal["status"], StrLen(Terminal["body"]))
	}
	_LLM_InvokeCallback(on_result, "on_result", ok)
	return ok
}

/**
 * Sends a JSON body via WinHTTP. Async ``Open(..., true)`` rejects ADODB binary
 * SafeArrays (hard failure / E_NOINTERFACE); sync mode tolerated them but the
 * prediction engine is async-only. ``_LLM_Ollama_EscapeJSON`` keeps the wire
 * form ASCII via ``\uXXXX`` so ``Send(string)`` is safe for accented context.
 */
_LLM_Ollama_SendUtf8(http, payload) {
	http.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
	http.Send(payload)
}

/**
 * Sends a prompt to Ollama and returns the generated text (blocking).
 * Kept for legacy call sites (test harnesses, manual probes). The prediction
 * engine uses the async surface below.
 * @param {string} model - Ollama model tag (e.g. "qwen2.5:3b").
 * @param {string} system_prompt - System instruction injected before the user context.
 * @param {string} user_text - The user context / completion seed.
 * @param {number} temperature - Sampling temperature (0.0–2.0).
 * @returns {string} The generated text, or "" on error.
 */
LLM_OllamaIsReady() {
	global _LLM_Ollama_IsReady
	return _LLM_Ollama_IsReady
}

/**
 * True when predictions may hit Ollama: warmup succeeded, or the server was
 * reachable long enough that blocking forever is worse than a slow first token.
 */
LLM_OllamaAllowInference() {
	global _LLM_Ollama_IsReady, _LLM_Ollama_WarmupStartedTick
	if _LLM_Ollama_IsReady
		return true
	if !(IsSet(LLM_Deps_IsReady) and LLM_Deps_IsReady())
		return false
	if (_LLM_Ollama_WarmupStartedTick > 0
			and (A_TickCount - (_LLM_Ollama_WarmupStartedTick) & 0xFFFFFFFF) >= 8000)
		return true
	return false
}

/**
 * Async health probe — same intent as LLM_OllamaIsRunning but never blocks
 * the AHK message loop. Invokes ``on_result(bool)`` from a polling tick.
 * Used by the tray menu's rebuild path so the health dot reflects the
 * current state without making the menu open feel sluggish.
 *
 * @param {function} on_result - Callback receiving the boolean reachability.
 */
LLM_OllamaIsRunning_Async(on_result, Owner := 0) {
	; curl CHILD PROCESS, not WinHTTP. The WinHttpRequest.5.1 COM object's "async"
	; mode (Open(...,true) + Send()) still performs the TCP connect synchronously on
	; the CALLING (message-loop) thread: against a cold/busy local daemon that connect
	; blocked for up to ~9 s at boot — freezing the tray build AND keystroke/cancel
	; handling (the menu build that ran during the boot bootstrap was measured stuck
	; for ~14 s entirely on this). It is the same reason the generation path already
	; uses curl. A curl child does the connect in its OWN process; we only poll
	; its terminal sidecar (instant), so the AHK message loop is NEVER blocked.
	Owner := _LLM_OllamaAuxOwner(Owner, "ollama_ping")
	try {
		uid := _LLM_Ollama_NextStreamUid()
		tmp_out := _LLM_Ollama_TempDir() . "\ergopti_ollama_ping_" . uid . ".out"
		terminal := _LLM_CurlTerminalPaths(tmp_out)
		Paths := [tmp_out, terminal["status"], terminal["exit"]]
		if !LLM_AuxBindResources(Owner, Map(
				"finalizer", _LLM_OllamaAuxDeletePaths.Bind(Paths)))
			return Owner
		curl_exe := A_WinDir . "\System32\curl.exe"
		; -m 2: hard 2 s ceiling. A local daemon answers GET /api/version in < 50 ms;
		; one that needs longer is "not ready yet" for our purposes — the deps poll
		; retries, and the health tick re-probes, so a slow first answer self-heals.
		curlCmd := '"' . curl_exe . '" -s -m 2 '
			. _LLM_CurlMaxFileSizeArg() . '-o ' . _Q(tmp_out) . ' '
			. _Q(LLM_OLLAMA_BASE_URL . "/api/version")
		cmd := _LLM_CurlOwnedCommand(curlCmd, terminal["status"], terminal["exit"])
		pid := 0
		ProcessOwner := 0
		PreviousCritical := Critical("On")
		try {
			ProcessOwner := _LLM_CurlRunOwned(_LLM_CurlArtifactRun,
				cmd, "", "Hide", &pid)
			if !LLM_AuxBindResources(Owner, Map(
					"process_pid", pid,
					"process_owner", ProcessOwner,
					"cancel", _LLM_CurlReleaseProcess.Bind(ProcessOwner, true)))
				return Owner
		} finally Critical(PreviousCritical)
		_LLM_Ollama_PingPoll(ProcessOwner, tmp_out, terminal["status"], terminal["exit"], on_result, A_TickCount, Owner)
	} catch {
		if ProcessOwner is Map
			_LLM_CurlReleaseProcess(ProcessOwner, true)
		_LLM_OllamaInvokeAuxResult(Owner, on_result, false)
	}
	return Owner
}

/**
 * Polls a reachability-ping curl child WITHOUT blocking the message loop. Reachable
 * requires a successful curl exit, 2xx status, readable body, and the canonical
 * ``GET /api/version`` JSON schema. Mirrors the generation poll at a shorter bound.
 * @param {Map}      ProcessOwner - Exact retained curl process HANDLE owner.
 * @param {string}   tmp_out    - Temp file curl writes the response body to.
 * @param {function} on_result  - Callback receiving the boolean reachability.
 * @param {integer}  start_tick - A_TickCount at dispatch, for the deadline backstop.
 */
_LLM_Ollama_PingPoll(ProcessOwner, tmp_out, tmp_status, tmp_exit, on_result, start_tick, Owner, Port := 0) {
	if !LLM_AuxIsCurrent(Owner)
		return
	ReadTerminalFn := _LLM_CurlArtifactPortFn(Port,
		"read_terminal", _LLM_CurlReadTerminal)
	Terminal := ReadTerminalFn.Call(tmp_status, tmp_exit, tmp_out)
	if _LLM_CurlTerminalComplete(Terminal) {
		_LLM_CurlReleaseProcess(ProcessOwner, false, Port)
		reachable := _LLM_OllamaPingTerminalOk(Terminal["exit"], Terminal["status"], Terminal["body_read"], Terminal["body"])
		_LLM_OllamaInvokeAuxResult(Owner, on_result, reachable)
		return
	}
	; Curl owns a 2 s max-time; this 4 s backstop retires a missing receipt.
	if _LLM_DeadlineExpired(start_tick, 4000) {
		_LLM_CurlReleaseProcess(ProcessOwner, true, Port)
		_LLM_OllamaInvokeAuxResult(Owner, on_result, false)
		return
	}
	LLM_AuxSchedule(Owner,
		() => _LLM_Ollama_PingPoll(ProcessOwner, tmp_out, tmp_status, tmp_exit,
			on_result, start_tick, Owner, Port), -150)
}

/**
 * Extracts the model tag names from an Ollama ``GET /api/tags`` JSON body. Shared
 * by ``LLM_OllamaListModels_Async`` so parsing remains independent from the
 * child-process transport.
 * @param {string} raw - Raw JSON response text from /api/tags.
 * @returns {Array} Array of tag-name strings (empty when none / on no match).
 */
_LLM_Ollama_ParseTagNames(raw) {
	models := []
	try Root := JsonParse(raw)
	catch
		return models
	if !(Root is Map) or !Root.Has("models") or !(Root["models"] is Array)
		return models
	for Row in Root["models"] {
		if !(Row is Map) or !Row.Has("name") or Type(Row["name"]) != "String" or Row["name"] == ""
			continue
		models.Push(Row["name"])
	}
	return models
}

/**
 * Fetches the locally-installed
 * model tags from ``GET /api/tags`` through a curl child + a polling tick
 * (mirrors ``LLM_OllamaIsRunning_Async``), so the keyboard/menu thread is NEVER
 * frozen on a cold or slow daemon. The blocking version, called per catalogue row
 * at every tray rebuild past the installed-cache TTL, stalled the menu (and dropped
 * keystrokes) for up to ~20 s — the UI must read only the in-memory cache and let
 * THIS function refresh it in the background (AUDIT_AHK_2026-06-19 / TODO.md).
 * @param {function} on_result - Callback receiving an Array of tag names ([] on failure).
 */
LLM_OllamaListModels_Async(on_result, Owner := 0) {
	; curl CHILD PROCESS, not WinHTTP — identical reasoning to LLM_OllamaIsRunning_Async:
	; WinHttpRequest async mode (Open(...,true) + Send()) still performs the TCP connect
	; SYNCHRONOUSLY on the calling thread, so against a busy daemon it could block the
	; tray build (which runs under Critical) for up to its timeout. curl does the connect
	; in its own process; we only poll its terminal sidecar, so the loop never blocks.
	Owner := _LLM_OllamaAuxOwner(Owner, "ollama_tags")
	try {
		uid := _LLM_Ollama_NextStreamUid()
		tmp_out := _LLM_Ollama_TempDir() . "\ergopti_ollama_tags_" . uid . ".out"
		terminal := _LLM_CurlTerminalPaths(tmp_out)
		Paths := [tmp_out, terminal["status"], terminal["exit"]]
		if !LLM_AuxBindResources(Owner, Map(
				"finalizer", _LLM_OllamaAuxDeletePaths.Bind(Paths)))
			return Owner
		curl_exe := A_WinDir . "\System32\curl.exe"
		; -m 2: a local daemon lists installed tags in well under a second; a slower
		; answer is "not ready" — the installed-cache TTL re-probes on the next rebuild.
		curlCmd := '"' . curl_exe . '" -s -m 2 '
			. _LLM_CurlMaxFileSizeArg() . '-o ' . _Q(tmp_out) . ' '
			. _Q(LLM_OLLAMA_BASE_URL . "/api/tags")
		cmd := _LLM_CurlOwnedCommand(curlCmd, terminal["status"], terminal["exit"])
		pid := 0
		ProcessOwner := 0
		PreviousCritical := Critical("On")
		try {
			ProcessOwner := _LLM_CurlRunOwned(_LLM_CurlArtifactRun,
				cmd, "", "Hide", &pid)
			if !LLM_AuxBindResources(Owner, Map(
					"process_pid", pid,
					"process_owner", ProcessOwner,
					"cancel", _LLM_CurlReleaseProcess.Bind(ProcessOwner, true)))
				return Owner
		} finally Critical(PreviousCritical)
		_LLM_Ollama_TagsPoll(ProcessOwner, tmp_out, terminal["status"], terminal["exit"], on_result, A_TickCount, Owner)
	} catch {
		if ProcessOwner is Map
			_LLM_CurlReleaseProcess(ProcessOwner, true)
		_LLM_OllamaInvokeAuxResult(Owner, on_result, [])
	}
	return Owner
}

/**
 * Polls an installed-tags curl child WITHOUT blocking the message loop, then parses
 * the ``GET /api/tags`` body into a tag-name Array (mirrors _LLM_Ollama_PingPoll, but
 * returns the parsed list rather than a boolean). Delivers [] on timeout / empty body.
 * @param {integer}  pid        - curl child PID (0 if Run failed).
 * @param {string}   tmp_out    - Temp file curl writes the response body to.
 * @param {function} on_result  - Callback receiving an Array of tag names ([] on failure).
 * @param {integer}  start_tick - A_TickCount at dispatch, for the deadline backstop.
 */
_LLM_Ollama_TagsPoll(ProcessOwner, tmp_out, tmp_status, tmp_exit, on_result, start_tick, Owner, Port := 0) {
	if !LLM_AuxIsCurrent(Owner)
		return
	ReadTerminalFn := _LLM_CurlArtifactPortFn(Port,
		"read_terminal", _LLM_CurlReadTerminal)
	Terminal := ReadTerminalFn.Call(tmp_status, tmp_exit, tmp_out)
	if _LLM_CurlTerminalComplete(Terminal) {
		_LLM_CurlReleaseProcess(ProcessOwner, false, Port)
		tags := _LLM_CurlTerminalOk(Terminal) ? _LLM_Ollama_ParseTagNames(Terminal["body"]) : []
		_LLM_OllamaInvokeAuxResult(Owner, on_result, tags)
		return
	}
	if _LLM_DeadlineExpired(start_tick, 4000) {
		_LLM_CurlReleaseProcess(ProcessOwner, true, Port)
		_LLM_OllamaInvokeAuxResult(Owner, on_result, [])
		return
	}
	LLM_AuxSchedule(Owner,
		() => _LLM_Ollama_TagsPoll(ProcessOwner, tmp_out, tmp_status, tmp_exit,
			on_result, start_tick, Owner, Port), -150)
}

/**
 * Removes the local copy of an Ollama model via the daemon's
 * ``DELETE /api/delete`` endpoint. Non-blocking — mirrors
 * ``LLM_OllamaListModels_Async``: a curl child performs the request and we
 * only poll the terminal sidecar (instant), so the tray-menu/message-loop thread
 * is never frozen for the DELETE's up-to-10 s round trip. Every sibling
 * Ollama HTTP surface had already been migrated to this pattern; the
 * "Delete model cache" action was the one that was missed (F24).
 *
 * @param {string}   tag       - Ollama model tag (e.g. ``qwen3-coder:30b``).
 * @param {function} on_result - Callback receiving a Boolean (true on success).
 * @param {Map|0}    Port      - Optional deterministic transport seam for tests.
 */
LLM_OllamaDeleteModel_Async(tag, on_result, Port := 0, Owner := 0) {
	global LLM_OLLAMA_BASE_URL, LLM_OLLAMA_DELETE_TIMEOUT_MS
	Owner := _LLM_OllamaAuxOwner(Owner, "ollama_delete:" . tag, tag)
	if (tag == "") {
		_LLM_OllamaInvokeAuxResult(Owner, on_result, false)
		return
	}
	WriteFn := _LLM_CurlArtifactPortFn(Port, "write", FSWrite)
	DeleteFn := _LLM_CurlArtifactPortFn(Port, "delete", FSDelete)
	RunFn := _LLM_CurlArtifactPortFn(Port, "run", _LLM_CurlArtifactRun)
	PollFn := _LLM_CurlArtifactPortFn(Port, "poll", _LLM_Ollama_DeletePoll)
	TempDirFn := _LLM_CurlArtifactPortFn(Port, "temp_dir", _LLM_Ollama_TempDir)
	TickFn := _LLM_CurlArtifactPortFn(Port, "tick", _LLM_CurlArtifactTick)
	tmp_payload := ""
	tmp_out := ""
	try {
		uid := _LLM_Ollama_NextStreamUid()
		tmp_dir := TempDirFn.Call()
		tmp_payload := tmp_dir . "\ergopti_ollama_delete_" . uid . ".json"
		tmp_out     := tmp_dir . "\ergopti_ollama_delete_" . uid . ".out"
		terminal := _LLM_CurlTerminalPaths(tmp_out)
		Paths := [tmp_payload, tmp_out, terminal["status"], terminal["exit"]]
		if !LLM_AuxBindResources(Owner, Map(
				"finalizer", _LLM_OllamaAuxDeletePaths.Bind(Paths, DeleteFn)))
			return Owner
		; The payload is intentionally minimal — Ollama tolerates the
		; ``model`` field too on newer versions, but ``name`` is the
		; documented one and works on every release we care about
		; (mirrors the retired blocking body).
		body := '{"name":"' . StrReplace(tag, '"', '\"') . '"}'
		if !WriteFn.Call(tmp_payload, body) {
			try LoggerWarn("LLM.ollama", "Failed to write delete payload file for '{1}'.", tag)
			_LLM_OllamaInvokeAuxResult(Owner, on_result, false)
			return
		}
		curl_exe := A_WinDir . "\System32\curl.exe"
		curlCmd := '"' . curl_exe . '" -s -S -m '
			. (LLM_OLLAMA_DELETE_TIMEOUT_MS // 1000) . ' '
			. _LLM_CurlMaxFileSizeArg() . '-X DELETE '
			. '-H "Content-Type: application/json" '
			. '--data-binary @' . _Q(tmp_payload) . ' '
			. _Q(LLM_OLLAMA_BASE_URL . "/api/delete") . ' '
			. '-o ' . _Q(tmp_out)
		cmdLine := _LLM_CurlOwnedCommand(curlCmd, terminal["status"], terminal["exit"])
		pid := 0
		ProcessOwner := 0
		launch_blocked := false
		PreviousCritical := Critical("On")
		try {
			; WriteFn can pump a cancellation or endpoint transition. Revalidate the
			; owner at the same atomic launch boundary used by the other curl paths:
			; an invalidated model-delete request must never send its destructive POST.
			if !_LLM_AuxOwnerIsCurrentLocked(Owner) {
				launch_blocked := true
			} else {
				ProcessOwner := _LLM_CurlRunOwned(RunFn, cmdLine, "", "Hide", &pid, Port)
				if !LLM_AuxBindResources(Owner, Map(
						"process_pid", pid,
						"process_owner", ProcessOwner,
						"cancel", _LLM_CurlReleaseProcess.Bind(ProcessOwner, true, Port)))
					return Owner
			}
		} finally Critical(PreviousCritical)
		if launch_blocked
			return Owner
		PollFn.Call(ProcessOwner, tmp_payload, tmp_out, terminal["status"], terminal["exit"], tag, on_result, TickFn.Call(), Owner, Port)
	} catch as e {
		if ProcessOwner is Map
			_LLM_CurlReleaseProcess(ProcessOwner, true, Port)
		try LoggerError("LLM.ollama", "Ollama delete '{1}' launch failed: {2}.", tag, e.Message)
		_LLM_OllamaInvokeAuxResult(Owner, on_result, false)
	}
	return Owner
}

/**
 * Polls a model-delete curl child WITHOUT blocking the message loop (mirrors
 * ``_LLM_Ollama_TagsPoll``). Ollama's ``DELETE /api/delete`` returns an
 * empty body on HTTP 200 and a JSON ``{"error": …}`` body on failure (model
 * not found, daemon busy, …), so success is read straight off the stdout file.
 * @param {integer}  pid         - curl child PID (0 if Run failed).
 * @param {string}   tmp_payload - Temp payload file to clean up once done.
 * @param {string}   tmp_out     - Temp file curl writes the response body to.
 * @param {string}   tag         - Ollama model tag, for logging.
 * @param {function} on_result   - Callback receiving a Boolean (true on success).
 * @param {integer}  start_tick  - A_TickCount at dispatch, for the deadline backstop.
 */
_LLM_Ollama_DeletePoll(ProcessOwner, tmp_payload, tmp_out, tmp_status, tmp_exit, tag, on_result, start_tick, Owner, Port := 0) {
	global LLM_OLLAMA_POLL_MS, LLM_OLLAMA_DELETE_TIMEOUT_MS
	if !LLM_AuxIsCurrent(Owner)
		return
	ReadTerminalFn := _LLM_CurlArtifactPortFn(Port,
		"read_terminal", _LLM_CurlReadTerminal)
	Terminal := ReadTerminalFn.Call(tmp_status, tmp_exit, tmp_out)
	if _LLM_CurlTerminalComplete(Terminal) {
		_LLM_CurlReleaseProcess(ProcessOwner, false, Port)
		if !LLM_AuxIsCurrent(Owner)
			return
		try _LLM_OllamaFinishDelete(Terminal, tag, on_result)
		finally LLM_AuxFinish(Owner)
		return
	}
	if _LLM_DeadlineExpired(start_tick, LLM_OLLAMA_DELETE_TIMEOUT_MS + 5000) {
		_LLM_CurlReleaseProcess(ProcessOwner, true, Port)
		try LoggerWarn("LLM.ollama", "Ollama delete '{1}' timed out.", tag)
		_LLM_OllamaInvokeAuxResult(Owner, on_result, false)
		return
	}
	LLM_AuxSchedule(Owner,
		() => _LLM_Ollama_DeletePoll(ProcessOwner, tmp_payload, tmp_out, tmp_status,
			tmp_exit, tag, on_result, start_tick, Owner, Port), -LLM_OLLAMA_POLL_MS)
}
