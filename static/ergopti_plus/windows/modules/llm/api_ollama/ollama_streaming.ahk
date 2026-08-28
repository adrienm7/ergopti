; modules/llm/api_ollama/ollama_streaming.ahk

; ==============================================================================
; MODULE: Ollama API — Streaming via curl
; DESCRIPTION:
; Streaming generation for the Ollama backend. Spawns a curl child with -N
; (no-buffer) to consume JSONL tokens one at a time, firing on_partial per
; token and on_success at end-of-stream. Also provides orphan temp-file cleanup.
; ==============================================================================





; =====================================
; =====================================
; ======= 3/ Async Generation =========
; =====================================
; =====================================

/**
 * Non-blocking Ollama generation. Returns immediately; calls
 * ``on_success(text)`` when the model finishes responding, or ``on_fail()``
 * on any HTTP / parse failure. Mirrors hs.http.asyncPost on the HS side.
 *
 * The transport is a curl child process, not WinHTTP: WinHTTP's async ``Send()``
 * returned HTTP 200 with an empty ``content`` on this driver despite valid JSON
 * payloads. A SetTimer poll (_LLM_Ollama_PollCurl) watches the child every
 * LLM_OLLAMA_POLL_MS and reads its stdout file once the process exits, which
 * keeps the dispatch non-blocking without any COM object in the picture.
 *
 * @param {string}   model         - Ollama model tag.
 * @param {string}   system_prompt - System instruction.
 * @param {string}   user_text     - User context.
 * @param {number}   temperature   - Sampling temperature.
 * @param {function} on_success    - Callback receiving the generated text.
 * @param {function} on_fail       - Callback fired on any failure.
 * @returns {Integer} The request id, for correlating log lines. Aborting is
 *                    always all-or-nothing via LLM_OllamaCancelAllAsync — the
 *                    registry holds at most one in-flight slot by design.
 */
LLM_OllamaGenerate_Async(model, system_prompt, full_text, temperature, on_success, on_fail, stop_sequences := "", max_tokens := "", is_batch := false, tail_text := "") {
	global _LLM_Ollama_AsyncCounter, _LLM_Ollama_Pending
	_LLM_Ollama_AsyncCounter += 1
	req_id := _LLM_Ollama_AsyncCounter
	job := Map(
		"req_id", req_id,
		"model", model,
		"system_prompt", system_prompt,
		"full_text", full_text,
		"temperature", temperature,
		"on_success", on_success,
		"on_fail", on_fail,
		"stop_sequences", stop_sequences,
		"max_tokens", max_tokens,
		"is_batch", is_batch,
		"tail_text", tail_text
	)
	global _LLM_Ollama_Async
	if (_LLM_Ollama_Async.Count > 0) {
		; Latest-only coalescing keeps a single pending slot. If a previous job
		; is already waiting there, it is being superseded and will never run —
		; honour the async contract (exactly one of on_success / on_fail fires)
		; by failing the displaced job before overwriting it. Without this a
		; future consumer that advances a state machine on the callback would
		; stall forever on the dropped job.
		displaced := ""
		if (_LLM_Ollama_Pending is Map and _LLM_Ollama_Pending.Has("on_fail"))
			displaced := _LLM_Ollama_Pending["on_fail"]
		; Overwrite the slot BEFORE firing the displaced callback: on_fail re-enters
		; the engine, and a re-entrant dispatch that still found the displaced job
		; parked here would fail it a second time, breaking the exactly-once contract.
		_LLM_Ollama_Pending := job
		_LLM_InvokeCallback(displaced, "on_fail")
		try LoggerInfo("LLM.ollama", "Ollama busy — coalescing request #{1} until slot free.", req_id)
		return req_id
	}
	_LLM_Ollama_DispatchAsync(job)
	return req_id
}

; Starts one /api/chat request via curl (UTF-8 file body). WinHTTP async ``Send()``
; returned HTTP 200 with ``content: ""`` on this driver despite valid JSON payloads.
_LLM_Ollama_DispatchAsync(job) {
	global _LLM_Ollama_Async, LLM_OLLAMA_BASE_URL, LLM_OLLAMA_TIMEOUT
	req_id := job["req_id"]
	payload := LLM_BuildOllamaPayload(
		job["model"], job["system_prompt"], job["full_text"], job["temperature"],
		false, job["stop_sequences"], job["max_tokens"], job["is_batch"], job["tail_text"])
	; Reap any crash-orphaned payload files before writing a new one. The
	; non-streaming path is the hot path that actually creates these PII files,
	; so the sweeper must run here too — coupling it only to the (currently
	; dead) streaming path left orphans accumulating forever after a hard kill.
	_LLM_Ollama_ScheduleOrphanSweep()
	uid := _LLM_Ollama_NextStreamUid()
	tmp_dir := _LLM_Ollama_TempDir()
	tmp_payload := tmp_dir . "\ergopti_ollama_" . uid . ".json"
	tmp_stdout := tmp_dir . "\ergopti_ollama_" . uid . ".out"
	terminal := _LLM_CurlTerminalPaths(tmp_stdout)
	_LLM_Ollama_TrimAsyncRegistry()
	; AHK-28: mark the slot busy synchronously so DrainPending's
	; _LLM_Ollama_Async.Count > 0 coalescing check sees it before the
	; deferred spawn runs. FSWrite + Run are deferred via SetTimer(-1)
	; to release the Critical region before the blocking OS calls.
	_LLM_Ollama_Async[req_id] := Map(
		"pid", 0, "process_owner", 0,
		"tmp_payload", tmp_payload, "tmp_stdout", tmp_stdout,
		"tmp_status", terminal["status"], "tmp_exit", terminal["exit"],
		"on_success", job["on_success"], "on_fail", job["on_fail"],
		"cancelled", false, "start_tick", A_TickCount,
		"timeout_ms", LLM_OLLAMA_TIMEOUT + 5000, "payload_snip", "")
	SetTimer(() => _LLM_Ollama_DoSpawn(req_id, payload, tmp_payload, tmp_stdout, job), -1)
}

; Deferred spawn: writes the payload file and launches curl outside the
; Critical region. The slot in _LLM_Ollama_Async was reserved synchronously
; in _LLM_Ollama_DispatchAsync so the coalescing count is correct throughout.
_LLM_Ollama_DoSpawn(req_id, payload, tmp_payload, tmp_stdout, job) {
	global _LLM_Ollama_Async, LLM_OLLAMA_BASE_URL, LLM_OLLAMA_TIMEOUT
	; This SetTimer(-1) tick is the only step of the dispatch chain that runs
	; OUTSIDE the Critical region where the slot was reserved, so it is the
	; one place a Suspend or a cancel (LLM_OllamaCancelAllAsync) landing in the
	; gap between reservation and this callback firing can still slip a real
	; HTTP POST + PII payload write out the door — no curl PID exists yet for
	; the cancel path to kill. Mirrors the "cancelled" re-check that
	; _LLM_Ollama_PollCurl already does on every tick
	; (F23: deferred-spawn-ignores-cancel-suspend).
	if !_LLM_Ollama_Async.Has(req_id) {
		; Entry vanished before this tick fired (e.g. evicted by
		; _LLM_Ollama_TrimAsyncRegistry, which already fired on_fail for it) —
		; mirror the sibling poll functions' silent return so the async
		; contract's "exactly once" callback guarantee is not violated by a
		; double on_fail.
		return
	}
	if (A_IsSuspended or _LLM_Ollama_Async[req_id]["cancelled"]) {
		try LoggerInfo("LLM.ollama", "Deferred spawn for req {1} skipped — {2}.",
			req_id, A_IsSuspended ? "suspended" : "cancelled before dispatch")
		_LLM_Ollama_Async.Delete(req_id)
		_LLM_InvokeCallback(job.Has("on_fail") ? job["on_fail"] : "", "on_fail")
		_LLM_Ollama_DrainPending()
		return
	}
	curl_exe := A_WinDir . "\System32\curl.exe"
	if !_HTTP_CurlRuntimeLimitSupported(curl_exe) {
		try LoggerWarn("LLM.ollama", "curl cannot enforce the live response-size limit.")
		_LLM_Ollama_Async.Delete(req_id)
		_LLM_InvokeCallback(job.Has("on_fail") ? job["on_fail"] : "", "on_fail")
		_LLM_Ollama_DrainPending()
		return
	}
	if !FSWrite(tmp_payload, payload) {
		try LoggerWarn("LLM.ollama", "Failed to write curl payload file.")
		_LLM_Ollama_Async.Delete(req_id)
		_LLM_InvokeCallback(job.Has("on_fail") ? job["on_fail"] : "", "on_fail")
		_LLM_Ollama_DrainPending()
		return
	}
	entry := _LLM_Ollama_Async[req_id]
	cmdLine := '"' . curl_exe . '" -s -S -m '
		. Max(1, Ceil(LLM_OLLAMA_TIMEOUT / 1000)) . ' '
		. _LLM_CurlMaxFileSizeArg() . '-X POST '
		. '-H "Content-Type: application/json" '
		. '--data-binary @' . _Q(tmp_payload) . ' '
		. _Q(LLM_OLLAMA_BASE_URL . "/api/chat") . ' '
		. '-o ' . _Q(tmp_stdout)
	cmdLine := _LLM_CurlOwnedCommand(cmdLine,
		entry["tmp_status"], entry["tmp_exit"])
	pid := 0
	try {
		Run(cmdLine, , "Hide", &pid)
	} catch as err {
		try FSDelete(tmp_payload)
		try LoggerWarn("LLM.ollama", "curl launch failed: {1}.", err.Message)
		_LLM_Ollama_Async.Delete(req_id)
		_LLM_InvokeCallback(job.Has("on_fail") ? job["on_fail"] : "", "on_fail")
		_LLM_Ollama_DrainPending()
		return
	}
	payload_snip := StrLen(payload) > 160 ? SubStr(payload, 1, 160) . "…" : payload
	try ProcessOwner := _LLM_CurlAdoptProcess(pid)
	catch {
		try FSDelete(tmp_payload)
		if _LLM_Ollama_Async.Has(req_id) {
			Entry := _LLM_Ollama_Async[req_id]
			_LLM_Ollama_Async.Delete(req_id)
			if !Entry["cancelled"]
				_LLM_InvokeCallback(job.Has("on_fail") ? job["on_fail"] : "", "on_fail")
		}
		_LLM_Ollama_DrainPending()
		return
	}
	if _LLM_Ollama_Async.Has(req_id) {
		_LLM_Ollama_Async[req_id]["pid"]          := pid
		_LLM_Ollama_Async[req_id]["process_owner"] := ProcessOwner
		_LLM_Ollama_Async[req_id]["payload_snip"] := payload_snip
	} else
		_LLM_CurlReleaseProcess(ProcessOwner, true)
	_LLM_Ollama_PollCurl(req_id)
}

; Sends the latest coalesced job once the in-flight slot is free.
_LLM_Ollama_DrainPending() {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending
	; A paused driver must never re-dispatch (network POST + PII temp-file write).
	; SetTimer poll ticks bypass native Suspend, so this guard is the chokepoint.
	if A_IsSuspended
		return
	; Engine disabled at runtime (user toggled off) — do not re-dispatch pending
	; jobs; on_fail already fired when the job was displaced from the pending slot.
	if (IsSet(_LLM_Engine) and !_LLM_Engine["enabled"])
		return
	if (_LLM_Ollama_Async.Count > 0)
		return
	if !(_LLM_Ollama_Pending is Map)
		return
	job := _LLM_Ollama_Pending
	_LLM_Ollama_Pending := ""
	_LLM_Ollama_DispatchAsync(job)
}

/**
 * Cancels every in-flight curl stream. The streaming poll tick discovers the
 * flag on its next iteration and reaps the temp files it owns; stale responses
 * are additionally ignored via the engine's request_id (macOS parity).
 */
LLM_OllamaCancelStreams() {
	global _LLM_Ollama_ActiveStreams
	for _, h in _LLM_Ollama_ActiveStreams
		try LLM_OllamaCancelStream(h)
	_LLM_Ollama_ActiveStreams := []
}

/**
 * Cancel every in-flight async request. The engine calls this on each new
 * prediction fire so previous variants don't keep landing into the tooltip
 * after the user has typed more characters.
 */
LLM_OllamaCancelAllAsync() {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending
	; Flip the flags now — the poll ticks read them — but snapshot the pids and
	; kill them off-thread: this runs under the per-keystroke Critical, where a
	; blocking TerminateProcess starves the keyboard hook.
	Kills := []
	for _id, entry in _LLM_Ollama_Async {
		entry["cancelled"] := true
		if entry.Has("process_owner") and entry["process_owner"] is Map
			Kills.Push(Map("cancel", _LLM_CurlReleaseProcess.Bind(
				entry["process_owner"], true)))
	}
	LLM_DeferCancelKills(Kills)
	LLM_OllamaCancelStreams()
	; Drop any coalesced-but-not-yet-dispatched job. Otherwise the already-armed
	; poll tick discovers the cancelled in-flight entry, deletes it, and calls
	; _LLM_Ollama_DrainPending() which re-dispatches the pending job — a fresh
	; curl POST + PII temp-file write — AFTER the driver was suspended (the engine
	; calls this from Ergopti_OnSuspendEnter -> LLM_Engine_StopGeneration). Honour
	; the async contract by failing the displaced job exactly once before dropping.
	if (_LLM_Ollama_Pending is Map) {
		displaced := _LLM_Ollama_Pending.Has("on_fail") ? _LLM_Ollama_Pending["on_fail"] : ""
		; Drop the slot before firing so a callback that re-enters the dispatcher
		; cannot find — and fail — the same job twice.
		_LLM_Ollama_Pending := ""
		_LLM_InvokeCallback(displaced, "on_fail")
	}
}

/**
 * Marks the model ready after a successful inference (warmup may have timed out
 * on slow CPU loads while real predictions still work).
 */
LLM_OllamaNoteInferenceSuccess() {
	global _LLM_Ollama_IsReady
	if _LLM_Ollama_IsReady
		return
	_LLM_Ollama_IsReady := true
	try LoggerInfo("LLM.ollama", "Model ready — first successful prediction.")
	; First real prediction succeeded — backoff can safely reset for the next cycle
	LLM_OllamaCancelWarmupRetry(true)
}

; Polls a non-streaming curl child until stdout is ready or the slot times out.
_LLM_Ollama_PollCurl(req_id, Port := 0) {
	global _LLM_Ollama_Async, LLM_OLLAMA_POLL_MS
	if !_LLM_Ollama_Async.Has(req_id)
		return
	entry := _LLM_Ollama_Async[req_id]
	Terminal := Map("complete", false, "exit", -1,
		"status", 0, "body_read", false, "body", "")
	ReadTerminalFn := _LLM_CurlArtifactPortFn(Port,
		"read_terminal", _LLM_CurlReadTerminal)
	if entry.Has("tmp_status") and entry.Has("tmp_exit") and entry.Has("tmp_stdout")
		Terminal := ReadTerminalFn.Call(
			entry["tmp_status"], entry["tmp_exit"], entry["tmp_stdout"])
	if _LLM_CurlTerminalComplete(Terminal) {
		_LLM_CurlReleaseEntryProcess(entry, false, Port)
		if entry["cancelled"] {
			_LLM_Ollama_CleanupCurlFiles(entry)
			_LLM_Ollama_Async.Delete(req_id)
			_LLM_Ollama_DrainPending()
			return
		}
		on_success := entry["on_success"]
		on_fail := entry["on_fail"]
		body := Terminal["body"]
		_LLM_Ollama_CleanupCurlFiles(entry)
		_LLM_Ollama_Async.Delete(req_id)
		if !_LLM_CurlTerminalOk(Terminal) or body == "" {
			try LoggerWarn("LLM.ollama", "curl terminal failure (exit={1}, status={2}, body_chars={3}).",
				Terminal["exit"], Terminal["status"], StrLen(body))
			_LLM_InvokeCallback(on_fail, "on_fail")
			_LLM_Ollama_DrainPending()
			return
		}
		try _LLM_OllamaParseAsyncBody(body, on_success, on_fail, entry)
		_LLM_Ollama_DrainPending()
		return
	}
	if entry["cancelled"] {
		_LLM_CurlReleaseEntryProcess(entry, true, Port)
		_LLM_Ollama_CleanupCurlFiles(entry)
		_LLM_Ollama_Async.Delete(req_id)
		_LLM_Ollama_DrainPending()
		return
	}
	if (entry.Has("start_tick") and entry.Has("timeout_ms") and _LLM_DeadlineExpired(entry["start_tick"], entry["timeout_ms"])) {
		_LLM_CurlReleaseEntryProcess(entry, true, Port)
		elapsed := entry.Has("start_tick") ? TickElapsed(entry["start_tick"]) : 0
		try LoggerWarn("LLM.ollama", "curl request timed out after {1} ms.", elapsed)
		on_fail := entry["on_fail"]
		_LLM_Ollama_CleanupCurlFiles(entry)
		_LLM_Ollama_Async.Delete(req_id)
		_LLM_InvokeCallback(on_fail, "on_fail")
		_LLM_Ollama_DrainPending()
		return
	}
	SetTimer(() => _LLM_Ollama_PollCurl(req_id, Port), -LLM_OLLAMA_POLL_MS)
}

_LLM_Ollama_CleanupCurlFiles(entry) {
	if !(entry is Map)
		return
	if entry.Has("tmp_payload") and entry["tmp_payload"] != ""
		try FSDelete(entry["tmp_payload"])
	if entry.Has("tmp_stdout") and entry["tmp_stdout"] != ""
		try FSDelete(entry["tmp_stdout"])
	if entry.Has("tmp_status") and entry["tmp_status"] != ""
		try FSDelete(entry["tmp_status"])
	if entry.Has("tmp_exit") and entry["tmp_exit"] != ""
		try FSDelete(entry["tmp_exit"])
}

/**
 * Default async-response parser — extracts the ``response`` field from
 * Ollama's /api/generate reply and hands the unescaped text to on_success.
 */
_LLM_OllamaParseAsyncBody(body, on_success, on_fail, entry := "") {
	text := LLM_ParseOllamaChatResponse(body)
	; LLM_ParseOllamaChatResponse returns a structured Map("error", true, ...)
	; on a JSON parse failure (malformed body) instead of an empty string, so
	; that case must be checked before the empty-string "parse miss" branch —
	; otherwise on_fail would receive the raw Map as if it were prediction text.
	if (text is Map) and text.Has("error") {
		try LoggerWarn("LLM.ollama", "Ollama response parse failed: {1}.", text.Has("message") ? text["message"] : "unknown error")
		_LLM_InvokeCallback(on_fail, "on_fail", text)
		return
	}
	if (text == "") {
		snip := StrLen(body) > 120 ? SubStr(body, 1, 120) . "…" : body
		payload_hint := ""
		if (entry is Map) and entry.Has("payload_snip")
			payload_hint := " Payload: «" . entry["payload_snip"] . "»."
		try LoggerWarn("LLM.ollama", "Ollama returned an empty prediction (parse miss). Body: «{1}».{2}", snip, payload_hint)
		_LLM_InvokeCallback(on_fail, "on_fail", Map("error", true, "message", "empty prediction"))
		return
	}
	snip := StrLen(text) > 60 ? SubStr(text, 1, 60) . "…" : text
	try LoggerInfo("LLM.ollama", "Prediction received ({1} chars): «{2}».", StrLen(text), snip)
	try LLM_OllamaNoteInferenceSuccess()
	_LLM_InvokeCallback(on_success, "on_success", text)
}

/**
 * Generic async poll for non-/api/generate requests (e.g. health probe).
 * Calls ``on_ok(status, body)`` on response received, ``on_err()`` otherwise.
 *
 * The ``deadline`` argument is the absolute A_TickCount at which we MUST
 * give up — without it, a WinHTTP request whose ``WaitForResponse(0)``
 * never flips ``true`` (the COM proxy silently breaks under heavy load,
 * or the server is unreachable AND WinHTTP fails to honour its own
 * timeout) would re-arm ``SetTimer`` every 50 ms forever. With Ollama
 * not installed, the 10 s tray health probe paired with that unbounded
 * poll produced a continuous stream of timer callbacks that saturated
 * the AHK message loop and caused the InputHook to drop keystrokes —
 * the user's typing felt like characters were being eaten at random.
 */
_LLM_Ollama_PollGeneric(http, on_ok, on_err, start_tick := 0, timeout_ms := 0, poll_ms := 0) {
	; First entry — record the start tick once so subsequent recursive ticks
	; can compute elapsed time correctly across the 32-bit A_TickCount wrap.
	; 3000 ms is generous enough for any local Ollama call (the WinHTTP
	; per-phase timeout is 2 s) but short enough to guarantee the timer chain
	; ends within a few hundred milliseconds of the request actually failing.
	if (start_tick == 0)
		start_tick := A_TickCount
	if (timeout_ms == 0)
		timeout_ms := 3000
	; Default poll cadence — callers that don't care use LLM_OLLAMA_POLL_MS
	; (50 ms, optimal for prediction latency). The health probe overrides
	; this with 500 ms because reactivity on a 10 s timer is irrelevant.
	if (poll_ms == 0)
		poll_ms := LLM_OLLAMA_POLL_MS

	ready := false
	try {
		ready := http.WaitForResponse(0)
	} catch as com_err {
		; Same abandonment contract as the two sibling polls. A COM exception here
		; means the connection dropped (WiFi cut, Ollama restarted): the bare `try`
		; this replaces swallowed it and re-queued, so a dead request kept polling
		; every 50 ms until the 90 s deadline — a busy-loop against a socket that
		; was never going to answer, with no diagnostic anywhere
		; (ollama-com-exception-busy-loop).
		try LoggerWarn("LLM.ollama", "WaitForResponse threw COM error in poll — abandoning: {1}", com_err.Message)
		try http.Abort()
		_LLM_InvokeCallback(on_err, "on_err")
		return
	}
	if !ready {
		if _LLM_DeadlineExpired(start_tick, timeout_ms) {
			; Abort the in-flight request before dropping our reference — a
			; server that accepts the connection but never responds would
			; otherwise keep the COM object + socket resident until WinHTTP's
			; own timeout fires, long after we have stopped polling it.
			try http.Abort()
			_LLM_InvokeCallback(on_err, "on_err")
			return
		}
		SetTimer(() => _LLM_Ollama_PollGeneric(http, on_ok, on_err, start_tick, timeout_ms, poll_ms), -poll_ms)
		return
	}
	try {
		status := http.Status
		body := http.ResponseText
	} catch {
		_LLM_InvokeCallback(on_err, "on_err")
		return
	}
	_LLM_InvokeCallback(on_ok, "on_ok", status, body)
}

/**
 * Drops the oldest registry entry when the in-flight count is over the
 * cap. Defensive: in normal flow the engine cancels stale variants well
 * before this triggers, but a runaway request would otherwise leak its
 * COM object indefinitely.
 */
_LLM_Ollama_TrimAsyncRegistry() {
	global _LLM_Ollama_Async, LLM_OLLAMA_MAX_INFLIGHT
	if (_LLM_Ollama_Async.Count < LLM_OLLAMA_MAX_INFLIGHT)
		return
	; AHK v2 Maps do NOT guarantee insertion order — always find the
	; numerically smallest key explicitly so the truly oldest request is
	; killed, not a random one (trim-async-registry-map-order fix).
	oldest_id := 0x7FFFFFFFFFFFFFFF
	for id in _LLM_Ollama_Async
		if (id < oldest_id)
			oldest_id := id
	if !_LLM_Ollama_Async.Has(oldest_id)
		return
	oldest_entry := _LLM_Ollama_Async[oldest_id]
	; Detach before cleanup or callbacks: either boundary can re-enter dispatch,
	; and the terminated owner must no longer participate in successor trimming.
	_LLM_Ollama_Async.Delete(oldest_id)
	; Kill the curl child so it does not keep writing to the temp file
	; after we abandon the registry entry — the PID would otherwise
	; accumulate until it expires naturally (up to 3 min).
	_LLM_CurlReleaseEntryProcess(oldest_entry, true)
	_LLM_Ollama_CleanupCurlFiles(oldest_entry)
	; Honour the async contract: exactly one of on_success / on_fail must
	; fire. Without this the caller (e.g. the prediction engine slot state
	; machine) hangs forever waiting for a callback that will never arrive.
	if oldest_entry.Has("on_fail") and oldest_entry["on_fail"] is Func
		_LLM_InvokeCallback(oldest_entry["on_fail"], "on_fail")
}





; =====================================
; =====================================
; ======= 5/ Streaming via curl =======
; =====================================
; =====================================

/**
 * Streaming variant of LLM_OllamaGenerate_Async. Fires curl as a child
 * process with ``-N`` (no-buffer) so Ollama's JSONL stream is consumed
 * one token at a time. on_partial is invoked with the accumulated text
 * after each new token; on_success is invoked with the final text once
 * the stream ends; on_fail fires on a non-zero curl exit code or a parse
 * miss for every line of the stream.
 *
 * Why curl: WinHTTP's COM wrapper does not surface incremental response
 * bytes until the server closes the connection. The HS side has the same
 * constraint and solves it with ``hs.task + curl -N``; we follow the
 * exact same pattern.
 *
 * @param {string}   model         - Ollama model tag.
 * @param {string}   system_prompt - System instruction.
 * @param {string}   user_text     - User context.
 * @param {number}   temperature   - Sampling temperature.
 * @param {function} on_partial    - Called as on_partial(accumulated_text) per token.
 * @param {function} on_success    - Called as on_success(final_text) at end-of-stream.
 * @param {function} on_fail       - Called on any failure.
 * @returns {Object} A handle retaining the exact process object; callers pass it
 *                   to LLM_OllamaCancelStream to terminate the curl process.
 */
LLM_OllamaGenerate_Streaming(model, system_prompt, full_text, temperature, on_partial, on_success, on_fail, stop_sequences := "", max_tokens := "", is_batch := false, tail_text := "") {
	; Build the streaming payload — ``stream:true`` flips Ollama to JSONL (/api/chat).
	payload := LLM_BuildOllamaPayload(model, system_prompt, full_text, temperature, true, stop_sequences, max_tokens, is_batch, tail_text)
	curl_exe := A_WinDir . "\System32\curl.exe"
	if !_HTTP_CurlRuntimeLimitSupported(curl_exe) {
		try LoggerWarn("LLM.ollama", "curl cannot enforce the live response-size limit.")
		_LLM_InvokeCallback(on_fail, "on_fail")
		return { Pid: 0, ProcessOwner: 0, Cancelled: false }
	}

	; Write the payload to a temp file (curl --data-binary @file). Avoids
	; command-line length limits and shell escaping headaches with the JSON
	; quotes. The filename mixes the tick count with a per-call counter so
	; two streams fired in the same millisecond can't share a file.
	_LLM_Ollama_ScheduleOrphanSweep()
	uid := _LLM_Ollama_NextStreamUid()
	tmp_dir := _LLM_Ollama_TempDir()
	tmp_payload := tmp_dir . "\ergopti_ollama_" . uid . ".json"
	if !FSWrite(tmp_payload, payload) {
		_LLM_InvokeCallback(on_fail, "on_fail")
		return { Pid: 0, ProcessOwner: 0, Cancelled: false }
	}

	tmp_stdout := tmp_dir . "\ergopti_ollama_" . uid . ".out"
	; Launch curl.exe directly (not cmd /c): hidden cmd often lacks curl on PATH and
	; shell redirects (> file) silently produce empty/missing stdout — logs showed
	; "Streaming finished with empty response. No stdout file."
	cmdLine := '"' . curl_exe . '" -N -s -S -m '
		. Max(1, Ceil(LLM_OLLAMA_TIMEOUT / 1000)) . ' '
		. _LLM_CurlMaxFileSizeArg() . '-X POST '
		. '-H "Content-Type: application/json" '
		. '--data-binary @' . _Q(tmp_payload) . ' '
		. _Q(LLM_OLLAMA_BASE_URL . "/api/chat") . ' '
		. '-o ' . _Q(tmp_stdout)

	handle := { Pid: 0, ProcessOwner: 0, Cancelled: false,
		TmpPayload: tmp_payload, TmpStdout: tmp_stdout }
	try {
		Run(cmdLine, , "Hide", &pid)
		handle.Pid := pid
		handle.ProcessOwner := _LLM_CurlAdoptProcess(pid)
	} catch {
		_LLM_InvokeCallback(on_fail, "on_fail")
		_LLM_Ollama_CleanupStreamFiles(handle)
		return handle
	}

	; Polling loop: read what's appeared in tmp_stdout so far, parse new
	; JSONL lines, fire on_partial for each. When the process exits, fire
	; on_success with the accumulated text.
	state := Map("acc", "", "last_pos", 0, "start_tick", A_TickCount,
		"timeout_ms", LLM_OLLAMA_TIMEOUT + 5000)
	global _LLM_Ollama_ActiveStreams
	_LLM_Ollama_ActiveStreams.Push(handle)
	_LLM_Ollama_StreamPoll(handle, state, on_partial, on_success, on_fail)
	return handle
}

/**
 * Polling tick for the streaming child process. Reads the tail of the
 * stdout temp file, parses any new JSONL lines, and fires on_partial /
 * on_success accordingly. Stops when the process is gone or the
 * cancellation flag flips.
 */
_LLM_Ollama_StreamPoll(handle, state, on_partial, on_success, on_fail) {
	global LLM_OLLAMA_POLL_MS
	if handle.Cancelled {
		_LLM_CurlReleaseProcess(handle.ProcessOwner, true)
		_LLM_Ollama_CleanupStreamFiles(handle)
		_LLM_Ollama_RemoveStreamHandle(handle)
		try LoggerInfo("LLM.ollama", "Streaming cancelled (newer prediction).")
		_LLM_InvokeCallback(on_fail, "on_fail")
		return
	}
	if (state.Has("start_tick") and state.Has("timeout_ms") and _LLM_DeadlineExpired(state["start_tick"], state["timeout_ms"])) {
		_LLM_CurlReleaseProcess(handle.ProcessOwner, true)
		_LLM_Ollama_CleanupStreamFiles(handle)
		_LLM_Ollama_RemoveStreamHandle(handle)
		elapsed := state.Has("start_tick") ? TickElapsed(state["start_tick"]) : 0
		try LoggerWarn("LLM.ollama", "Streaming timed out after {1} ms.", elapsed)
		_LLM_InvokeCallback(on_fail, "on_fail")
		return
	}
	; Read whatever new bytes appeared.
	try {
		fh := FileOpen(handle.TmpStdout, "r", "UTF-8")
		if IsObject(fh) {
			fh.Pos := state["last_pos"]
			chunk := fh.Read()
			state["last_pos"] := fh.Pos
			fh.Close()
			if (chunk != "") {
				_LLM_Ollama_ConsumeStreamChunk(chunk, state, on_partial)
			}
		}
	} catch as Err {
		state["failed"] := true
		state["stream_error"] := "Stream output read failed: " . Err.Message
	}
	if state.Get("failed", false) {
		_LLM_CurlReleaseProcess(handle.ProcessOwner, true)
		try LoggerError("LLM.ollama", "{1}", state.Get("stream_error", "Streaming failed."))
		_LLM_Ollama_CleanupStreamFiles(handle)
		_LLM_Ollama_RemoveStreamHandle(handle)
		_LLM_InvokeCallback(on_fail, "on_fail")
		return
	}
	; Still alive? Schedule the next tick.
	if !_LLM_CurlProcessExited(handle.ProcessOwner) {
		SetTimer(() => _LLM_Ollama_StreamPoll(handle, state, on_partial, on_success, on_fail), -LLM_OLLAMA_POLL_MS)
		return
	}
	_LLM_CurlReleaseProcess(handle.ProcessOwner)
	; Process exited: flush whatever is left on disk before declaring the
	; result. The child's stdout can lag its exit by a few ms, so hand off to
	; the re-armed flush tick (no blocking Sleep) which retries the read a
	; bounded number of times until content appears or the file is confirmed
	; empty.
	_LLM_Ollama_StreamFinalFlush(handle, state, on_partial, on_success, on_fail)
}

; Non-blocking end-of-stream flush. Reads any bytes the child wrote after exit;
; if the accumulator is still empty but the stdout file is non-empty (flush
; lag), it re-arms itself as a one-shot timer instead of Sleep()ing so the AHK
; message pump keeps pumping. Bounded by _LLM_OLLAMA_STREAM_FLUSH_MAX_RETRIES.
_LLM_Ollama_StreamFinalFlush(handle, state, on_partial, on_success, on_fail) {
	global _LLM_OLLAMA_STREAM_FLUSH_MAX_RETRIES, _LLM_OLLAMA_STREAM_FLUSH_RETRY_MS
	try {
		fh := FileOpen(handle.TmpStdout, "r", "UTF-8")
		if IsObject(fh) {
			fh.Pos := state["last_pos"]
			chunk := fh.Read()
			state["last_pos"] := fh.Pos
			fh.Close()
			if (chunk != "") {
				_LLM_Ollama_ConsumeStreamChunk(chunk, state, on_partial)
			}
		}
	} catch as Err {
		state["failed"] := true
		state["stream_error"] := "Final stream output read failed: " . Err.Message
	}
	retries := state.Has("flush_retries") ? state["flush_retries"] : 0
	; Retry when the output file is still empty — curl may have just finished
	; but not yet flushed its OS write buffer. Conversely, if the file exists
	; and has data, we have already drained it above; no retry needed.
	more_to_read := true
	try more_to_read := (!FileExist(handle.TmpStdout)
		or FileGetSize(handle.TmpStdout) = 0)
	catch as Err {
		state["failed"] := true
		state["stream_error"] := "Final stream size check failed: " . Err.Message
	}
	if (!state.Get("failed", false) and state["acc"] == "" and more_to_read
			and retries < _LLM_OLLAMA_STREAM_FLUSH_MAX_RETRIES) {
		state["flush_retries"] := retries + 1
		SetTimer(() => _LLM_Ollama_StreamFinalFlush(handle, state, on_partial, on_success, on_fail), -_LLM_OLLAMA_STREAM_FLUSH_RETRY_MS)
		return
	}
	; Flush any leftover (last JSON line that did not end with \n).
	; Without this the final token of a response that lacks a trailing newline
	; is silently lost, producing "Streaming finished with empty response".
	; Clear the stored leftover BEFORE passing it to ConsumeStreamChunk — that
	; function prepends state["leftover"] itself, so leaving it set would double
	; the content and corrupt the accumulated result.
	if (!state.Get("failed", false) and state.Has("leftover")
			and state["leftover"] != "") {
		_resid := state["leftover"]
		state["leftover"] := ""
		_LLM_Ollama_ConsumeStreamChunk(_resid . "`n", state, on_partial)
	}
	Result := _LLM_Ollama_StreamTerminalResult(state)
	hint := ""
	if !Result["ok"] and Result["error"] == "Streaming finished with empty response."
		hint := _LLM_Ollama_StreamFailHint(handle.TmpStdout)
	_LLM_Ollama_CleanupStreamFiles(handle)
	_LLM_Ollama_RemoveStreamHandle(handle)
	if !Result["ok"] {
		try LoggerWarn("LLM.ollama", "{1}{2}", Result["error"],
			hint != "" ? " " . hint : "")
		_LLM_InvokeCallback(on_fail, "on_fail")
		return
	}
	try LLM_OllamaNoteInferenceSuccess()
	_LLM_InvokeCallback(on_success, "on_success", Result["text"])
}

_LLM_Ollama_StreamTerminalResult(state) {
	if state.Get("failed", false)
		return Map("ok", false, "text", "",
			"error", state.Get("stream_error", "Streaming failed."))
	if !state.Get("done", false)
		return Map("ok", false, "text", "",
			"error", "Stream ended before Ollama's done marker.")
	if state["acc"] == ""
		return Map("ok", false, "text", "",
			"error", "Streaming finished with empty response.")
	return Map("ok", true, "text", state["acc"], "error", "")
}

_LLM_Ollama_RemoveStreamHandle(handle) {
	global _LLM_Ollama_ActiveStreams
	; Stream handles are object literals ({ Pid, Cancelled, … }), not Map instances —
	; ``handle is Map`` always fails and made this function a permanent no-op,
	; leaving _LLM_Ollama_ActiveStreams grow without bound across streaming calls
	if !IsObject(handle) or !handle.HasOwnProp("Pid")
		return
	next := []
	for _, h in _LLM_Ollama_ActiveStreams {
		; Compare by object reference, not by PID — Windows reuses PIDs of
		; short-lived processes; a PID collision would silently remove the
		; wrong (still-active) handle from the registry.
		if h != handle
			next.Push(h)
	}
	_LLM_Ollama_ActiveStreams := next
}

_LLM_Ollama_StreamFailHint(stdout_path) {
	if (stdout_path == "" or !FileExist(stdout_path))
		return "No stdout file."
	try {
		raw := FileRead(stdout_path, "UTF-8-RAW")
		if (raw == "")
			return "Stdout empty."
		if InStr(raw, '"error"')
			return "Ollama error: " . SubStr(raw, 1, 200)
		if InStr(raw, '"thinking"') and !InStr(raw, '"response":"') 
			return "Model returned thinking-only tokens (enable think:false)."
		return "Stdout snippet: " . SubStr(raw, 1, 120)
	} catch {
		return ""
	}
}

/**
 * Parses a chunk of JSONL stream output, extracts the ``response`` field
 * from each complete line, and appends to state["acc"]. Calls on_partial
 * once per chunk with the up-to-date accumulated text.
 */
_LLM_Ollama_ConsumeStreamChunk(chunk, state, on_partial) {
	; Split on newlines; the last fragment may be incomplete — buffer it
	; back into state["leftover"] for the next chunk.
	leftover := state.Has("leftover") ? state["leftover"] : ""
	full := leftover . chunk
	lines := StrSplit(full, "`n", "`r")
	new_acc := state["acc"]
	; If the chunk ends mid-line, the last piece is incomplete and we
	; buffer it back for the next tick. Reading the very last character
	; via ``SubStr(chunk, StrLen(chunk), 1)`` is unambiguous; the
	; previous ``SubStr(chunk, -1)`` form was reading the last UTF-16
	; code unit, which on chunks ending with ``\r\n`` would miss the
	; \n and mistakenly keep the empty trailing string as "leftover".
	last_char := (StrLen(chunk) > 0) ? SubStr(chunk, StrLen(chunk), 1) : ""
	if (last_char != "`n") {
		state["leftover"] := lines[lines.Length]
		lines.RemoveAt(lines.Length)
	} else {
		state["leftover"] := ""
	}
	for _, line in lines {
		if (line == "")
			continue
		Parsed := _LLM_Ollama_ParseStreamLine(line)
		if !Parsed["ok"] {
			state["failed"] := true
			state["stream_error"] := Parsed["error"]
			break
		}
		if Parsed["token"] != ""
			new_acc .= Parsed["token"]
		if Parsed["done"]
			state["done"] := true
	}
	if (new_acc != state["acc"]) {
		state["acc"] := new_acc
		if !state.Get("failed", false)
			_LLM_InvokeCallback(on_partial, "on_partial", new_acc)
	}
}

/**
 * Cancels an in-flight streaming request — terminates the curl process
 * and lets the polling tick clean up the temp files on its next iteration.
 *
 * @param {Object} handle - The handle returned by LLM_OllamaGenerate_Streaming.
 */
LLM_OllamaCancelStream(handle) {
	if (handle == "" or !IsObject(handle))
		return
	handle.Cancelled := true
	; Deferred for the same reason as the async cancellation: this is reached from
	; the per-keystroke Critical via LLM_OllamaCancelStreams, and killing the curl
	; child is OS work that must not run with the message pump suspended.
	if handle.HasOwnProp("ProcessOwner") and handle.ProcessOwner is Map
		LLM_DeferCancelKills([Map("cancel",
			_LLM_CurlReleaseProcess.Bind(handle.ProcessOwner, true))])
}

_LLM_Ollama_CleanupStreamFiles(handle) {
	if (handle == "" or !IsObject(handle))
		return
	FSDelete(handle.TmpPayload)
	FSDelete(handle.TmpStdout)
}

; Per-call counter so two streams fired in the same millisecond cannot
; collide on the temp filenames. Combined with A_TickCount this is enough
; for uniqueness across the lifetime of a single script instance.
global _LLM_Ollama_StreamCounter := 0

_LLM_Ollama_NextStreamUid() {
	global _LLM_Ollama_StreamCounter
	_LLM_Ollama_StreamCounter += 1
	return A_TickCount . "_" . _LLM_Ollama_StreamCounter
}

; Per-instance hardened temp directory for the curl payload + stdout files. The
; payload carries the user's typed context (potential PII), so it must not land
; in the shared %TEMP% root where a sibling process / clipboard manager / sync
; agent can read it. Routing every file through a private subdirectory keyed on
; the current PID both narrows the exposure surface (the dir is created with the
; user's default ACL, not world-shared) and lets the orphan sweeper scope its
; glob to ``ergopti_ollama_*`` files this driver actually owns. Created lazily on
; first use; falls back to A_Temp only if the directory cannot be created so a
; locked-down %TEMP% never silently breaks predictions.
_LLM_Ollama_TempDir() {
	dir := A_Temp . "\ergopti_llm_" . DllCall("GetCurrentProcessId")
	if !FileExist(dir) {
		try DirCreate(dir)
	}
	; Fail-safe: if the private dir is unavailable, degrade to A_Temp rather
	; than dropping the prediction entirely.
	return FileExist(dir) ? dir : A_Temp
}

; Wipes every owned Ollama and remote curl artifact older than 60 s. Runs on
; a throttled background timer (see _LLM_Ollama_ScheduleOrphanSweep), never on
; the synchronous dispatch path, so a previous AHK instance that crashed mid-stream
; (Power loss, hard kill, …) never leaks files indefinitely. The 60 s
; window is generous — typical predictions complete in 1-3 s and any
; legitimate in-flight stream on a fresh AHK instance is younger than that.
_LLM_Ollama_StreamCleanupOrphans(RootDir := "", CurrentDir := "") {
	now := A_Now
	if (RootDir = "")
		RootDir := A_Temp
	my_dir := CurrentDir != "" ? CurrentDir : _LLM_Ollama_TempDir()
	; Legacy A_Temp-root files (older builds wrote artifacts straight into
	; %TEMP%). NON-recursive ("F") — never walk the whole %TEMP% subtree: it holds
	; 100k+ entries on a busy box and a recursive sweep took ~19 s per pass.
	; The family wildcard intentionally owns every sidecar extension (.json,
	; .conf, .out, .out.status and .out.exit), rather than maintaining an
	; incomplete extension list which silently leaks newly added receipts.
	loop files, RootDir . "\ergopti_ollama_*", "F"
		_LLM_Ollama_TryDeleteIfOld(A_LoopFilePath, A_LoopFileTimeModified, now)
	loop files, RootDir . "\ergopti_remote_*", "F"
		_LLM_Ollama_TryDeleteIfOld(A_LoopFilePath, A_LoopFileTimeModified, now)
	; Per-instance hardened dirs of prior instances. Scope the walk to our own
	; ergopti_llm_* dirs, one level deep ("D") — a bounded handful, not all of %TEMP%.
	; The current instance's own files are reaped by _LLM_Ollama_CleanupCurlFiles.
	loop files, RootDir . "\ergopti_llm_*", "D" {
		inst_dir := A_LoopFilePath
		if (inst_dir == my_dir)
			continue
		loop files, inst_dir . "\ergopti_ollama_*", "F"
			_LLM_Ollama_TryDeleteIfOld(A_LoopFilePath, A_LoopFileTimeModified, now)
		loop files, inst_dir . "\ergopti_remote_*", "F"
			_LLM_Ollama_TryDeleteIfOld(A_LoopFilePath, A_LoopFileTimeModified, now)
		; Reap the now-empty dir of a dead instance so PID dirs (160+ leaked) do not
		; pile up and slow every future sweep. DirDelete(recurse=false) only deletes
		; when empty, so a live sibling (it recreates the dir lazily) is never harmed.
		try DirDelete(inst_dir, false)
	}
}

; Schedules the orphan sweep OFF the synchronous dispatch path. A SetTimer callback
; runs only after the caller's (Critical) dispatch returns, so a slow filesystem can
; never freeze the keyboard mid-prediction. Throttled because orphans (from crashed
; PRIOR instances) are never urgent — the live instance reaps its own files inline.
_LLM_Ollama_ScheduleOrphanSweep() {
	global _LLM_Ollama_LastSweepTick, _LLM_OLLAMA_ORPHAN_SWEEP_MS
	now := A_TickCount
	; Wrap-safe delta: A_TickCount overflows at ~49.7 days.
	if (_LLM_Ollama_LastSweepTick != 0
			and ((now - _LLM_Ollama_LastSweepTick + 0x100000000) & 0xFFFFFFFF) < _LLM_OLLAMA_ORPHAN_SWEEP_MS)
		return
	_LLM_Ollama_LastSweepTick := now
	; -1 = fire once, as soon as the message pump is free (outside any Critical).
	SetTimer(_LLM_Ollama_StreamCleanupOrphans, -1)
}

_LLM_Ollama_TryDeleteIfOld(path, file_time, now) {
	try {
		age_s := DateDiff(now, file_time, "Seconds")
		if (age_s > 60)
			FSDelete(path)
	} catch {
	}
}

; Tiny helper: wrap a path in double quotes for CMD. Not exported.
_Q(s) {
	return '"' . s . '"'
}
