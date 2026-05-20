; modules/llm/api_ollama.ahk

; ==============================================================================
; MODULE: LLM API — Ollama Backend
; DESCRIPTION:
; HTTP client for the local Ollama inference server (http://localhost:11434).
; Exposes both an async path (callback-based) and a small sync wrapper for
; legacy call sites. The prediction engine uses the async path so it can fire
; N concurrent variants, cancel stale ones when typing resumes, and update the
; tooltip token-by-token via on_partial — same surface as the HS twin
; ``modules/llm/api_ollama.lua``.
;
; FEATURES & RATIONALE:
; 1. Non-blocking dispatch — WinHTTP's async mode + a polling timer so the
;    AHK message loop never freezes while waiting for the server. Mirrors
;    hs.http.asyncPost semantics on the HS side: caller passes on_success /
;    on_fail closures, fetch returns immediately.
; 2. Curl-based streaming — for the multi-prediction reveal animation the
;    engine needs token-by-token feedback. Windows 10+ ships curl natively
;    at C:\Windows\System32\curl.exe; we spawn it with --no-buffer and read
;    its stdout one JSONL line at a time, firing on_partial on each token.
; 3. Backwards-compat sync — old callers (deps checker, model lister) that
;    block on purpose keep their synchronous shape. The async surface is
;    additive, not a rewrite.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================
; =====================================
; ======= 1/ Constants ================
; =====================================
; =====================================

; Default Ollama endpoint
global LLM_OLLAMA_BASE_URL := "http://localhost:11434"
global LLM_OLLAMA_TIMEOUT  := 30000   ; ms — generous to accommodate cold-start inference

; Polling interval for the async path. 50 ms is the same cadence the HS side
; effectively gets from hs.http.asyncPost's underlying CFRunLoop tick — fine
; for interactive feedback (≤ 1 keystroke of latency) and cheap on CPU.
global LLM_OLLAMA_POLL_MS := 50

; Maximum number of in-flight async requests kept in the registry. Once we
; exceed this, the oldest pending request is abandoned (its callback becomes
; a no-op). 16 covers worst-case "user types a dozen letters back-to-back
; while the server is sluggish" without leaking handles indefinitely.
global LLM_OLLAMA_MAX_INFLIGHT := 16

; Registry of in-flight async requests, keyed by an internal id. Each value
; is a Map(http, on_success, on_fail, cancelled). The cancelled flag flips
; to true when LLM_OllamaCancelAllAsync is called; the polling tick checks
; it and bails before invoking the user's callback.
global _LLM_Ollama_Async := Map()
global _LLM_Ollama_AsyncCounter := 0




; =====================================
; =====================================
; ======= 2/ Sync HTTP Client =========
; =====================================
; =====================================

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
LLM_OllamaGenerate(model, system_prompt, user_text, temperature := 0.1) {
	payload := LLM_BuildOllamaPayload(model, system_prompt, user_text, temperature)

	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("POST", LLM_OLLAMA_BASE_URL "/api/generate", false)
		http.SetTimeouts(LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT)
		http.SetRequestHeader("Content-Type", "application/json")
		http.Send(payload)

		if (http.Status != 200) {
			return ""
		}

		raw := http.ResponseText
		parsed := LLM_ParseOllamaResponse(raw)
		return parsed
	} catch as err {
		return ""
	}
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
	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("GET", LLM_OLLAMA_BASE_URL "/api/version", true)
		; 1 s timeouts (was 2 s × 4 phases = 8 s worst case). A local
		; Ollama answers in < 50 ms; if it doesn't reply within a single
		; second the daemon is unreachable and there's nothing to gain
		; from waiting longer.
		http.SetTimeouts(1000, 1000, 1000, 1000)
		http.Send()
		; Use ``poll_ms = 500`` for the health probe — we don't need 50 ms
		; reactivity for a check that fires every 10 s, and the tighter
		; loop was firing ~60 timer callbacks per probe, contesting the
		; message loop with the InputHook and dropping user keystrokes.
		_LLM_Ollama_PollGeneric(http, (status, _body) => on_result(status == 200), () => on_result(false), 0, 500)
	} catch {
		try on_result(false)
	}
}

/**
 * Returns the list of locally available model tags from Ollama (blocking).
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

		raw := http.ResponseText
		pos := 1
		while (RegExMatch(raw, '"name"\s*:\s*"([^"]+)"', &m, pos)) {
			models.Push(m[1])
			pos := m.Pos + m.Len
		}
	} catch {
	}
	return models
}




; =====================================
; =====================================
; ======= 3/ Async Generation =========
; =====================================
; =====================================

/**
 * Non-blocking variant of LLM_OllamaGenerate. Returns immediately; calls
 * ``on_success(text)`` when the model finishes responding, or ``on_fail()``
 * on any HTTP / parse failure. Mirrors hs.http.asyncPost on the HS side.
 *
 * Internally the request goes through WinHTTP's async mode (``Open(..., true)``)
 * and a SetTimer poll checks ``WaitForResponse(0)`` every LLM_OLLAMA_POLL_MS.
 * That gives us a non-blocking dispatch without depending on COM event sinks
 * (which AHK v2's ComObjConnect supports but is finicky to debug).
 *
 * @param {string}   model         - Ollama model tag.
 * @param {string}   system_prompt - System instruction.
 * @param {string}   user_text     - User context.
 * @param {number}   temperature   - Sampling temperature.
 * @param {function} on_success    - Callback receiving the generated text.
 * @param {function} on_fail       - Callback fired on any failure.
 * @returns {Integer} The request id (use with LLM_OllamaCancelAsync to abort).
 */
LLM_OllamaGenerate_Async(model, system_prompt, user_text, temperature, on_success, on_fail, stop_sequences := "") {
	global _LLM_Ollama_Async, _LLM_Ollama_AsyncCounter, LLM_OLLAMA_BASE_URL, LLM_OLLAMA_TIMEOUT

	_LLM_Ollama_AsyncCounter += 1
	req_id := _LLM_Ollama_AsyncCounter

	payload := LLM_BuildOllamaPayload(model, system_prompt, user_text, temperature, false, stop_sequences)
	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("POST", LLM_OLLAMA_BASE_URL "/api/generate", true)
		http.SetTimeouts(LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT)
		http.SetRequestHeader("Content-Type", "application/json")
		http.Send(payload)
	} catch as err {
		try on_fail()
		return req_id
	}

	_LLM_Ollama_TrimAsyncRegistry()
	_LLM_Ollama_Async[req_id] := Map("http", http, "on_success", on_success, "on_fail", on_fail, "cancelled", false)
	_LLM_Ollama_PollRequest(req_id, _LLM_OllamaParseAsyncBody)
	return req_id
}

/**
 * Cancel an in-flight async request. The polling tick will discover the
 * cancelled flag on its next iteration and bail without invoking the
 * caller's callbacks. Used by the engine to abandon stale variants when
 * the user keeps typing.
 * @param {Integer} req_id - The id returned by LLM_OllamaGenerate_Async.
 */
LLM_OllamaCancelAsync(req_id) {
	global _LLM_Ollama_Async
	if !_LLM_Ollama_Async.Has(req_id)
		return
	_LLM_Ollama_Async[req_id]["cancelled"] := true
}

/**
 * Cancel every in-flight async request. The engine calls this on each new
 * prediction fire so previous variants don't keep landing into the tooltip
 * after the user has typed more characters.
 */
LLM_OllamaCancelAllAsync() {
	global _LLM_Ollama_Async
	for _id, entry in _LLM_Ollama_Async
		entry["cancelled"] := true
}

/**
 * Polling tick — fires every LLM_OLLAMA_POLL_MS until the request is done
 * or cancelled. Uses ``WaitForResponse(0)`` which returns immediately with
 * a boolean indicating whether the response is ready.
 *
 * @param {Integer}  req_id   - The id used to look up the registry entry.
 * @param {function} parser   - parser(http, on_success, on_fail) — called when ready.
 */
_LLM_Ollama_PollRequest(req_id, parser) {
	global _LLM_Ollama_Async, LLM_OLLAMA_POLL_MS
	if !_LLM_Ollama_Async.Has(req_id)
		return
	entry := _LLM_Ollama_Async[req_id]
	if entry["cancelled"] {
		_LLM_Ollama_Async.Delete(req_id)
		return
	}
	http := entry["http"]
	ready := false
	try ready := http.WaitForResponse(0)
	if !ready {
		SetTimer(() => _LLM_Ollama_PollRequest(req_id, parser), -LLM_OLLAMA_POLL_MS)
		return
	}
	; Response received — pull status / body inside a try so a misbehaving
	; ResponseText property never leaves the registry entry alive.
	on_success := entry["on_success"]
	on_fail    := entry["on_fail"]
	_LLM_Ollama_Async.Delete(req_id)
	try {
		status := http.Status
		body   := http.ResponseText
	} catch {
		try on_fail()
		return
	}
	if (status != 200) {
		try on_fail()
		return
	}
	try parser(body, on_success, on_fail)
}

/**
 * Default async-response parser — extracts the ``response`` field from
 * Ollama's /api/generate reply and hands the unescaped text to on_success.
 */
_LLM_OllamaParseAsyncBody(body, on_success, on_fail) {
	text := LLM_ParseOllamaResponse(body)
	if (text == "") {
		try on_fail()
		return
	}
	try on_success(text)
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
_LLM_Ollama_PollGeneric(http, on_ok, on_err, deadline := 0, poll_ms := 0) {
	; First entry — compute the deadline once and bind it to subsequent
	; ticks. 3000 ms is generous enough for any local Ollama call (the
	; WinHTTP per-phase timeout is 2 s) but short enough to guarantee
	; the timer chain ends within a few hundred milliseconds of the
	; underlying request actually failing.
	if (deadline == 0)
		deadline := A_TickCount + 3000
	; Default poll cadence — callers that don't care use LLM_OLLAMA_POLL_MS
	; (50 ms, optimal for prediction latency). The health probe overrides
	; this with 500 ms because reactivity on a 10 s timer is irrelevant.
	if (poll_ms == 0)
		poll_ms := LLM_OLLAMA_POLL_MS

	ready := false
	try ready := http.WaitForResponse(0)
	if !ready {
		if (A_TickCount >= deadline) {
			try on_err()
			return
		}
		SetTimer(() => _LLM_Ollama_PollGeneric(http, on_ok, on_err, deadline, poll_ms), -poll_ms)
		return
	}
	try {
		status := http.Status
		body := http.ResponseText
	} catch {
		try on_err()
		return
	}
	try on_ok(status, body)
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
	; Maps preserve insertion order in AHK v2 — first key = oldest.
	for oldest_id, _entry in _LLM_Ollama_Async {
		_LLM_Ollama_Async.Delete(oldest_id)
		return
	}
}




; =====================================
; =====================================
; ======= 4/ Async Warmup =============
; =====================================
; =====================================

/**
 * Sends a minimal 1-token generation request so Ollama loads the model
 * weights into GPU memory. Mirrors api_ollama.lua's ``M.warmup`` — fire
 * and forget, no callback. Subsequent real requests skip the cold-start
 * penalty (1–3 s for a 2B model on a typical Windows GPU).
 *
 * @param {string} model - Ollama model tag.
 */
LLM_OllamaWarmup(model) {
	if (model == "")
		return
	payload := LLM_BuildOllamaPayload(model, "", " ", 0)
	; Override num_predict to 1 — fastest possible round-trip that still
	; forces weight load.
	payload := RegExReplace(payload, '"options"\s*:\s*\{', '"options":{"num_predict":1,')
	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("POST", LLM_OLLAMA_BASE_URL "/api/generate", true)
		http.SetTimeouts(LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT)
		http.SetRequestHeader("Content-Type", "application/json")
		http.Send(payload)
		; No callback — we just need the server to start loading. The
		; polling tick is still wired so the COM object eventually gets
		; reaped instead of hanging around forever.
		_LLM_Ollama_PollGeneric(http, (*) => 0, (*) => 0)
	} catch {
	}
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
 * @returns {Object} A handle ``{ Pid, Cancelled }`` callers can pass to
 *                   LLM_OllamaCancelStream to terminate the curl process.
 */
LLM_OllamaGenerate_Streaming(model, system_prompt, user_text, temperature, on_partial, on_success, on_fail, stop_sequences := "") {
	; Build the streaming payload — ``stream:true`` flips Ollama to JSONL.
	payload := LLM_BuildOllamaPayload(model, system_prompt, user_text, temperature, true, stop_sequences)

	; Write the payload to a temp file (curl --data-binary @file). Avoids
	; command-line length limits and shell escaping headaches with the JSON
	; quotes. The filename mixes the tick count with a per-call counter so
	; two streams fired in the same millisecond can't share a file.
	_LLM_Ollama_StreamCleanupOrphans()
	uid := _LLM_Ollama_NextStreamUid()
	tmp_payload := A_Temp . "\ergopti_ollama_" . uid . ".json"
	try {
		fh := FileOpen(tmp_payload, "w", "UTF-8")
		fh.Write(payload)
		fh.Close()
	} catch {
		try on_fail()
		return { Pid: 0, Cancelled: false }
	}

	tmp_stdout := A_Temp . "\ergopti_ollama_" . uid . ".out"
	; -N = no-buffer, -s = silent, -X POST + URL, -H Content-Type
	cmd := A_ComSpec . ' /c curl.exe -N -s -X POST '
		. '-H "Content-Type: application/json" '
		. '--data-binary @' . _Q(tmp_payload) . ' '
		. _Q(LLM_OLLAMA_BASE_URL . "/api/generate") . ' > ' . _Q(tmp_stdout)

	handle := { Pid: 0, Cancelled: false, TmpPayload: tmp_payload, TmpStdout: tmp_stdout }
	try {
		Run(cmd, , "Hide", &pid)
		handle.Pid := pid
	} catch {
		try on_fail()
		_LLM_Ollama_CleanupStreamFiles(handle)
		return handle
	}

	; Polling loop: read what's appeared in tmp_stdout so far, parse new
	; JSONL lines, fire on_partial for each. When the process exits, fire
	; on_success with the accumulated text.
	state := Map("acc", "", "last_pos", 0)
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
		_LLM_Ollama_CleanupStreamFiles(handle)
		try on_fail()
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
	} catch {
	}
	; Still alive? Schedule the next tick.
	if ProcessExist(handle.Pid) {
		SetTimer(() => _LLM_Ollama_StreamPoll(handle, state, on_partial, on_success, on_fail), -LLM_OLLAMA_POLL_MS)
		return
	}
	; Process exited: flush whatever is left on disk one last time before
	; declaring success.
	try {
		fh := FileOpen(handle.TmpStdout, "r", "UTF-8")
		if IsObject(fh) {
			fh.Pos := state["last_pos"]
			chunk := fh.Read()
			fh.Close()
			if (chunk != "") {
				_LLM_Ollama_ConsumeStreamChunk(chunk, state, on_partial)
			}
		}
	} catch {
	}
	final := state["acc"]
	_LLM_Ollama_CleanupStreamFiles(handle)
	if (final == "") {
		try on_fail()
		return
	}
	try on_success(final)
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
	for line in lines {
		if (line == "")
			continue
		if RegExMatch(line, '"response"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
			new_acc .= LLM_UnescapeJSON(m[1])
	}
	if (new_acc != state["acc"]) {
		state["acc"] := new_acc
		try on_partial(new_acc)
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
	if (handle.Pid > 0) {
		try ProcessClose(handle.Pid)
	}
}

_LLM_Ollama_CleanupStreamFiles(handle) {
	if (handle == "" or !IsObject(handle))
		return
	try FileDelete(handle.TmpPayload)
	try FileDelete(handle.TmpStdout)
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

; Wipes any leftover ``ergopti_ollama_*`` temp files older than 60 s. Runs
; before each new stream so a previous AHK instance that crashed mid-stream
; (Power loss, hard kill, …) never leaks files indefinitely. The 60 s
; window is generous — typical predictions complete in 1-3 s and any
; legitimate in-flight stream on a fresh AHK instance is younger than that.
_LLM_Ollama_StreamCleanupOrphans() {
	now := A_Now
	loop files, A_Temp . "\ergopti_ollama_*.json"
		_LLM_Ollama_TryDeleteIfOld(A_LoopFilePath, A_LoopFileTimeModified, now)
	loop files, A_Temp . "\ergopti_ollama_*.out"
		_LLM_Ollama_TryDeleteIfOld(A_LoopFilePath, A_LoopFileTimeModified, now)
}

_LLM_Ollama_TryDeleteIfOld(path, file_time, now) {
	try {
		age_s := DateDiff(now, file_time, "Seconds")
		if (age_s > 60)
			try FileDelete(path)
	} catch {
	}
}

; Tiny helper: wrap a path in double quotes for CMD. Not exported.
_Q(s) {
	return '"' . s . '"'
}




; =====================================
; =====================================
; ======= 6/ Payload Helpers ==========
; =====================================
; =====================================

/**
 * Serialises request parameters into an Ollama /api/generate JSON payload.
 * @param {string}  model         - Model tag.
 * @param {string}  system_prompt - System instruction.
 * @param {string}  user_text     - User context.
 * @param {number}  temperature   - Sampling temperature.
 * @param {boolean} streaming     - When true, emits ``stream:true`` for the
 *                                  curl-based streaming path; default false
 *                                  matches the existing sync caller behaviour.
 * @param {Array}   stop_sequences - Optional array of strings the model
 *                                   must stop generating at. When empty
 *                                   (the default), Ollama uses its own
 *                                   built-in stops. Power-user profiles
 *                                   can override via the ``stop_sequences``
 *                                   field on the profile JSON record.
 * @returns {string} JSON string ready to send.
 */
LLM_BuildOllamaPayload(model, system_prompt, user_text, temperature, streaming := false, stop_sequences := "") {
	EscapeJSON(s) {
		s := StrReplace(s, "\", "\\")
		s := StrReplace(s, '"', '\"')
		s := StrReplace(s, "`n", "\n")
		s := StrReplace(s, "`r", "")
		return s
	}

	stream_field := streaming ? "true" : "false"
	options := '"temperature":' temperature
	if (stop_sequences != "" and Type(stop_sequences) == "Array" and stop_sequences.Length > 0) {
		stops_json := ""
		for s in stop_sequences {
			if (stops_json != "")
				stops_json .= ","
			stops_json .= '"' . EscapeJSON(s) . '"'
		}
		options .= ',"stop":[' . stops_json . ']'
	}
	return '{"model":"' EscapeJSON(model) '",'
		. '"system":"' EscapeJSON(system_prompt) '",'
		. '"prompt":"' EscapeJSON(user_text) '",'
		. '"stream":' stream_field ','
		. '"options":{' options '}}'
}

/**
 * Extracts the "response" field from an Ollama /api/generate JSON reply.
 * @param {string} raw - Raw JSON response body.
 * @returns {string} The extracted response text, trimmed.
 */
LLM_ParseOllamaResponse(raw) {
	if RegExMatch(raw, '"response"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
		return LLM_UnescapeJSON(m[1])
	return ""
}

/**
 * Unescapes basic JSON string escape sequences.
 * @param {string} s - Escaped JSON string value.
 * @returns {string} Unescaped string.
 */
LLM_UnescapeJSON(s) {
	s := StrReplace(s, "\n",  "`n")
	s := StrReplace(s, "\r",  "`r")
	s := StrReplace(s, "\t",  "`t")
	s := StrReplace(s, '\"', '"')
	s := StrReplace(s, "\\", "\")
	return s
}
