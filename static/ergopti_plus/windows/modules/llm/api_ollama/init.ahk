; modules/llm/api_ollama/init.ahk

; ==============================================================================
; MODULE: Ollama API — Init & Constants
; DESCRIPTION:
; Entry point for the split Ollama API module. Declares all global constants,
; sentinel globals, and boot-time loader functions, then includes the four
; functional sub-files (HTTP client, streaming, warmup, payload helpers).
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================
; =====================================
; ======= 1/ Constants ================
; =====================================
; =====================================

; Ollama server port. The default lives in exactly ONE place —
; _shared/modules/llm/defaults.json (llm_ollama_port). The user can override it
; from the tray menu (persisted under [llm] ollama_port in config.toml) when they
; run the daemon on a non-standard port. Sentinel 0 — sourced at boot from
; LLM_Defaults by LLM_Ollama_LoadDefaults() (well before any request fires).
; LLM_OLLAMA_BASE_URL is DERIVED from it; change both via LLM_Ollama_SetPort.
global LLM_OLLAMA_PORT     := 0
global LLM_OLLAMA_BASE_URL := "http://localhost:" . LLM_OLLAMA_PORT
global _LLM_AuxGeneration := 1

LLM_AuxGeneration() {
	global _LLM_AuxGeneration
	return _LLM_AuxGeneration
}

LLM_AuxInvalidate(*) {
	global _LLM_AuxGeneration
	_LLM_AuxGeneration += 1
	return _LLM_AuxGeneration
}
; Keep-alive duration sent in /api/chat payloads — canonical value lives in
; _shared/modules/llm/defaults.json (llm_ollama_keep_alive). Sentinel "" —
; sourced at boot from LLM_Defaults by LLM_Ollama_LoadDefaults().
global LLM_OLLAMA_KEEP_ALIVE := ""
; Weak laptops running qwen3.5:0.8b on CPU can exceed 30 s per token batch.
; WinHTTP aborts the whole request when this fires — too low and the tooltip
; never appears despite Ollama still computing in the background.
global LLM_OLLAMA_TIMEOUT  := 180000  ; ms (3 min) — cold CPU inference headroom

; DELETE /api/delete round-trip ceiling for LLM_OllamaDeleteModel_Async.
; Mirrors the retired blocking version's WinHTTP receive timeout so observed
; behaviour is unchanged — only non-blocking now (F24).
global LLM_OLLAMA_DELETE_TIMEOUT_MS := 10000  ; ms

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
	global LLM_DEPS_POLL_TIMEOUT_MS
	LLM_OLLAMA_POLL_MS         := TimingsGet("llm", "poll_interval_ms")
	LLM_REMOTE_TIMEOUT_MS      := TimingsGet("llm", "request_timeout_ms")
	LLM_REMOTE_POLL_MS         := TimingsGet("llm", "poll_interval_ms")
	LLM_INSTALLED_CACHE_TTL_MS := TimingsGet("llm", "installed_cache_ttl_ms")
	LLM_DEPS_POLL_TIMEOUT_MS   := TimingsGet("llm", "dependency_bootstrap_timeout_ms")
}

; Source the Ollama port default from the shared registry (LLM_Defaults, loaded
; from _shared/modules/llm/defaults.json) at boot — keeps 11434 in exactly one
; place. Mirrors LLMApiLoadTimings; called right after it in infra/boot.ahk, after
; LLM_Defaults_Load(). The per-user override is applied later by LLM_Menu_Init.
LLM_Ollama_LoadDefaults() {
	global LLM_Defaults, LLM_OLLAMA_KEEP_ALIVE
	if IsSet(LLM_Defaults) and Type(LLM_Defaults) == "Map" {
		if LLM_Defaults.Has("llm_ollama_port")
			LLM_Ollama_SetPort(LLM_Defaults["llm_ollama_port"])
		if LLM_Defaults.Has("llm_ollama_keep_alive")
			LLM_OLLAMA_KEEP_ALIVE := LLM_Defaults["llm_ollama_keep_alive"]
	}
}

; Maximum number of in-flight async requests kept in the registry. Once we
; exceed this, the oldest pending request is abandoned (its callback becomes
; a no-op). 16 covers worst-case "user types a dozen letters back-to-back
; while the server is sluggish" without leaking handles indefinitely.
global LLM_OLLAMA_MAX_INFLIGHT := 16

; Registry of in-flight async requests, keyed by an internal id. Entries are
; created at exactly ONE site (_LLM_Ollama_DispatchAsync) and carry the curl
; child's pid, its two temp-file paths, the callbacks, the cancelled flag and
; the deadline — never a COM object, because the Ollama transport is curl. The
; cancelled flag flips to true when LLM_OllamaCancelAllAsync is called; the
; polling tick checks it and bails before invoking the user's callback.
global _LLM_Ollama_Async := Map()
global _LLM_Ollama_AsyncCounter := 0
; Latest-only queue when Ollama is busy — coalesces rapid re-fires instead of
; aborting in-flight WinHTTP (Abort made Ollama return ``content: ""``).
global _LLM_Ollama_Pending := ""
; In-flight curl streaming handles — cancelled by LLM_OllamaCancelAllAsync.
global _LLM_Ollama_ActiveStreams := []

; Orphan-sweep throttle. The sweep reaps temp files + empty dirs left by PRIOR
; (crashed) instances; it is never time-critical, so it runs at most once per
; _LLM_OLLAMA_ORPHAN_SWEEP_MS and ALWAYS off the synchronous dispatch path (see
; _LLM_Ollama_ScheduleOrphanSweep). Running it inline inside FirePrediction's
; Critical section, with an unbounded recursive %TEMP% walk, froze the keyboard
; for tens of seconds mid-prediction (llm-orphan-sweep-temp-recursion).
global _LLM_Ollama_LastSweepTick := 0
global _LLM_OLLAMA_ORPHAN_SWEEP_MS := 60000

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
	if port != LLM_OLLAMA_PORT
		LLM_AuxInvalidate("ollama_port")
	LLM_OLLAMA_PORT     := port
	LLM_OLLAMA_BASE_URL := "http://localhost:" . port
	return true
}




#Include ollama_payload.ahk
#Include ollama_http.ahk
#Include ollama_warmup.ahk
#Include ollama_streaming.ahk
