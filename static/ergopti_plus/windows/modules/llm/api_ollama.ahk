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

; Ollama server port. 11434 is Ollama's own standard; the user can override it
; from the tray menu (persisted under [llm] ollama_port in config.toml) when they
; run the daemon on a non-standard port. LLM_OLLAMA_BASE_URL is DERIVED from it so
; every request below follows the configured port — change it via LLM_Ollama_SetPort.
global LLM_OLLAMA_PORT     := 11434
global LLM_OLLAMA_BASE_URL := "http://localhost:" . LLM_OLLAMA_PORT
; Weak laptops running qwen3.5:0.8b on CPU can exceed 30 s per token batch.
; WinHTTP aborts the whole request when this fires — too low and the tooltip
; never appears despite Ollama still computing in the background.
global LLM_OLLAMA_TIMEOUT  := 180000  ; ms (3 min) — cold CPU inference headroom

; Polling interval for the async path. 50 ms is the same cadence the HS side
; effectively gets from hs.http.asyncPost's underlying CFRunLoop tick — fine
; for interactive feedback (≤ 1 keystroke of latency) and cheap on CPU.
; Sentinel 0 — sourced at boot from the shared registry by LLMApiLoadTimings()
; (read only at runtime, long after boot, so the reassign always wins).
global LLM_OLLAMA_POLL_MS := 0

; Reassign the LLM backend timing globals (Ollama + remote poll/timeout and the
; installed-models cache TTL) from the shared registry _shared/modules/timings/constants.toml
; at boot, so they stay in sync with the macOS driver instead of re-typing the
; same literals. AHK v2 runs global initializers before the auto-execute body, so
; these start at the sentinel 0 and are sourced here; every read happens at
; runtime when a prediction fires, long after this loader runs. Fail-fast via
; TimingsGet on a missing key.
LLMApiLoadTimings() {
	global LLM_OLLAMA_POLL_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_POLL_MS, LLM_INSTALLED_CACHE_TTL_MS
	LLM_OLLAMA_POLL_MS         := TimingsGet("llm", "poll_interval_ms")
	LLM_REMOTE_TIMEOUT_MS      := TimingsGet("llm", "request_timeout_ms")
	LLM_REMOTE_POLL_MS         := TimingsGet("llm", "poll_interval_ms")
	LLM_INSTALLED_CACHE_TTL_MS := TimingsGet("llm", "installed_cache_ttl_ms")
}

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
; Latest-only queue when Ollama is busy — coalesces rapid re-fires instead of
; aborting in-flight WinHTTP (Abort made Ollama return ``content: ""``).
global _LLM_Ollama_Pending := ""
; In-flight curl streaming handles — cancelled by LLM_OllamaCancelAllAsync.
global _LLM_Ollama_ActiveStreams := []

; Stop tokens — same lists as macOS api_ollama.lua (STOP_BATCH / STOP_LINE).
global _LLM_OLLAMA_STOP_BATCH := ["<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "TAIL:"]
global _LLM_OLLAMA_STOP_LINE := ["<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "TAIL:", "`n`n", "===", "`n", "`r", "</", "Suite finale", "SUITE", "NEXT_WORDS:"]

; True after warmup succeeds — mirrors macOS api_ollama ``_is_ready``.
global _LLM_Ollama_IsReady := false
; Warmup retry loop (macOS warmup_controller parity). Without this, a single
; failed or slow warmup left _LLM_Ollama_IsReady false forever and the engine
; dropped every prediction at FirePrediction.
global _LLM_Ollama_WarmupRetryFn := unset
global _LLM_Ollama_WarmupRetryModel := ""
global _LLM_Ollama_WarmupRetryIntervalMs := 5000
global _LLM_Ollama_WarmupStartedTick := 0
; Monotonic id so stale warmup poll chains bail after a newer warmup starts.
global _LLM_Ollama_WarmupGeneration := 0
; Tracks the current in-flight warmup WinHTTP object so overlapping retries can
; abort the previous request before issuing a new one — prevents object leaks
global _LLM_Ollama_WarmupHttp := 0
; Warmup uses a shorter ceiling than real predictions — a hung warmup must not
; block the server for 3 min while the user is typing real requests.
global LLM_OLLAMA_WARMUP_TIMEOUT := 90000
; Warmup poll must outlive cold CPU model loads (3 s was far too short — logs
; showed endless "prediction deferred" with no "Model warmed up" line).
global _LLM_OLLAMA_WARMUP_POLL_MS := 250

; Streaming end-of-stream flush: the curl child's stdout file can lag the
; process exit by a few ms, so after the child is gone we re-read the file a
; few more times before declaring the result empty. These were a blocking
; Sleep(40) loop inside the timer callback (up to 200 ms of frozen message
; pump — dropped keystrokes the moment streaming is re-enabled); they now drive
; a re-armed one-shot timer so the pump stays live between reads.
global _LLM_OLLAMA_STREAM_FLUSH_MAX_RETRIES := 5
global _LLM_OLLAMA_STREAM_FLUSH_RETRY_MS := 40

/**
 * Updates the Ollama server port and rebuilds LLM_OLLAMA_BASE_URL so every
 * subsequent request targets it. Rejects non-integers and out-of-range ports
 * (privileged < 1024, or > 65535). Called from the tray menu and at boot from
 * LLM_Menu_Init with the persisted value.
 * @param {Integer} port - The new Ollama port (1024-65535).
 * @returns {Boolean} true when applied, false when rejected.
 */
LLM_Ollama_SetPort(port) {
	global LLM_OLLAMA_PORT, LLM_OLLAMA_BASE_URL
	if !IsInteger(port)
		return false
	port := Integer(port)
	if (port < 1024 || port > 65535)
		return false
	LLM_OLLAMA_PORT     := port
	LLM_OLLAMA_BASE_URL := "http://localhost:" . port
	return true
}




; =====================================
; =====================================
; ======= 2/ Sync HTTP Client =========
; =====================================
; =====================================

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

LLM_OllamaGenerate(model, system_prompt, full_text, temperature := 0.1, tail_text := "") {
	; Sync path has no max_words context, so it asks for the shared default budget
	; explicitly via PB_DEFAULT_MAX_TOKENS (no literal — single cross-driver source)
	payload := LLM_BuildOllamaPayload(model, system_prompt, full_text, temperature, false, "", PB_DEFAULT_MAX_TOKENS, false, tail_text)

	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("POST", LLM_OLLAMA_BASE_URL "/api/chat", false)
		http.SetTimeouts(LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT)
		_LLM_Ollama_SendUtf8(http, payload)

		if (http.Status != 200) {
			return ""
		}

		raw := http.ResponseText
		return LLM_ParseOllamaChatResponse(raw)
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
		_LLM_Ollama_PollGeneric(http, (status, _body) => on_result(status == 200), () => on_result(false), 0, 0, 500)
	} catch {
		try on_result(false)
	}
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
	pos := 1
	while (RegExMatch(raw, '"name"\s*:\s*"([^"]+)"', &m, pos)) {
		models.Push(m[1])
		pos := m.Pos + m.Len
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
 * model tags from ``GET /api/tags`` through WinHTTP's async mode + a polling tick
 * (mirrors ``LLM_OllamaIsRunning_Async``), so the keyboard/menu thread is NEVER
 * frozen on a cold or slow daemon. The blocking version, called per catalogue row
 * at every tray rebuild past the installed-cache TTL, stalled the menu (and dropped
 * keystrokes) for up to ~20 s — the UI must read only the in-memory cache and let
 * THIS function refresh it in the background (AUDIT_AHK_2026-06-19 / TODO.md).
 * @param {function} on_result - Callback receiving an Array of tag names ([] on failure).
 */
LLM_OllamaListModels_Async(on_result) {
	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("GET", LLM_OLLAMA_BASE_URL "/api/tags", true)
		; Same 1 s per-phase budget as the health probe — a local daemon answers in
		; well under a second; if it doesn't, the menu must not wait on it.
		http.SetTimeouts(1000, 1000, 1000, 1000)
		http.Send()
		; 500 ms poll cadence (not the 50 ms prediction cadence): this fires from a
		; menu rebuild, not a per-keystroke path, so reactivity is irrelevant and the
		; looser loop spares the message pump.
		_LLM_Ollama_PollGeneric(http,
			(status, body) => on_result(status == 200 ? _LLM_Ollama_ParseTagNames(body) : []),
			() => on_result([]),
			0, 0, 500)
	} catch {
		try on_result([])
	}
}

/**
 * Removes the local copy of an Ollama model via the daemon's
 * ``DELETE /api/delete`` endpoint. Blocking — the caller is responsible
 * for confirming with the user before invoking this.
 *
 * @param {string} tag - Ollama model tag (e.g. ``qwen3-coder:30b``).
 * @returns {Boolean} True on HTTP 200, false on any failure.
 */
LLM_OllamaDeleteModel(tag) {
	if (tag == "")
		return false
	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("DELETE", LLM_OLLAMA_BASE_URL "/api/delete", false)
		http.SetTimeouts(5000, 5000, 10000, 10000)
		http.SetRequestHeader("Content-Type", "application/json")
		; The payload is intentionally minimal — Ollama tolerates the
		; ``model`` field too on newer versions, but ``name`` is the
		; documented one and works on every release we care about.
		body := '{"name":"' . StrReplace(tag, '"', '\"') . '"}'
		http.Send(body)
		ok := (http.Status >= 200 and http.Status < 300)
		try {
			if (ok)
				LoggerSuccess("LLM.ollama", "Deleted Ollama model '{1}'.", tag)
			else
				LoggerWarn("LLM.ollama", "Ollama delete '{1}' returned HTTP {2}.", tag, http.Status)
		}
		return ok
	} catch as e {
		try LoggerError("LLM.ollama", "Ollama delete '{1}' failed: {2}.", tag, e.Message)
		return false
	}
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
		if (_LLM_Ollama_Pending is Map and _LLM_Ollama_Pending.Has("on_fail"))
			try _LLM_Ollama_Pending["on_fail"]()
		_LLM_Ollama_Pending := job
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
	_LLM_Ollama_StreamCleanupOrphans()
	uid := _LLM_Ollama_NextStreamUid()
	tmp_dir := _LLM_Ollama_TempDir()
	tmp_payload := tmp_dir . "\ergopti_ollama_" . uid . ".json"
	tmp_stdout := tmp_dir . "\ergopti_ollama_" . uid . ".out"
	if !FSWrite(tmp_payload, payload) {
		try LoggerWarn("LLM.ollama", "Failed to write curl payload file.")
		try job["on_fail"]()
		_LLM_Ollama_DrainPending()
		return
	}
	curl_exe := A_WinDir . "\System32\curl.exe"
	cmdLine := '"' . curl_exe . '" -s -S -X POST '
		. '-H "Content-Type: application/json" '
		. '--data-binary @' . _Q(tmp_payload) . ' '
		. _Q(LLM_OLLAMA_BASE_URL . "/api/chat") . ' '
		. '-o ' . _Q(tmp_stdout)
	pid := 0
	try {
		Run(cmdLine, , "Hide", &pid)
	} catch as err {
		try FSDelete(tmp_payload)
		try LoggerWarn("LLM.ollama", "curl launch failed: {1}.", err.Message)
		try job["on_fail"]()
		_LLM_Ollama_DrainPending()
		return
	}
	_LLM_Ollama_TrimAsyncRegistry()
	payload_snip := StrLen(payload) > 160 ? SubStr(payload, 1, 160) . "…" : payload
	_LLM_Ollama_Async[req_id] := Map(
		"pid", pid, "tmp_payload", tmp_payload, "tmp_stdout", tmp_stdout,
		"on_success", job["on_success"], "on_fail", job["on_fail"],
		"cancelled", false, "start_tick", A_TickCount,
		"timeout_ms", LLM_OLLAMA_TIMEOUT + 5000, "payload_snip", payload_snip)
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
	entry := _LLM_Ollama_Async[req_id]
	entry["cancelled"] := true
	if entry.Has("http") {
		try entry["http"].Abort()
	} else if entry.Has("pid") and entry["pid"] > 0 {
		try ProcessClose(entry["pid"])
	}
}

/**
 * Cancel every in-flight async request. The engine calls this on each new
 * prediction fire so previous variants don't keep landing into the tooltip
 * after the user has typed more characters.
 */
/**
 * Cancels in-flight curl streams only. WinHTTP async requests are left running;
 * stale responses are ignored via the engine's request_id (macOS parity).
 */
LLM_OllamaCancelStreams() {
	global _LLM_Ollama_ActiveStreams
	for _, h in _LLM_Ollama_ActiveStreams
		try LLM_OllamaCancelStream(h)
	_LLM_Ollama_ActiveStreams := []
}

LLM_OllamaCancelAllAsync() {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending
	for _id, entry in _LLM_Ollama_Async {
		entry["cancelled"] := true
		if entry.Has("http") {
			try entry["http"].Abort()
		} else if entry.Has("pid") and entry["pid"] > 0 {
			try ProcessClose(entry["pid"])
		}
	}
	LLM_OllamaCancelStreams()
	; Drop any coalesced-but-not-yet-dispatched job. Otherwise the already-armed
	; poll tick discovers the cancelled in-flight entry, deletes it, and calls
	; _LLM_Ollama_DrainPending() which re-dispatches the pending job — a fresh
	; curl POST + PII temp-file write — AFTER the driver was suspended (the engine
	; calls this from Ergopti_OnSuspendEnter -> LLM_Engine_StopGeneration). Honour
	; the async contract by failing the displaced job exactly once before dropping.
	if (_LLM_Ollama_Pending is Map) {
		if _LLM_Ollama_Pending.Has("on_fail")
			try _LLM_Ollama_Pending["on_fail"]()
		_LLM_Ollama_Pending := ""
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
		_LLM_Ollama_DrainPending()
		return
	}
	http := entry["http"]
	ready := false
	try {
		ready := http.WaitForResponse(0)
	} catch as com_err {
		; A COM exception here means the connection dropped (WiFi cut, Ollama
		; restarted). Abandon immediately — re-queuing would produce a busy-loop
		; at 50 ms saturating the CPU until the 3-minute global timeout fires
		; (ollama-com-exception-busy-loop fix).
		try LoggerWarn("LLM.ollama", "WaitForResponse threw COM error — aborting req {1}: {2}", req_id, com_err.Message)
		on_fail := entry["on_fail"]
		_LLM_Ollama_Async.Delete(req_id)
		try on_fail()
		_LLM_Ollama_DrainPending()
		return
	}
	if !ready {
		if (entry.Has("start_tick") and entry.Has("timeout_ms") and _LLM_DeadlineExpired(entry["start_tick"], entry["timeout_ms"])) {
			elapsed := A_TickCount - entry["start_tick"]
			try LoggerWarn("LLM.ollama", "Ollama request timed out after {1} ms.", elapsed)
			on_fail := entry["on_fail"]
			_LLM_Ollama_Async.Delete(req_id)
			try on_fail()
			_LLM_Ollama_DrainPending()
			return
		}
		SetTimer(() => _LLM_Ollama_PollRequest(req_id, parser), -LLM_OLLAMA_POLL_MS)
		return
	}
	; Response received — honour cancellation before invoking callbacks. Without
	; this check, ``Abort()`` races could still deliver empty ``content`` bodies
	; from superseded requests into the active variant loop.
	if entry["cancelled"] {
		_LLM_Ollama_Async.Delete(req_id)
		_LLM_Ollama_DrainPending()
		return
	}
	on_success := entry["on_success"]
	on_fail    := entry["on_fail"]
	_LLM_Ollama_Async.Delete(req_id)
	try {
		status := http.Status
		body   := http.ResponseText
	} catch {
		try on_fail()
		_LLM_Ollama_DrainPending()
		return
	}
	if (status != 200) {
		try LoggerWarn("LLM.ollama", "Ollama request failed — HTTP {1}.", status)
		try on_fail()
		_LLM_Ollama_DrainPending()
		return
	}
	try parser(body, on_success, on_fail, entry)
	_LLM_Ollama_DrainPending()
}

; Polls a non-streaming curl child until stdout is ready or the slot times out.
_LLM_Ollama_PollCurl(req_id) {
	global _LLM_Ollama_Async, LLM_OLLAMA_POLL_MS
	if !_LLM_Ollama_Async.Has(req_id)
		return
	entry := _LLM_Ollama_Async[req_id]
	if entry["cancelled"] {
		if entry.Has("pid") and entry["pid"] > 0
			try ProcessClose(entry["pid"])
		_LLM_Ollama_CleanupCurlFiles(entry)
		_LLM_Ollama_Async.Delete(req_id)
		_LLM_Ollama_DrainPending()
		return
	}
	if (entry.Has("start_tick") and entry.Has("timeout_ms") and _LLM_DeadlineExpired(entry["start_tick"], entry["timeout_ms"])) {
		if entry.Has("pid") and entry["pid"] > 0
			try ProcessClose(entry["pid"])
		elapsed := entry.Has("start_tick") ? (A_TickCount - entry["start_tick"]) : 0
		try LoggerWarn("LLM.ollama", "curl request timed out after {1} ms.", elapsed)
		on_fail := entry["on_fail"]
		_LLM_Ollama_CleanupCurlFiles(entry)
		_LLM_Ollama_Async.Delete(req_id)
		try on_fail()
		_LLM_Ollama_DrainPending()
		return
	}
	if entry.Has("pid") and entry["pid"] > 0 and ProcessExist(entry["pid"]) {
		SetTimer(() => _LLM_Ollama_PollCurl(req_id), -LLM_OLLAMA_POLL_MS)
		return
	}
	on_success := entry["on_success"]
	on_fail    := entry["on_fail"]
	body := ""
	try {
		if entry.Has("tmp_stdout") and FileExist(entry["tmp_stdout"])
			body := FileRead(entry["tmp_stdout"], "UTF-8-RAW")
	} catch {
		body := ""
	}
	_LLM_Ollama_CleanupCurlFiles(entry)
	_LLM_Ollama_Async.Delete(req_id)
	if (body == "") {
		try LoggerWarn("LLM.ollama", "curl finished with empty stdout.")
		try on_fail()
		_LLM_Ollama_DrainPending()
		return
	}
	try _LLM_OllamaParseAsyncBody(body, on_success, on_fail, entry)
	_LLM_Ollama_DrainPending()
}

_LLM_Ollama_CleanupCurlFiles(entry) {
	if !(entry is Map)
		return
	if entry.Has("tmp_payload") and entry["tmp_payload"] != ""
		try FSDelete(entry["tmp_payload"])
	if entry.Has("tmp_stdout") and entry["tmp_stdout"] != ""
		try FSDelete(entry["tmp_stdout"])
}

/**
 * Default async-response parser — extracts the ``response`` field from
 * Ollama's /api/generate reply and hands the unescaped text to on_success.
 */
_LLM_OllamaParseAsyncBody(body, on_success, on_fail, entry := "") {
	text := LLM_ParseOllamaChatResponse(body)
	if (text == "") {
		snip := StrLen(body) > 120 ? SubStr(body, 1, 120) . "…" : body
		payload_hint := ""
		if (entry is Map) and entry.Has("payload_snip")
			payload_hint := " Payload: «" . entry["payload_snip"] . "»."
		try LoggerWarn("LLM.ollama", "Ollama returned an empty prediction (parse miss). Body: «{1}».{2}", snip, payload_hint)
		try on_fail(Map("error", true, "message", "empty prediction"))
		return
	}
	snip := StrLen(text) > 60 ? SubStr(text, 1, 60) . "…" : text
	try LoggerInfo("LLM.ollama", "Prediction received ({1} chars): «{2}».", StrLen(text), snip)
	try LLM_OllamaNoteInferenceSuccess()
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
	try ready := http.WaitForResponse(0)
	if !ready {
		if _LLM_DeadlineExpired(start_tick, timeout_ms) {
			; Abort the in-flight request before dropping our reference — a
			; server that accepts the connection but never responds would
			; otherwise keep the COM object + socket resident until WinHTTP's
			; own timeout fires, long after we have stopped polling it.
			try http.Abort()
			try on_err()
			return
		}
		SetTimer(() => _LLM_Ollama_PollGeneric(http, on_ok, on_err, start_tick, timeout_ms, poll_ms), -poll_ms)
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
	; Kill the curl child so it does not keep writing to the temp file
	; after we abandon the registry entry — the PID would otherwise
	; accumulate until it expires naturally (up to 3 min).
	if oldest_entry.Has("pid") and oldest_entry["pid"] > 0
		try ProcessClose(oldest_entry["pid"])
	_LLM_Ollama_CleanupCurlFiles(oldest_entry)
	; Honour the async contract: exactly one of on_success / on_fail must
	; fire. Without this the caller (e.g. the prediction engine slot state
	; machine) hangs forever waiting for a callback that will never arrive.
	if oldest_entry.Has("on_fail") and oldest_entry["on_fail"] is Func
		try oldest_entry["on_fail"].Call()
	_LLM_Ollama_Async.Delete(oldest_id)
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
	global _LLM_Ollama_IsReady, _LLM_Ollama_WarmupGeneration, LLM_OLLAMA_WARMUP_TIMEOUT
		, _LLM_Ollama_WarmupHttp
	if (model == "")
		return
	if _LLM_Ollama_IsReady
		return
	; Abort any in-flight warmup request before issuing a new one — overlapping
	; retries would otherwise leak WinHTTP COM objects and hold server connections
	if (_LLM_Ollama_WarmupHttp != 0) {
		try _LLM_Ollama_WarmupHttp.Abort()
		_LLM_Ollama_WarmupHttp := 0
	}
	_LLM_Ollama_WarmupGeneration += 1
	gen := _LLM_Ollama_WarmupGeneration
	payload := LLM_BuildOllamaPayload(model, "", " ", 0, false, "", 1, false)
	payload := RegExReplace(payload, '"num_predict":\d+', '"num_predict":1', , 1)
	try {
		_LLM_Ollama_WarmupHttp := ComObject("WinHttp.WinHttpRequest.5.1")
		_LLM_Ollama_WarmupHttp.Open("POST", LLM_OLLAMA_BASE_URL "/api/chat", true)
		_LLM_Ollama_WarmupHttp.SetTimeouts(LLM_OLLAMA_WARMUP_TIMEOUT, LLM_OLLAMA_WARMUP_TIMEOUT,
			LLM_OLLAMA_WARMUP_TIMEOUT, LLM_OLLAMA_WARMUP_TIMEOUT)
		_LLM_Ollama_SendUtf8(_LLM_Ollama_WarmupHttp, payload)
		_LLM_Ollama_PollGeneric(_LLM_Ollama_WarmupHttp,
			(status, _body) => _LLM_Ollama_OnWarmupDone(status, gen),
			() => _LLM_Ollama_OnWarmupPollFailed("timeout", gen),
			A_TickCount, LLM_OLLAMA_WARMUP_TIMEOUT, _LLM_OLLAMA_WARMUP_POLL_MS)
	} catch as e {
		try LoggerWarn("LLM.ollama", "Warmup POST failed: {1}.", e.Message)
		_LLM_Ollama_WarmupHttp := 0
		_LLM_Ollama_OnWarmupPollFailed("send", gen)
	}
}

_LLM_Ollama_OnWarmupPollFailed(reason, gen := 0) {
	global _LLM_Ollama_WarmupGeneration
	if (gen != 0 and gen != _LLM_Ollama_WarmupGeneration)
		return
	try LoggerInfo("LLM.ollama", "Warmup poll ended ({1}) — grace inference may proceed.", reason)
}

_LLM_Ollama_OnWarmupDone(status, gen := 0) {
	global _LLM_Ollama_IsReady, _LLM_Ollama_WarmupGeneration
	if (gen != 0 and gen != _LLM_Ollama_WarmupGeneration)
		return
	if (status = 200) {
		_LLM_Ollama_IsReady := true
		try LoggerInfo("LLM.ollama", "Model warmed up — ready for predictions.")
		; Warmup succeeded — reset the backoff so a future warmup cycle starts fresh
		LLM_OllamaCancelWarmupRetry(true)
	} else {
		try LoggerInfo("LLM.ollama", "Warmup finished with HTTP {1} — will retry.", status)
	}
}

/**
 * Keeps firing warmup POSTs with exponential backoff until ``_LLM_Ollama_IsReady``
 * flips true or LLM is disabled. Mirrors macOS ``warmup_controller.lua``.
 * @param {string} model - Display name or Ollama tag.
 */
LLM_OllamaScheduleWarmupRetry(model := "") {
	global _LLM_Ollama_WarmupRetryModel, _LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_WarmupRetryFn
		, _LLM_Ollama_WarmupStartedTick
	if (_LLM_Ollama_WarmupStartedTick = 0)
		_LLM_Ollama_WarmupStartedTick := A_TickCount
	if (model != "")
		_LLM_Ollama_WarmupRetryModel := (IsSet(LLM_ResolveOllamaTag))
			? LLM_ResolveOllamaTag(model) : model
	if (_LLM_Ollama_WarmupRetryModel == "")
		return
	if LLM_OllamaIsReady()
		return
	if (IsSet(_LLM_Menu) && _LLM_Menu.Has("enabled") && !_LLM_Menu["enabled"])
		return
	LLM_OllamaWarmup(_LLM_Ollama_WarmupRetryModel)
	if (IsSet(_LLM_Ollama_WarmupRetryFn) && _LLM_Ollama_WarmupRetryFn)
		SetTimer(_LLM_Ollama_WarmupRetryFn, 0)
	_LLM_Ollama_WarmupRetryFn := LLM_Ollama_WarmupRetryTick.Bind()
	SetTimer(_LLM_Ollama_WarmupRetryFn, -_LLM_Ollama_WarmupRetryIntervalMs)
}

LLM_Ollama_WarmupRetryTick() {
	global _LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_WarmupRetryModel, _LLM_Ollama_Async
	; Pause must silence every LLM background activity — no HTTP while suspended.
	if A_IsSuspended
		return
	if LLM_OllamaIsReady()
		return
	; Do not stack warmups behind an in-flight prediction — Ollama is single-queue.
	if (IsSet(_LLM_Ollama_Async) and _LLM_Ollama_Async.Count > 0)
		return
	if (IsSet(_LLM_Menu) && _LLM_Menu.Has("enabled") && !_LLM_Menu["enabled"]) {
		LLM_OllamaCancelWarmupRetry()
		return
	}
	_LLM_Ollama_WarmupRetryIntervalMs := Min(_LLM_Ollama_WarmupRetryIntervalMs * 2, 60000)
	try LoggerInfo("LLM.ollama", "Warmup retry in {1} ms for '{2}'.",
		_LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_WarmupRetryModel)
	LLM_OllamaScheduleWarmupRetry(_LLM_Ollama_WarmupRetryModel)
}

LLM_OllamaCancelWarmupRetry(reset_backoff := false) {
	global _LLM_Ollama_WarmupRetryFn, _LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_WarmupStartedTick
		, _LLM_Ollama_IsReady, _LLM_Ollama_WarmupHttp
	if (IsSet(_LLM_Ollama_WarmupRetryFn) && _LLM_Ollama_WarmupRetryFn) {
		SetTimer(_LLM_Ollama_WarmupRetryFn, 0)
		_LLM_Ollama_WarmupRetryFn := unset
	}
	if (_LLM_Ollama_WarmupHttp != 0) {
		try _LLM_Ollama_WarmupHttp.Abort()
		_LLM_Ollama_WarmupHttp := 0
	}
	; Only reset the backoff interval on warmup success — callers that merely cancel
	; (e.g. LLM_Bridge_Stop on driver teardown) must not reset it, otherwise a slow
	; server would restart the full backoff ramp from 5 s every time the driver
	; is re-enabled without Ollama actually being ready
	if reset_backoff
		_LLM_Ollama_WarmupRetryIntervalMs := 5000
	; Only reset the started tick when warmup was successful — resetting unconditionally
	; re-triggers the 8 s grace window on every model change, delaying first predictions
	if _LLM_Ollama_IsReady
		_LLM_Ollama_WarmupStartedTick := 0
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
LLM_OllamaGenerate_Streaming(model, system_prompt, full_text, temperature, on_partial, on_success, on_fail, stop_sequences := "", max_tokens := "", is_batch := false, tail_text := "") {
	; Build the streaming payload — ``stream:true`` flips Ollama to JSONL (/api/chat).
	payload := LLM_BuildOllamaPayload(model, system_prompt, full_text, temperature, true, stop_sequences, max_tokens, is_batch, tail_text)

	; Write the payload to a temp file (curl --data-binary @file). Avoids
	; command-line length limits and shell escaping headaches with the JSON
	; quotes. The filename mixes the tick count with a per-call counter so
	; two streams fired in the same millisecond can't share a file.
	_LLM_Ollama_StreamCleanupOrphans()
	uid := _LLM_Ollama_NextStreamUid()
	tmp_dir := _LLM_Ollama_TempDir()
	tmp_payload := tmp_dir . "\ergopti_ollama_" . uid . ".json"
	if !FSWrite(tmp_payload, payload) {
		try on_fail()
		return { Pid: 0, Cancelled: false }
	}

	tmp_stdout := tmp_dir . "\ergopti_ollama_" . uid . ".out"
	; Launch curl.exe directly (not cmd /c): hidden cmd often lacks curl on PATH and
	; shell redirects (> file) silently produce empty/missing stdout — logs showed
	; "Streaming finished with empty response. No stdout file."
	curl_exe := A_WinDir . "\System32\curl.exe"
	cmdLine := '"' . curl_exe . '" -N -s -S -X POST '
		. '-H "Content-Type: application/json" '
		. '--data-binary @' . _Q(tmp_payload) . ' '
		. _Q(LLM_OLLAMA_BASE_URL . "/api/chat") . ' '
		. '-o ' . _Q(tmp_stdout)

	handle := { Pid: 0, Cancelled: false, TmpPayload: tmp_payload, TmpStdout: tmp_stdout }
	try {
		Run(cmdLine, , "Hide", &pid)
		handle.Pid := pid
	} catch {
		try on_fail()
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
		_LLM_Ollama_CleanupStreamFiles(handle)
		_LLM_Ollama_RemoveStreamHandle(handle)
		try LoggerInfo("LLM.ollama", "Streaming cancelled (newer prediction).")
		try on_fail()
		return
	}
	if (state.Has("start_tick") and state.Has("timeout_ms") and _LLM_DeadlineExpired(state["start_tick"], state["timeout_ms"])) {
		if (handle.Pid > 0)
			try ProcessClose(handle.Pid)
		_LLM_Ollama_CleanupStreamFiles(handle)
		_LLM_Ollama_RemoveStreamHandle(handle)
		elapsed := state.Has("start_tick") ? (A_TickCount - state["start_tick"]) : 0
		try LoggerWarn("LLM.ollama", "Streaming timed out after {1} ms.", elapsed)
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
	} catch {
	}
	retries := state.Has("flush_retries") ? state["flush_retries"] : 0
	; Retry when the output file is still empty — curl may have just finished
	; but not yet flushed its OS write buffer. Conversely, if the file exists
	; and has data, we have already drained it above; no retry needed.
	more_to_read := (!FileExist(handle.TmpStdout) or FileGetSize(handle.TmpStdout) = 0)
	if (state["acc"] == "" and more_to_read and retries < _LLM_OLLAMA_STREAM_FLUSH_MAX_RETRIES) {
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
	if (state.Has("leftover") and state["leftover"] != "") {
		_resid := state["leftover"]
		state["leftover"] := ""
		_LLM_Ollama_ConsumeStreamChunk(_resid . "`n", state, on_partial)
	}
	final := state["acc"]
	_LLM_Ollama_CleanupStreamFiles(handle)
	_LLM_Ollama_RemoveStreamHandle(handle)
	if (final == "") {
		hint := _LLM_Ollama_StreamFailHint(handle.TmpStdout)
		try LoggerWarn("LLM.ollama", "Streaming finished with empty response.{1}", hint != "" ? " " hint : "")
		try on_fail()
		return
	}
	try LLM_OllamaNoteInferenceSuccess()
	try on_success(final)
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
		token := _LLM_Ollama_ParseStreamLine(line)
		if (token != "")
			new_acc .= token
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

; Wipes any leftover ``ergopti_ollama_*`` temp files older than 60 s. Runs
; before each new stream so a previous AHK instance that crashed mid-stream
; (Power loss, hard kill, …) never leaks files indefinitely. The 60 s
; window is generous — typical predictions complete in 1-3 s and any
; legitimate in-flight stream on a fresh AHK instance is younger than that.
_LLM_Ollama_StreamCleanupOrphans() {
	now := A_Now
	; Sweep both the per-instance hardened dir (where payloads now live) and the
	; legacy A_Temp root (older builds wrote directly there; a crash from one of
	; those leaves orphans we must still reap). Recursive ``FR`` reaches the
	; PID-keyed subdirectories created by _LLM_Ollama_TempDir().
	loop files, A_Temp . "\ergopti_ollama_*.json", "FR"
		_LLM_Ollama_TryDeleteIfOld(A_LoopFilePath, A_LoopFileTimeModified, now)
	loop files, A_Temp . "\ergopti_ollama_*.out", "FR"
		_LLM_Ollama_TryDeleteIfOld(A_LoopFilePath, A_LoopFileTimeModified, now)
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




; =====================================
; =====================================
; ======= 6/ Payload Helpers ==========
; =====================================
; =====================================

/**
 * Escapes a string for embedding in a JSON value. Written via ``FSWrite``
 * (UTF-8-RAW) into the curl payload file — accents pass through as UTF-8.
 */
_LLM_Ollama_EscapeJSON(s) {
	out := ""
	loop parse s {
		ch := A_LoopField
		code := Ord(ch)
		if (ch = "\") {
			out .= "\\"
		} else if (ch = '"') {
			out .= '\"'
		} else if (ch = "`n") {
			out .= "\n"
		} else if (ch = "`r") {
			out .= "\r"
		} else if (ch = "`t") {
			out .= "\t"
		} else if (code < 0x20) {
			out .= Format("\u{:04X}", code)
		} else {
			out .= ch
		}
	}
	return out
}

_LLM_Ollama_IsLineMode(system_prompt, is_batch) {
	if is_batch
		return false
	if (InStr(system_prompt, "TAIL_CORRECTED") or InStr(system_prompt, "NEXT_WORDS"))
		return false
	return true
}

_LLM_Ollama_StopsArray(stop_sequences, line_mode, is_batch) {
	if (stop_sequences != "" and Type(stop_sequences) == "Array" and stop_sequences.Length > 0)
		return stop_sequences
	global _LLM_OLLAMA_STOP_BATCH, _LLM_OLLAMA_STOP_LINE
	return (line_mode && !is_batch) ? _LLM_OLLAMA_STOP_LINE : _LLM_OLLAMA_STOP_BATCH
}

_LLM_Ollama_StopsJson(stop_sequences, line_mode, is_batch) {
	stops := _LLM_Ollama_StopsArray(stop_sequences, line_mode, is_batch)
	out := ""
	for _, s in stops {
		escaped := _LLM_Ollama_EscapeJSON(s)
		if (escaped = "")
			continue
		if (out != "")
			out .= ","
		out .= '"' escaped '"'
	}
	return out
}

/**
 * Builds the ``messages`` array for /api/chat — mirrors macOS ``build_request_context``.
 */
_LLM_Ollama_BuildMessages(system_prompt, full_text, tail_text, model) {
	messages := []
	sys := system_prompt
	user := full_text
	tail := (tail_text != "") ? tail_text : full_text
	if (InStr(sys, "PREFIX") and InStr(sys, "TAIL")) {
		user := Format('PREFIX: "{1}"`nTAIL: "{2}"', full_text, tail)
	} else if (sys != "" and InStr(sys, "{context}")) {
		sys := StrReplace(sys, "{context}", full_text)
		user := sys
		sys := ""
	}
	if RegExMatch(model, "i)qwen3|deepseek|(?:^|:)r1|think|reasoning") {
		if !InStr(user, "/no_think")
			user .= "`n`n/no_think"
	}
	if (sys != "")
		messages.Push(Map("role", "system", "content", sys))
	messages.Push(Map("role", "user", "content", user))
	return messages
}

/**
 * Serialises parameters into an Ollama /api/chat JSON payload (macOS parity).
 */
LLM_BuildOllamaPayload(model, system_prompt, full_text, temperature, streaming := false, stop_sequences := "", max_tokens := "", is_batch := false, tail_text := "") {
	line_mode := _LLM_Ollama_IsLineMode(system_prompt, is_batch)
	; Output-token cap = the shared PromptBuilder budget threaded from the engine
	; (single cross-driver source). No local re-derivation and no literal: an unset
	; ("") or out-of-range value resolves to PB_DEFAULT_MAX_TOKENS, the one shared
	; constant codegen'd from the domain DEFAULT_MAX_TOKENS.
	num_predict := (max_tokens is Number and max_tokens > 0) ? Integer(max_tokens) : PB_DEFAULT_MAX_TOKENS
	msgs := _LLM_Ollama_BuildMessages(system_prompt, full_text, tail_text, model)
	msgs_json := ""
	for _, m in msgs {
		if (msgs_json != "")
			msgs_json .= ","
		msgs_json .= '{"role":"' m["role"] '","content":"' _LLM_Ollama_EscapeJSON(m["content"]) '"}'
	}
	stream_field := streaming ? "true" : "false"
	return '{"model":"' _LLM_Ollama_EscapeJSON(model) '",'
		. '"messages":[' msgs_json '],'
		. '"stream":' stream_field ','
		. '"think":false,'
		. '"keep_alive":"30m",'
		. '"options":{"temperature":' Format("{:g}", temperature)
		. ',"num_predict":' num_predict
		. ',"thinking_budget":0'
		. ',"stop":[' _LLM_Ollama_StopsJson(stop_sequences, line_mode, is_batch) . ']}}'
}

/**
 * Parses one NDJSON line from a /api/chat stream (``message.content`` tokens).
 */
_LLM_Ollama_ParseStreamLine(line) {
	if (line == "")
		return ""
	try {
		obj := JsonParse(line)
		if !(obj is Map) or !obj.Has("message")
			return ""
		msg := obj["message"]
		if !(msg is Map) or !msg.Has("content")
			return ""
		content := msg["content"]
		return (Type(content) = "String") ? content : ""
	} catch as e {
		err_substr := SubStr(line, 1, 200)
		try LoggerError("LLM.ollama", "JSON parse failed in stream: {1}. Raw (200c): {2}", e.Message, err_substr)
		return ""
	}
}

/**
 * Extracts assistant text from a /api/chat JSON reply (non-streaming).
 */
LLM_ParseOllamaChatResponse(raw) {
	if (raw == "")
		return ""
	try {
		obj := JsonParse(raw)
		if (obj is Map) and obj.Has("message") {
			msg := obj["message"]
			if (msg is Map) and msg.Has("content") and Type(msg["content"]) = "String" {
				text := Trim(msg["content"])
				if (text != "")
					return text
				if msg.Has("thinking") and Type(msg["thinking"]) = "String" {
					thinking := Trim(msg["thinking"])
					if (thinking != "") {
						try LoggerInfo("LLM.ollama", "Using thinking field as fallback ({1} chars).", StrLen(thinking))
						return (IsSet(LLM_Parser_StripThinking))
							? LLM_Parser_StripThinking(thinking) : thinking
					}
				}
			}
		}
	} catch as e {
		err_substr := SubStr(raw, 1, 200)
		try LoggerError("LLM.ollama", "JSON parse failed in ChatResponse: {1}. Raw (200c): {2}", e.Message, err_substr)
		return ""
	}
	; Legacy /api/generate bodies (tests + old logs).
	return LLM_ParseOllamaResponse(raw)
}

/**
 * Extracts the "response" field from a legacy Ollama /api/generate JSON reply.
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

	; Decode \uXXXX Unicode escape sequences
	out := ""
	pos := 1
	len := StrLen(s)
	while pos <= len {
		if (SubStr(s, pos, 2) == "\u") {
			hex := SubStr(s, pos + 2, 4)
			if RegExMatch(hex, "^[0-9A-Fa-f]{4}$") {
				out .= Chr(Integer("0x" . hex))
				pos += 6
				continue
			}
		}
		out .= SubStr(s, pos, 1)
		pos++
	}
	s := out

	return s
}
