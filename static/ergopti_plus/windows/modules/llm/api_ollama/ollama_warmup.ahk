; modules/llm/api_ollama/ollama_warmup.ahk

; ==============================================================================
; MODULE: Ollama API — Async Warmup
; DESCRIPTION:
; Warmup controller for the Ollama inference server. Fires a minimal 1-token
; generation at startup to load model weights into GPU memory, then retries
; with exponential backoff until the model is confirmed ready or LLM is disabled.
; ==============================================================================

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
	; Pause must silence every LLM background activity — no HTTP while suspended.
	; LLM_Ollama_WarmupRetryTick (the recurring retry tick) already guards
	; itself, but this function's FIRST dispatch is reachable directly from two
	; menu-click paths (LLM_Menu_SetModel, LLM_Menu_OnDepsReady) with no guard
	; anywhere else on that path, so clicking either while suspended fired a
	; real WinHTTP POST (F26). Guarding here protects both call sites at once.
	if A_IsSuspended
		return
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
		, _LLM_Ollama_IsReady, _LLM_Ollama_WarmupHttp, _LLM_Ollama_WarmupGeneration
	; Invalidate every in-flight warmup callback. The generation counter was
	; previously bumped ONLY on the start path, so the `gen != _LLM_Ollama_WarmupGeneration`
	; guard in _LLM_Ollama_OnWarmupDone could never invalidate anything a cancel
	; was meant to invalidate. That matters because the poll chain re-arms from an
	; anonymous closure nobody holds a handle to: bumping the generation here is
	; the ONLY way a cancel can stop a late response from setting _LLM_Ollama_IsReady
	; and resetting the backoff ramp behind a driver the user just paused.
	_LLM_Ollama_WarmupGeneration += 1
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



