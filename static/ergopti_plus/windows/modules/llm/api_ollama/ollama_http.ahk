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

_LLM_CurlArtifactPortFn(Port, Name, DefaultFn) {
	if !(Port is Map) or !Port.Has(Name)
		return DefaultFn
	Candidate := Port[Name]
	if !HasMethod(Candidate, "Call")
		throw TypeError("curl artifact port '" . Name . "' must be callable")
	return Candidate
}

_LLM_CurlArtifactRun(Command, WorkingDir, Options, &Pid) {
	Run(Command, WorkingDir, Options, &Pid)
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

_LLM_CurlReadTerminal(StatusPath, ExitPath, BodyPath) {
	Result := Map("exit", -1, "status", 0, "body_read", false, "body", "")
	try {
		ExitText := Trim(FileRead(ExitPath, "UTF-8-RAW"))
		if RegExMatch(ExitText, "^-?\d+$")
			Result["exit"] := Integer(ExitText)
	}
	try {
		StatusText := Trim(FileRead(StatusPath, "UTF-8-RAW"))
		if RegExMatch(StatusText, "^\d{3}$")
			Result["status"] := Integer(StatusText)
	}
	try {
		Result["body"] := FileRead(BodyPath, "UTF-8-RAW")
		Result["body_read"] := true
	}
	return Result
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
 * Checks whether the Ollama server is reachable (blocking, short timeout).
 * @returns {boolean} True if the server responds to GET /.
 */
LLM_OllamaIsRunning() {
	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("GET", LLM_OLLAMA_BASE_URL, false)
		http.SetTimeouts(500, 500, 500, 500)
		http.Send()
		return (http.Status == 200)
	} catch {
		return false
	}
}

/**
 * Async health probe — same intent as LLM_OllamaIsRunning but never blocks
 * the AHK message loop. Invokes ``on_result(bool)`` from a polling tick.
 * Used by the tray menu's rebuild path so the health dot reflects the
 * current state without making the menu open feel sluggish.
 *
 * @param {function} on_result - Callback receiving the boolean reachability.
 */
LLM_OllamaIsRunning_Async(on_result) {
	; curl CHILD PROCESS, not WinHTTP. The WinHttpRequest.5.1 COM object's "async"
	; mode (Open(...,true) + Send()) still performs the TCP connect synchronously on
	; the CALLING (message-loop) thread: against a cold/busy local daemon that connect
	; blocked for up to ~9 s at boot — freezing the tray build AND keystroke/cancel
	; handling (the menu build that ran during the boot bootstrap was measured stuck
	; for ~14 s entirely on this). It is the same reason the generation path already
	; uses curl. A curl child does the connect in its OWN process; we only poll
	; ProcessExist (instant), so the AHK message loop is NEVER blocked.
	try {
		uid := _LLM_Ollama_NextStreamUid()
		tmp_out := _LLM_Ollama_TempDir() . "\ergopti_ollama_ping_" . uid . ".out"
		terminal := _LLM_CurlTerminalPaths(tmp_out)
		owner_generation := LLM_AuxGeneration()
		curl_exe := A_WinDir . "\System32\curl.exe"
		; -m 2: hard 2 s ceiling. A local daemon answers GET /api/version in < 50 ms;
		; one that needs longer is "not ready yet" for our purposes — the deps poll
		; retries, and the health tick re-probes, so a slow first answer self-heals.
		curlCmd := '"' . curl_exe . '" -s -m 2 -o ' . _Q(tmp_out) . ' ' . _Q(LLM_OLLAMA_BASE_URL . "/api/version")
		cmd := _LLM_CurlOwnedCommand(curlCmd, terminal["status"], terminal["exit"])
		pid := 0
		Run(cmd, , "Hide", &pid)
		_LLM_Ollama_PingPoll(pid, tmp_out, terminal["status"], terminal["exit"], on_result, A_TickCount, owner_generation)
	} catch {
		_LLM_InvokeCallback(on_result, "on_result", false)
	}
}

/**
 * Polls a reachability-ping curl child WITHOUT blocking the message loop. Reachable
 * requires a successful curl exit, 2xx status, readable body, and the canonical
 * ``GET /api/version`` JSON schema. Mirrors the generation poll at a shorter bound.
 * @param {integer}  pid        - curl child PID (0 if Run failed).
 * @param {string}   tmp_out    - Temp file curl writes the response body to.
 * @param {function} on_result  - Callback receiving the boolean reachability.
 * @param {integer}  start_tick - A_TickCount at dispatch, for the deadline backstop.
 */
_LLM_Ollama_PingPoll(pid, tmp_out, tmp_status, tmp_exit, on_result, start_tick, owner_generation) {
	if owner_generation != LLM_AuxGeneration() {
		if (pid > 0 and ProcessExist(pid))
			try ProcessClose(pid)
		for Path in [tmp_out, tmp_status, tmp_exit]
			try FSDelete(Path)
		return
	}
	; 4 s backstop: curl -m 2 should exit by ~2 s, but ProcessClose if it overruns so
	; a wedged child can never keep the poll chain (or its temp handle) alive.
	if (pid > 0 and ProcessExist(pid)) {
		if (_LLM_DeadlineExpired(start_tick, 4000)) {
			try ProcessClose(pid)
			for Path in [tmp_out, tmp_status, tmp_exit]
				try FSDelete(Path)
			_LLM_InvokeCallback(on_result, "on_result", false)
			return
		}
		SetTimer(() => _LLM_Ollama_PingPoll(pid, tmp_out, tmp_status, tmp_exit, on_result, start_tick, owner_generation), -150)
		return
	}
	Terminal := _LLM_CurlReadTerminal(tmp_status, tmp_exit, tmp_out)
	reachable := _LLM_OllamaPingTerminalOk(Terminal["exit"], Terminal["status"], Terminal["body_read"], Terminal["body"])
	for Path in [tmp_out, tmp_status, tmp_exit]
		try FSDelete(Path)
	if owner_generation != LLM_AuxGeneration()
		return
	_LLM_InvokeCallback(on_result, "on_result", reachable)
}

/**
 * Extracts the model tag names from an Ollama ``GET /api/tags`` JSON body. Shared
 * by the blocking ``LLM_OllamaListModels`` and the non-blocking
 * ``LLM_OllamaListModels_Async`` so the two cannot drift in how they read the
 * daemon's reply (single source of truth for the parse).
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
 * Returns the list of locally available model tags from Ollama (blocking).
 * Kept ONLY for off-the-hot-path callers that can tolerate a synchronous round
 * trip (the model browser window, the deps-ready one-shot cache warm). The tray
 * menu build MUST NOT call this — use ``LLM_OllamaListModels_Async`` instead, or it
 * freezes the keyboard thread for up to ~20 s on a cold daemon.
 * @returns {Array} Array of model name strings, or empty array on error.
 */
LLM_OllamaListModels() {
	models := []
	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("GET", LLM_OLLAMA_BASE_URL "/api/tags", false)
		http.SetTimeouts(5000, 5000, 5000, 5000)
		http.Send()
		if (http.Status != 200)
			return models

		models := _LLM_Ollama_ParseTagNames(http.ResponseText)
	} catch {
	}
	return models
}

/**
 * Non-blocking variant of ``LLM_OllamaListModels`` — fetches the locally-installed
 * model tags from ``GET /api/tags`` through a curl child + a polling tick
 * (mirrors ``LLM_OllamaIsRunning_Async``), so the keyboard/menu thread is NEVER
 * frozen on a cold or slow daemon. The blocking version, called per catalogue row
 * at every tray rebuild past the installed-cache TTL, stalled the menu (and dropped
 * keystrokes) for up to ~20 s — the UI must read only the in-memory cache and let
 * THIS function refresh it in the background (AUDIT_AHK_2026-06-19 / TODO.md).
 * @param {function} on_result - Callback receiving an Array of tag names ([] on failure).
 */
LLM_OllamaListModels_Async(on_result) {
	; curl CHILD PROCESS, not WinHTTP — identical reasoning to LLM_OllamaIsRunning_Async:
	; WinHttpRequest async mode (Open(...,true) + Send()) still performs the TCP connect
	; SYNCHRONOUSLY on the calling thread, so against a busy daemon it could block the
	; tray build (which runs under Critical) for up to its timeout. curl does the connect
	; in its own process; we only poll ProcessExist (instant), so the loop never blocks.
	try {
		uid := _LLM_Ollama_NextStreamUid()
		tmp_out := _LLM_Ollama_TempDir() . "\ergopti_ollama_tags_" . uid . ".out"
		terminal := _LLM_CurlTerminalPaths(tmp_out)
		owner_generation := LLM_AuxGeneration()
		curl_exe := A_WinDir . "\System32\curl.exe"
		; -m 2: a local daemon lists installed tags in well under a second; a slower
		; answer is "not ready" — the installed-cache TTL re-probes on the next rebuild.
		curlCmd := '"' . curl_exe . '" -s -m 2 -o ' . _Q(tmp_out) . ' ' . _Q(LLM_OLLAMA_BASE_URL . "/api/tags")
		cmd := _LLM_CurlOwnedCommand(curlCmd, terminal["status"], terminal["exit"])
		pid := 0
		Run(cmd, , "Hide", &pid)
		_LLM_Ollama_TagsPoll(pid, tmp_out, terminal["status"], terminal["exit"], on_result, A_TickCount, owner_generation)
	} catch {
		_LLM_InvokeCallback(on_result, "on_result", [])
	}
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
_LLM_Ollama_TagsPoll(pid, tmp_out, tmp_status, tmp_exit, on_result, start_tick, owner_generation) {
	if owner_generation != LLM_AuxGeneration() {
		if (pid > 0 and ProcessExist(pid))
			try ProcessClose(pid)
		for Path in [tmp_out, tmp_status, tmp_exit]
			try FSDelete(Path)
		return
	}
	if (pid > 0 and ProcessExist(pid)) {
		; 4 s backstop: curl -m 2 should exit by ~2 s; ProcessClose a wedged child so it
		; can never keep the poll chain (or its temp handle) alive.
		if (_LLM_DeadlineExpired(start_tick, 4000)) {
			try ProcessClose(pid)
			for Path in [tmp_out, tmp_status, tmp_exit]
				try FSDelete(Path)
			_LLM_InvokeCallback(on_result, "on_result", [])
			return
		}
		SetTimer(() => _LLM_Ollama_TagsPoll(pid, tmp_out, tmp_status, tmp_exit, on_result, start_tick, owner_generation), -150)
		return
	}
	Terminal := _LLM_CurlReadTerminal(tmp_status, tmp_exit, tmp_out)
	tags := _LLM_CurlTerminalOk(Terminal) ? _LLM_Ollama_ParseTagNames(Terminal["body"]) : []
	for Path in [tmp_out, tmp_status, tmp_exit]
		try FSDelete(Path)
	if owner_generation != LLM_AuxGeneration()
		return
	_LLM_InvokeCallback(on_result, "on_result", tags)
}

/**
 * Removes the local copy of an Ollama model via the daemon's
 * ``DELETE /api/delete`` endpoint. Non-blocking — mirrors
 * ``LLM_OllamaListModels_Async``: a curl child performs the request and we
 * only poll ``ProcessExist`` (instant), so the tray-menu/message-loop thread
 * is never frozen for the DELETE's up-to-10 s round trip. Every sibling
 * Ollama HTTP surface had already been migrated to this pattern; the
 * "Delete model cache" action was the one that was missed (F24).
 *
 * @param {string}   tag       - Ollama model tag (e.g. ``qwen3-coder:30b``).
 * @param {function} on_result - Callback receiving a Boolean (true on success).
 * @param {Map|0}    Port      - Optional deterministic transport seam for tests.
 */
LLM_OllamaDeleteModel_Async(tag, on_result, Port := 0) {
	global LLM_OLLAMA_BASE_URL, LLM_OLLAMA_DELETE_TIMEOUT_MS
	if (tag == "") {
		_LLM_InvokeCallback(on_result, "on_result", false)
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
	Transferred := false
	try {
		uid := _LLM_Ollama_NextStreamUid()
		tmp_dir := TempDirFn.Call()
		tmp_payload := tmp_dir . "\ergopti_ollama_delete_" . uid . ".json"
		tmp_out     := tmp_dir . "\ergopti_ollama_delete_" . uid . ".out"
		terminal := _LLM_CurlTerminalPaths(tmp_out)
		owner_generation := LLM_AuxGeneration()
		; The payload is intentionally minimal — Ollama tolerates the
		; ``model`` field too on newer versions, but ``name`` is the
		; documented one and works on every release we care about
		; (mirrors the retired blocking body).
		body := '{"name":"' . StrReplace(tag, '"', '\"') . '"}'
		if !WriteFn.Call(tmp_payload, body) {
			try LoggerWarn("LLM.ollama", "Failed to write delete payload file for '{1}'.", tag)
			_LLM_InvokeCallback(on_result, "on_result", false)
			return
		}
		curl_exe := A_WinDir . "\System32\curl.exe"
		curlCmd := '"' . curl_exe . '" -s -S -m ' . (LLM_OLLAMA_DELETE_TIMEOUT_MS // 1000) . ' -X DELETE '
			. '-H "Content-Type: application/json" '
			. '--data-binary @' . _Q(tmp_payload) . ' '
			. _Q(LLM_OLLAMA_BASE_URL . "/api/delete") . ' '
			. '-o ' . _Q(tmp_out)
		cmdLine := _LLM_CurlOwnedCommand(curlCmd, terminal["status"], terminal["exit"])
		pid := 0
		RunFn.Call(cmdLine, "", "Hide", &pid)
		PollFn.Call(pid, tmp_payload, tmp_out, terminal["status"], terminal["exit"], tag, on_result, TickFn.Call(), owner_generation)
		Transferred := true
	} catch as e {
		try LoggerError("LLM.ollama", "Ollama delete '{1}' launch failed: {2}.", tag, e.Message)
		_LLM_InvokeCallback(on_result, "on_result", false)
	} finally {
		; Ownership transfers only after the poller accepted the exact artifact
		; tuple. A launch or synchronous poll-admission failure remains ours.
		if !Transferred {
			if tmp_payload != ""
				try DeleteFn.Call(tmp_payload)
			if tmp_out != ""
				try DeleteFn.Call(tmp_out)
			if IsSet(terminal)
				for Path in [terminal["status"], terminal["exit"]]
					try DeleteFn.Call(Path)
		}
	}
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
_LLM_Ollama_DeletePoll(pid, tmp_payload, tmp_out, tmp_status, tmp_exit, tag, on_result, start_tick, owner_generation) {
	global LLM_OLLAMA_POLL_MS, LLM_OLLAMA_DELETE_TIMEOUT_MS
	if (pid > 0 and ProcessExist(pid)) {
		; 5 s backstop beyond curl's own -m ceiling: ProcessClose a wedged
		; child so it can never keep the poll chain (or its temp files) alive.
		if (_LLM_DeadlineExpired(start_tick, LLM_OLLAMA_DELETE_TIMEOUT_MS + 5000)) {
			try ProcessClose(pid)
			try FSDelete(tmp_payload)
			try FSDelete(tmp_out)
			try FSDelete(tmp_status)
			try FSDelete(tmp_exit)
			try LoggerWarn("LLM.ollama", "Ollama delete '{1}' timed out.", tag)
			_LLM_InvokeCallback(on_result, "on_result", false)
			return
		}
		SetTimer(() => _LLM_Ollama_DeletePoll(pid, tmp_payload, tmp_out, tmp_status, tmp_exit, tag, on_result, start_tick, owner_generation), -LLM_OLLAMA_POLL_MS)
		return
	}
	Terminal := _LLM_CurlReadTerminal(tmp_status, tmp_exit, tmp_out)
	try FSDelete(tmp_payload)
	for Path in [tmp_out, tmp_status, tmp_exit]
		try FSDelete(Path)
	if owner_generation != LLM_AuxGeneration()
		return
	_LLM_OllamaFinishDelete(Terminal, tag, on_result)
}
