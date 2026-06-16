; modules/llm/prediction_engine.ahk

; ==============================================================================
; MODULE: LLM Prediction Engine
; DESCRIPTION:
; Debounce-based text prediction engine for Windows/AutoHotkey.
; Captures keystrokes via a shared buffer, waits for a configurable idle delay,
; then calls the Ollama backend to generate completions.
;
; FEATURES & RATIONALE:
; 1. Debounce: avoids hammering the LLM on every keystroke — waits for a pause.
; 2. Context window: takes the last N characters from the active buffer as seed.
; 3. Cancel-on-type: a new keystroke before the timer fires cancels the request.
; 4. Prediction cache: repeated identical context reuses the last result instantly.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; =======================================
; ======= 1/ Engine Configuration =======
; =======================================
; ======================================

; Runtime state — populated at first LLM_Engine_Init() call from LLM_Defaults
; (loaded by lib/llm_defaults.ahk at boot) so all values come from the shared
; defaults.json rather than being hardcoded here.
; Timer/cache keys are always initialised to their zero values regardless.
; String/numeric placeholder values — always overwritten by LLM_Engine_ApplySharedDefaults()
; which reads from LLM_Defaults (lib/llm_defaults.ahk → shared/llm/defaults.json).
global _LLM_Engine := Map(
	"enabled",                    false,
	"model",                      "",
	"profile_id",                 "basic",
	"user_profiles",              [],
	"n_predictions",              3,
	"min_words",                  3,
	"max_words",                  15,
	"debounce_ms",                500,
	"ctx_chars",                  500,
	"language",                   "fr",
	"temperature",                "0.10",
	"instant_on_word_end",        true,
	"after_hotstring",            true,
	"reset_on_nav",               true,
	"disable_url_bars",           false,
	"disable_password_fields",    false,
	"disabled_apps",              [],
	"show_info_bar",              true,
	"streaming",                  true,
	"show_all_at_once",           true,
	"pred_indent",                0,
	"auto_raise_temp",            true,
	"nav_modifiers",              "",
	"val_modifiers",              "alt",
	"timer_active",               false,
	"last_ctx",                   "",
	"last_result",                "",
	"last_results",               [],
	"last_request_tick",          0,
	; Monotonic id bumped on every LLM_Engine_FirePrediction call. Every
	; async variant captures the id at dispatch time and bails when its
	; callback finds the engine has moved on. Mirrors the HS
	; ``llm_request_counter`` pattern.
	"request_id",                 0,
	"backend",                    "ollama",
	; ── Remote API backend ──
	; Populated by the tray menu when the user selects "api" and configures
	; provider/url/token/model entries. ``api_entries`` is an array of
	; per-user records; ``api_entry_id`` is the selected one. Both are
	; persisted across reloads via the shared TOML config.
	"api_entries",                [],
	"api_entry_id",               ""
)

; Per-backend minimum interval (ms) between two prediction requests is now
; defined in ``static/ergopti_plus/shared/llm/inference.json`` and read via
; ``LLM_ApiCommon_GetRateLimitMs(backend)``. The shared JSON keeps the AHK
; and HS drivers in lockstep — changing a floor in one place applies to
; both backends with no risk of drift.

; Overwrite the defaults with values loaded from defaults.json at module load time.
; LLM_Defaults is populated by LLM_Defaults_Load() which runs before this file.
LLM_Engine_ApplySharedDefaults() {
	global _LLM_Engine, LLM_Defaults
	if !IsSet(LLM_Defaults)
		return

	static _num := ["n_predictions", "min_words", "max_words", "debounce_ms", "ctx_chars", "pred_indent"]
	static _bool := ["show_info_bar", "streaming", "show_all_at_once", "instant_on_word_end",
		"after_hotstring", "reset_on_nav", "auto_raise_temp", "disable_url_bars", "disable_password_fields"]
	static _str := ["profile_id", "model", "val_modifiers", "nav_modifiers", "temperature"]

	; Map shared-default key names → engine key names
	static _key_map := Map(
		"llm_active_profile",       "profile_id",
		"llm_model",                "model",
		"llm_num_predictions",      "n_predictions",
		"llm_min_words",            "min_words",
		"llm_max_words",            "max_words",
		"llm_debounce_ms",          "debounce_ms",
		"llm_context_length",       "ctx_chars",
		"llm_pred_indent",          "pred_indent",
		"llm_temperature",          "temperature",
		"llm_show_info_bar",        "show_info_bar",
		"llm_streaming",            "streaming",
		"llm_streaming_multi",      "show_all_at_once",
		"llm_instant_on_word_end",  "instant_on_word_end",
		"llm_after_hotstring",      "after_hotstring",
		"llm_reset_on_nav",         "reset_on_nav",
		"llm_auto_raise_temp",      "auto_raise_temp",
		"llm_disable_url_bars",     "disable_url_bars",
		"llm_disable_password_fields", "disable_password_fields",
		"llm_nav_modifiers",        "nav_modifiers",
		"llm_val_modifiers",        "val_modifiers"
	)

	for shared_key, engine_key in _key_map {
		if LLM_Defaults.Has(shared_key)
			_LLM_Engine[engine_key] := LLM_Defaults[shared_key]
	}
}
LLM_Engine_ApplySharedDefaults()





; ====================================
; ============================
; ======= 2/ Lifecycle =======
; ============================
; ====================================

/**
 * Initialises the prediction engine with user settings.
 * Must be called before any other LLM_Engine_* function.
 * @param {Map} opts - Map with optional keys: model, profile_id,
 *   n_predictions, min_words, max_words, debounce_ms, ctx_chars, language.
 */
LLM_Engine_Init(opts) {
	global _LLM_Engine
	_LLM_Engine["enabled"] := true

	static _keys := ["model", "profile_id", "backend", "n_predictions", "min_words", "max_words",
		"debounce_ms", "ctx_chars", "language", "temperature",
		"instant_on_word_end", "after_hotstring", "reset_on_nav",
		"disable_url_bars", "disable_password_fields",
		"show_info_bar", "streaming", "show_all_at_once",
		"pred_indent", "auto_raise_temp", "nav_modifiers", "val_modifiers",
		"inline_autotype", "api_entry_id"]

	for _, k in _keys
		if opts.Has(k)
			_LLM_Engine[k] := opts[k]

	; Arrays require explicit copy to avoid shared references
	if opts.Has("user_profiles") && (opts["user_profiles"] is Array)
		_LLM_Engine["user_profiles"] := opts["user_profiles"]
	if opts.Has("disabled_apps") && (opts["disabled_apps"] is Array)
		_LLM_Engine["disabled_apps"] := opts["disabled_apps"]
	if opts.Has("api_entries") && (opts["api_entries"] is Array)
		_LLM_Engine["api_entries"] := opts["api_entries"]
	; Per-app profile overrides Map(app_name -> profile_id). Copy by
	; reference is fine — the tray owns the canonical Map and the engine
	; only reads from it.
	if opts.Has("app_profile_overrides") and (opts["app_profile_overrides"] is Map)
		_LLM_Engine["app_profile_overrides"] := opts["app_profile_overrides"]
}

/**
 * Enables or disables the prediction engine at runtime.
 * @param {boolean} state - True to enable, false to disable.
 */
LLM_Engine_SetEnabled(state) {
	global _LLM_Engine
	_LLM_Engine["enabled"] := state
	if !state
		LLM_Engine_CancelTimer()
}





; ====================================
; ====================================
; ======= 3/ Keystroke Handler =======
; ====================================
; ====================================

/**
 * Called on every relevant keystroke. Resets the debounce timer.
 * Callers (llm_bridge.ahk) pass the current typed buffer.
 * @param {string} buffer - Full typed context up to the caret.
 */
LLM_Engine_OnKeystroke(buffer) {
	global _LLM_Engine
	if !_LLM_Engine["enabled"]
		return

	LLM_Engine_CancelTimer()

	; Arm debounce timer — closure captures the full buffer. PromptBuilder
	; (macOS parity) derives capped context + tail inside FirePrediction.
	_LLM_Engine["last_buffer"] := buffer
	_LLM_Engine["pending_timer"] := LLM_Engine_FirePrediction.Bind(buffer)
	SetTimer(_LLM_Engine["pending_timer"], -_LLM_Engine["debounce_ms"])
	_LLM_Engine["timer_active"] := true
}

/**
 * Arms the debounce timer with an optional delay override in seconds.
 * Mirrors HS prediction_engine.start_timer(delay_override). When omitted,
 * uses the configured debounce_ms. The buffer defaults to last_buffer,
 * then falls back to the LLM bridge rolling context.
 * @param {number} delaySec - Optional timer delay in seconds (0 = immediate).
 * @param {string} buffer - Optional context override captured at schedule time.
 */
LLM_Engine_StartTimer(delaySec := "", buffer := "") {
	global _LLM_Engine
	if !_LLM_Engine["enabled"]
		return

	if (buffer == "") {
		buffer := _LLM_Engine.Has("last_buffer") ? _LLM_Engine["last_buffer"] : ""
		if (buffer == "" and IsSet(_LLM_Bridge_Buffer))
			buffer := _LLM_Bridge_Buffer
	}
	if (buffer == "")
		return

	LLM_Engine_CancelTimer()
	_LLM_Engine["last_buffer"] := buffer
	delay_ms := (delaySec != "" and IsNumber(delaySec))
		? Max(1, Round(delaySec * 1000))
		: _LLM_Engine["debounce_ms"]
	_LLM_Engine["pending_timer"] := LLM_Engine_FirePrediction.Bind(buffer)
	SetTimer(_LLM_Engine["pending_timer"], -delay_ms)
	_LLM_Engine["timer_active"] := true
}

/**
 * Cancels any pending debounce timer.
 */
LLM_Engine_CancelTimer() {
	global _LLM_Engine
	; Always clear state so callers that pre-delete pending_timer still get a clean
	; result. The timer_active guard is skipped intentionally — an extra no-op
	; SetTimer(0) on an already-elapsed timer is harmless and avoids subtle
	; state divergence when the guard and the actual timer state disagree.
	if _LLM_Engine.Has("pending_timer") and IsObject(_LLM_Engine["pending_timer"])
		SetTimer(_LLM_Engine["pending_timer"], 0)
	_LLM_Engine["pending_timer"] := ""
	_LLM_Engine["timer_active"]  := false
}

/**
 * Returns true while a debounce timer, HTTP request, or curl stream is active.
 * Used by the pointer-dismiss watcher to avoid polling work when idle.
 */
LLM_Engine_IsBusy() {
	global _LLM_Engine, _LLM_Ollama_ActiveStreams, _LLM_Ollama_Async, _LLM_Remote_Async
	if (IsSet(_LLM_Engine) and _LLM_Engine.Has("timer_active") and _LLM_Engine["timer_active"])
		return true
	if (IsSet(_LLM_Ollama_ActiveStreams) and _LLM_Ollama_ActiveStreams.Length > 0)
		return true
	if (IsSet(_LLM_Ollama_Async)) {
		for , entry in _LLM_Ollama_Async {
			if (IsObject(entry) and (!entry.Has("cancelled") or !entry["cancelled"]))
				return true
		}
	}
	if (IsSet(_LLM_Remote_Async)) {
		for , entry in _LLM_Remote_Async {
			if (IsObject(entry) and (!entry.Has("cancelled") or !entry["cancelled"]))
				return true
		}
	}
	return false
}

/**
 * Stops debounced and in-flight generation without hiding the tooltip.
 * Mirrors HS prediction_engine.stop_timer() + cancel_streaming().
 */
LLM_Engine_StopGeneration() {
	global _LLM_Engine
	LLM_Engine_CancelTimer()
	if IsSet(_LLM_Engine) {
		_LLM_Engine["request_id"] := (_LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0) + 1
		; Drop the prediction cache on every explicit stop (navigation reset,
		; pause/suspend). The cache is keyed only on context-string equality, so
		; without this a context the user returns to — or rebuilds after a
		; pause/resume — would instantly replay a prediction they already
		; dismissed, surfacing as a "ghost" suggestion. The next fire on that
		; context must take the network path, not the cache branch.
		_LLM_Engine["last_ctx"]     := ""
		_LLM_Engine["last_results"] := []
		_LLM_Engine["last_result"]  := ""
	}
	try LLM_OllamaCancelStreams()
	try LLM_OllamaCancelAllAsync()
	try LLM_RemoteCancelAllAsync()
}





; ========================================
; =======================================
; ======= 4/ Prediction Execution =======
; =======================================
; ========================================

; Per-prediction token slack added to every backend call. Mirrors the macOS
; api_*.lua ``+ num_predictions * 5`` overhead so the two drivers size the output
; budget identically.
global LLM_PRED_TOKEN_OVERHEAD := 5

/**
 * Per-call output-token budget for a backend request, given the shared
 * PromptBuilder per-prediction budget and how many predictions THIS call yields
 * (1 for a sequential-variant call, N for a single batch call that returns all
 * N predictions in one response). Mirrors the macOS fetch_batch formula
 * ``max_predict * num_predictions + num_predictions * 5`` so the AHK batch path
 * is no longer under-budgeted (it previously sent the single-prediction cap for
 * an N-prediction response, truncating it).
 * @param {integer} maxTokens     Shared PromptBuilder per-prediction budget.
 * @param {integer} predsPerCall  Predictions produced by this one call (>= 1).
 * @returns {integer} The num_predict / max_tokens cap to send.
 */
_LLM_Engine_CallTokenBudget(maxTokens, predsPerCall) {
	global LLM_PRED_TOKEN_OVERHEAD
	n := (predsPerCall is Integer and predsPerCall >= 1) ? predsPerCall : 1
	return maxTokens * n + n * LLM_PRED_TOKEN_OVERHEAD
}

/**
 * Fires the actual LLM call after the debounce period expires.
 * Skips the call if context is identical to the last result's context.
 * @param {string} buffer - Full typed buffer captured at debounce arm time.
 */
LLM_Engine_FirePrediction(buffer) {
	global _LLM_Engine
	_LLM_Engine["timer_active"] := false

	; A debounce timer armed just before the user paused must not fire an HTTP
	; request or paint a prediction — « pause = tout éteint ».
	if A_IsSuspended
		return

	if !_LLM_Engine["enabled"] || buffer == ""
		return

	; ── Bump the request id ──
	; Every async callback closes over the id it saw at dispatch time. If
	; the engine's current id has moved on, the callback bails — mirrors
	; the HS llm_request_counter pattern in modules/llm/prediction_engine.lua.
	;
	; Moved to the top so even deferred attempts (warmup, rate limit) or
	; short-context skips bump the id and invalidate stale in-flight results
	; from previous contexts.
	_LLM_Engine["request_id"] := (_LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0) + 1
	this_request_id := _LLM_Engine["request_id"]

	backend_now := _LLM_Engine.Has("backend") ? _LLM_Engine["backend"] : "ollama"
	if (backend_now = "ollama" and IsSet(LLM_OllamaAllowInference) and !LLM_OllamaAllowInference()) {
		static _LLM_LastDeferLogTick := 0
		if (A_TickCount - _LLM_LastDeferLogTick > 5000) {
			_LLM_LastDeferLogTick := A_TickCount
			try LoggerInfo("LLM", "Ollama warmup in progress — prediction deferred (retry shortly).")
		}
		if IsSet(LLM_OllamaScheduleWarmupRetry)
			LLM_OllamaScheduleWarmupRetry(_LLM_Engine["model"])
		retry_ms := Max(500, Min(_LLM_Engine["debounce_ms"], 2000))
		_LLM_Engine["pending_timer"] := LLM_Engine_FirePrediction.Bind(buffer)
		SetTimer(_LLM_Engine["pending_timer"], -retry_ms)
		_LLM_Engine["timer_active"] := true
		return
	}
	if (backend_now = "ollama" and IsSet(LLM_OllamaIsReady) and !LLM_OllamaIsReady()
			and IsSet(LLM_OllamaAllowInference) and LLM_OllamaAllowInference()) {
		static _LLM_GraceLogged := false
		if !_LLM_GraceLogged {
			_LLM_GraceLogged := true
			try LoggerInfo("LLM", "Allowing prediction while model finishes loading (warmup grace).")
		}
	}

	pb := PromptBuilder()
	pb_cfg := Map(
		"max_words",       _LLM_Engine["max_words"],
		"min_words",       _LLM_Engine["min_words"],
		"num_predictions", _LLM_Engine["n_predictions"],
		"temperature",     _LLM_Engine["temperature"] + 0.0,
		"auto_raise_temp", _LLM_Engine["auto_raise_temp"],
		"language",        _LLM_Engine["language"]
	)
	params := pb.Build(buffer, pb_cfg)
	ctx := params["context"]
	tail := params["context_tail"]
	req_temp := params["temperature"]
	; Per-prediction output-token budget computed once by the shared PromptBuilder
	; (max(15, max_words*6+10), default 150) — the single cross-driver source.
	; Threaded to every backend below so AHK no longer re-derives its own cap
	; (Ollama's mw*4 / remote's hardcoded 256), matching the macOS driver.
	max_tokens := Integer(params["max_tokens"])

	if (tail == "" or StrLen(tail) < 2) {
		try LoggerInfo("LLM", "Context too short — prediction skipped.")
		return
	}

	try {
		preview := SubStr(tail, -40)
		LoggerInfo("LLM", "Prediction request queued — tail: «{1}».", preview)
	} catch {
	}

	; Cache hit (exact match): re-display last result without an API call.
	; The cache is an array of slot strings so the multi-prediction reveal
	; animation replays exactly as it did the first time.
	;
	; Bump request_id BEFORE rendering so any callback from a previous fire
	; that's still in flight will bail (its ``state["request_id"] != current``
	; check kicks in). Without this, a late async response from the previous
	; ctx could land AFTER the cache hit rendered and clobber the tooltip.
	if (ctx == _LLM_Engine["last_ctx"] && _LLM_Engine.Has("last_results")
			and Type(_LLM_Engine["last_results"]) == "Array"
			and _LLM_Engine["last_results"].Length > 0) {
		try LLM_OllamaCancelStreams()
		LLM_Engine_OnResults(_LLM_Engine["last_results"], ctx, 1, true)
		return
	}

	; Cache hit (prefix match): the user has typed PAST the last cached
	; context — e.g. cache was for "intelligen" and the user is now
	; at "intelligence ". If the cached top prediction STARTS with
	; the user's typed delta, the rest of the prediction is still valid
	; and we can re-display it (sliced to whatever remains). Mirrors the
	; "soft cache" some IDE completions use: avoid a request when the
	; previous answer was correct, just consumed partially.
	if (_LLM_Engine.Has("last_ctx") and _LLM_Engine["last_ctx"] != ""
			and _LLM_Engine.Has("last_results")
			and Type(_LLM_Engine["last_results"]) == "Array"
			and _LLM_Engine["last_results"].Length > 0
			and StrLen(ctx) > StrLen(_LLM_Engine["last_ctx"])
			and StrCompare(SubStr(ctx, 1, StrLen(_LLM_Engine["last_ctx"])), _LLM_Engine["last_ctx"], true) == 0) {
		typed_delta := SubStr(ctx, StrLen(_LLM_Engine["last_ctx"]) + 1)
		; Slice each cached slot by removing the prefix the user has
		; already typed. Only slots whose start equals typed_delta
		; contribute; the others are dropped (they don't match what
		; the user is now committed to typing). Case-SENSITIVE prefix
		; comparison so "Paris" doesn't get mis-matched with "paris".
		sliced := []
		for _, s in _LLM_Engine["last_results"] {
			if (StrLen(s) > StrLen(typed_delta)
					and StrCompare(SubStr(s, 1, StrLen(typed_delta)), typed_delta, true) == 0) {
				sliced.Push(SubStr(s, StrLen(typed_delta) + 1))
			}
		}
		if (sliced.Length > 0) {
			; Same race fix as the exact-match cache branch above: bump
			; request_id so late callbacks bail; WinHTTP stays in flight.
			try LLM_OllamaCancelStreams()
			LLM_Engine_OnResults(sliced, ctx, 1, true)
			return
		}
	}

	; ── Backend-aware request floor ──
	; Even when the user has set a 50 ms debounce, fire no more than one
	; request per ``min_interval`` ms for the active backend (paid APIs need
	; this hard cap; local backends benefit from it for energy). When the
	; floor blocks, re-arm the debounce timer for the remaining gap so the
	; next attempt fires at exactly the right moment instead of being lost.
	backend := _LLM_Engine.Has("backend") ? _LLM_Engine["backend"] : "ollama"
	min_interval := LLM_ApiCommon_GetRateLimitMs(backend)
	now := A_TickCount
	last := _LLM_Engine.Has("last_request_tick") ? _LLM_Engine["last_request_tick"] : 0
	if (last > 0 and (now - last) < min_interval) {
		remaining := min_interval - (now - last)
		; Same reasoning as LLM_Engine_OnKeystroke: keep a reference to the
		; closure so the next CancelTimer call can actually cancel it.
		_LLM_Engine["pending_timer"] := LLM_Engine_FirePrediction.Bind(buffer)
		SetTimer(_LLM_Engine["pending_timer"], -remaining)
		_LLM_Engine["timer_active"] := true
		return
	}

	; ── Cancel stale curl streams only (macOS parity) ──
	; WinHTTP is single-flight via ``_LLM_Ollama_Pending`` in api_ollama.ahk.
	; ``Abort()`` on stacked /api/chat calls made Ollama return ``content: ""``.
	global _LLM_Ollama_ActiveStreams
	if (IsSet(_LLM_Ollama_ActiveStreams) and _LLM_Ollama_ActiveStreams.Length > 0) {
		try LoggerInfo("LLM", "Cancelling {1} prior Ollama stream(s) — context changed.", _LLM_Ollama_ActiveStreams.Length)
	}
	try LLM_OllamaCancelStreams()

	try LLM_Tooltip_SetChainStart()

	; Resolve profile and build the system prompt. If the user has
	; configured a per-app override for the focused window, that wins
	; over the global profile id — same context, different prompt.
	; Falls back to the global profile when the active app has no
	; override or the override id is unknown.
	effective_profile_id := _LLM_Engine_ResolveProfileIdForApp(_LLM_Engine["profile_id"])
	profile       := LLM_GetActiveProfile(effective_profile_id)
	n_predictions := Max(1, Integer(_LLM_Engine["n_predictions"]))
	; Inline auto-type mode forces a single variant: typing N
	; alternatives sequentially into the active document would produce
	; chaos. The user-facing n_predictions setting is left untouched so
	; flipping inline mode back off restores the original count.
	if (_LLM_Engine.Has("inline_autotype") and _LLM_Engine["inline_autotype"])
		n_predictions := 1
	system_prompt := LLM_ResolveSystemPrompt(
		profile,
		n_predictions,
		_LLM_Engine["min_words"],
		_LLM_Engine["max_words"],
		_LLM_Engine["language"]
	)
	is_batch_profile := (profile is Map and profile.Has("batch") and profile["batch"] == true)

	; A batch call returns all N predictions in one response; a sequential-variant
	; call returns one. Size the per-call token budget accordingly (macOS parity).
	preds_per_call := (n_predictions > 1 and is_batch_profile) ? n_predictions : 1
	call_tokens := _LLM_Engine_CallTokenBudget(max_tokens, preds_per_call)

	_LLM_Engine["last_request_tick"] := A_TickCount

	; Resolve the model + the per-backend async dispatch closure exactly
	; once so the variant loop doesn't repeat the backend branch on every
	; request. Two flavours per backend: a non-streaming one (the default)
	; and a streaming one (Ollama only; remote providers' streaming APIs
	; have a different shape that the engine doesn't speak yet — same
	; constraint as HS where the remote backend stays non-stream).
	model_tag := ""
	log_model := ""
	dispatch_fn := ""
	dispatch_stream_fn := ""
	streaming_enabled := _LLM_Engine.Has("streaming") and _LLM_Engine["streaming"]
	; Windows curl streaming is not reliable yet (logs: empty stdout / No stdout
	; file). WinHTTP async matches macOS behaviour and completes on this driver.
	if (backend == "ollama")
		streaming_enabled := false
	if (backend == "api") {
		entry := _LLM_Engine_GetActiveApiEntry()
		if (entry == "")
			return
		model_tag := (entry is Map and entry.Has("Model")) ? entry["Model"] : (entry.HasOwnProp("Model") ? entry.Model : "")
		log_model := model_tag
		dispatch_fn := (temp, on_succ, on_fail) =>
			LLM_RemoteGenerate_Async(entry, system_prompt, ctx, temp, on_succ, on_fail, tail, call_tokens)
		; No remote-streaming dispatcher — disable streaming for the API
		; backend so the engine falls back to the async non-streaming path.
		streaming_enabled := false
	} else {
		model_tag := LLM_ResolveOllamaTag(_LLM_Engine["model"])
		log_model := model_tag
		; Forward the per-profile stop sequences when the profile carries
		; them. Power-user profiles use this to clip output at custom
		; markers (e.g. ``` for a code profile, "\n\n" for a
		; single-paragraph profile). Empty / missing → Ollama falls back
		; to its built-in stops.
		stop_seqs := (profile is Map and profile.Has("stop_sequences") and profile["stop_sequences"] is Array)
			? profile["stop_sequences"] : ""
		is_batch := (profile is Map and profile.Has("batch") and profile["batch"] == true)
		dispatch_fn := (temp, on_succ, on_fail) =>
			LLM_OllamaGenerate_Async(model_tag, system_prompt, ctx, temp, on_succ, on_fail, stop_seqs, call_tokens, is_batch, tail)
		dispatch_stream_fn := (temp, on_partial, on_succ, on_fail) =>
			LLM_OllamaGenerate_Streaming(model_tag, system_prompt, ctx, temp, on_partial, on_succ, on_fail, stop_seqs, call_tokens, is_batch, tail)
	}

	; ── Batch vs sequential dispatch ──
	; A profile with batch=true asks the model to return all N predictions
	; in a single response, separated by ===. Mirrors the HS fetch_batch
	; path. Falls back to sequential when batch is off or n=1.
	if (n_predictions > 1 and is_batch_profile) {
		state := Map(
			"ctx",           ctx,
			"ctx_tail",      tail,
			"min_words",     _LLM_Engine["min_words"],
			"max_words",     _LLM_Engine["max_words"],
			"is_batch",      true,
			"request_id",    this_request_id,
			"backend",       backend,
			"model",         log_model,
			"system_prompt", system_prompt,
			"requested",     n_predictions,
			"base_temp",     req_temp,
			"dispatch_fn",   dispatch_fn,
			"request_start", A_TickCount
		)
		_LLM_Engine_ShowLoadingTooltip()
		_LLM_Engine_DispatchBatch(state)
		return
	}

	; ── Multi-variant sequential dispatch ──
	; Mirrors api_ollama.lua fetch_sequential: one variant at a time so
	; back-to-back requests don't trip Ollama's small-model concurrency
	; limit. Each variant uses a diversity-temperature step on top of the
	; user's base so the predictions don't all collapse to the same answer.
	; Retry up to MAX_MULT × n_predictions attempts total when a variant
	; fails. Dedup against the already-collected slots so identical
	; completions don't fill multiple slots.
	state := Map(
		"ctx",               ctx,
		"ctx_tail",          tail,
		"min_words",         _LLM_Engine["min_words"],
		"max_words",         _LLM_Engine["max_words"],
		"is_batch",          is_batch_profile,
		"request_id",        this_request_id,
		"backend",           backend,
		"model",             log_model,
		"system_prompt",     system_prompt,
		"slots",             [],
		"requested",         n_predictions,
		"attempt_index",     1,
		"max_attempts",      _LLM_Engine_MaxAttempts(n_predictions),
		"base_temp",         req_temp,
		"dedup_stats",       LLM_ApiCommon_NewDedupStats(),
		"dispatch_fn",       dispatch_fn,
		"dispatch_stream_fn",dispatch_stream_fn,
		"streaming",         streaming_enabled,
		; Wallclock at request start so the keylogger event can include the
		; round-trip latency (matches the HS log_llm shape's ``elapsed_ms``
		; field). Read at finalize time as ``A_TickCount - request_start``.
		"request_start",     A_TickCount
	)
	_LLM_Engine_ShowLoadingTooltip()
	_LLM_Engine_DispatchVariant(state)
}

; Push footer/display state into the tooltip module before every paint.
_LLM_Engine_ApplyTooltipDisplayOpts(slotCount := 1) {
	global _LLM_Engine
	profile_label := ""
	try {
		prof := LLM_GetActiveProfile(
			_LLM_Engine_ResolveProfileIdForApp(_LLM_Engine["profile_id"]),
			_LLM_Engine.Has("user_profiles") ? _LLM_Engine["user_profiles"] : [])
		if (prof is Map and prof.Has("label"))
			profile_label := prof["label"]
	}
	info_model := ""
	if (_LLM_Engine.Has("show_info_bar") and _LLM_Engine["show_info_bar"])
		info_model := _LLM_Engine_BuildInfoBarText(
			_LLM_Engine.Has("model") ? _LLM_Engine["model"] : "",
			_LLM_Engine_ResolveBackendLabel(),
			profile_label)
	LLM_Tooltip_SetDisplayOpts(Map(
		"show_info_bar", !!(_LLM_Engine.Has("show_info_bar") and _LLM_Engine["show_info_bar"]),
		"info_model", info_model,
		"slot_count", Max(1, Integer(slotCount)),
		"nav_modifiers", _LLM_Engine.Has("nav_modifiers") ? _LLM_Engine["nav_modifiers"] : "",
		"pred_indent", _LLM_Engine.Has("pred_indent") ? Integer(_LLM_Engine["pred_indent"]) : 0,
		"val_modifiers", _LLM_Engine.Has("val_modifiers") ? _LLM_Engine["val_modifiers"] : "",
	))
}

; Purple loading tooltip — macOS ``tooltip.show_loading`` parity. Fires once per
; debounced request after the inactivity delay, before HTTP dispatch.
_LLM_Engine_ShowLoadingTooltip() {
	global _LLM_Engine
	if (_LLM_Engine.Has("inline_autotype") and _LLM_Engine["inline_autotype"])
		return
	; macOS parity (prediction_engine.lua:590 — "only show the spinner when the
	; screen is empty"). If a real prediction is already on screen, KEEP it while
	; this new request generates in the background; the fresh prediction swaps in
	; via LLM_Tooltip_Show when it lands. Replacing a shown prediction with the
	; violet "Génération en cours…" spinner on every follow-up keystroke is the
	; churn that made suggestions feel like they "n'ont pas le temps d'apparaître":
	; the prediction flashed, then the next keystroke's request blanked it back to
	; a spinner. Loading-over-loading still repaints (IsLoading → not a prediction).
	if (IsSet(LLM_Tooltip_IsVisible) and LLM_Tooltip_IsVisible()
			and IsSet(LLM_Tooltip_IsLoading) and !LLM_Tooltip_IsLoading())
		return
	_LLM_Engine_ApplyTooltipDisplayOpts(1)
	try LLM_Tooltip_ShowLoading()
}

; Single-shot batch dispatch: one async request, the model returns N
; predictions separated by ``===`` (the convention HS's Parser.split_blocks
; also expects), and we split / dedup the response into slots.
_LLM_Engine_DispatchBatch(state) {
	; Keep the compact violet loading tooltip until the batch response lands.
	; macOS does not paint placeholder rows here — show_loading stays up.

	state_ref := state
	dispatch_fn := state["dispatch_fn"]
	; The success callback receives ``(text, meta := "")`` so the API path's
	; per-request token usage / cost block lands in the state map. Ollama's
	; async callback only passes ``text`` — extra positional args are dropped
	; at the call boundary, so the same signature works for both backends.
	dispatch_fn.Call(state["base_temp"],
		(text, meta := "") => _LLM_Engine_OnBatchSuccess(state_ref, text, meta),
		() => _LLM_Engine_OnBatchFail(state_ref))
}

_LLM_Engine_OnBatchSuccess(state, text, meta := "") {
	global _LLM_Engine
	current_id := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	if (state["request_id"] != current_id)
		return
	; Capture per-request token usage when the backend provided it. Same
	; structure as the sequential path so the finalize step can emit a
	; unified keylogger event regardless of dispatch strategy.
	if (meta is Map) {
		state["prompt_tokens"]     := (state.Has("prompt_tokens")     ? state["prompt_tokens"]     : 0) + (meta.Has("prompt_tokens")     ? meta["prompt_tokens"]     : 0)
		state["completion_tokens"] := (state.Has("completion_tokens") ? state["completion_tokens"] : 0) + (meta.Has("completion_tokens") ? meta["completion_tokens"] : 0)
		state["total_tokens"]      := (state.Has("total_tokens")      ? state["total_tokens"]      : 0) + (meta.Has("total_tokens")      ? meta["total_tokens"]      : 0)
		state["est_cost_usd"]      := (state.Has("est_cost_usd")      ? state["est_cost_usd"]      : 0.0) + (meta.Has("est_cost_usd")    ? meta["est_cost_usd"]      : 0.0)
	}
	slots := _LLM_Engine_ParseSlots(text, state)
	state["slots"]       := slots
	state["dedup_stats"] := LLM_ApiCommon_NewDedupStats()
	_LLM_Engine_FinalizeRequest(state)
}

_LLM_Engine_OnBatchFail(state) {
	; Batch failures don't retry — the cost of a re-request is much higher
	; than for a single variant, and the user has already paid the latency
	; of the first attempt. Let the tooltip fade via its auto-dismiss
	; timer instead.
	global _LLM_Engine
	current_id := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	if (state["request_id"] != current_id)
		return
	; Keep slots empty + finalize so any subsequent cache hit is consistent.
	state["slots"]       := []
	state["dedup_stats"] := LLM_ApiCommon_NewDedupStats()
	_LLM_Engine_FinalizeRequest(state)
}

; Split a batch response on the ``===`` separator. Trims whitespace per
; block and drops empties. Mirrors HS's Parser.split_blocks behaviour
; (modules/llm/parser.lua) so the same model output yields the same
; predictions on both drivers.
_LLM_Engine_SplitBatchBlocks(raw) {
	blocks := []
	if (raw == "")
		return blocks
	; Append a trailing separator so the last block is captured by the
	; while loop without a special case.
	work := raw . "==="
	pos := 1
	; ``s)`` flag is critical here: by default ``.`` does NOT match newlines
	; in PCRE, so a multi-line prediction block (which is the normal case for
	; the batch profile — TAIL_CORRECTED + NEXT_WORDS on separate lines)
	; would never match and the whole response would fall through to the
	; ``blocks.Length == 0`` fallback, packed as a single block.
	while RegExMatch(work, "s)(.*?)===", &m, pos) {
		piece := Trim(m[1], " `t`r`n")
		if (piece != "")
			blocks.Push(piece)
		pos := m.Pos + m.Len
	}
	if (blocks.Length == 0 and raw != "")
		blocks.Push(Trim(raw, " `t`r`n"))
	return blocks
}

; Pumps one variant of the sequential loop. Recursively schedules itself
; from the success / fail callbacks until either ``requested`` slots are
; filled or ``max_attempts`` is exhausted.
_LLM_Engine_DispatchVariant(state) {
	global _LLM_Engine
	; Bail if a newer request has been fired since this variant was queued —
	; the closure may have been pending on the SetTimer queue and now lands
	; into stale context.
	current_id := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	if (state["request_id"] != current_id)
		return

	; Done? Either we got enough predictions or we ran out of attempts.
	if (state["slots"].Length >= state["requested"]
			or state["attempt_index"] > state["max_attempts"]) {
		_LLM_Engine_FinalizeRequest(state)
		return
	}

	variant_idx := state["attempt_index"]
	state["attempt_index"] := variant_idx + 1
	temp := LLM_ApiCommon_GetDiversityTemp(state["base_temp"], variant_idx)

	; Reveal animation once earlier variants already filled a slot — keep the
	; violet loading tooltip while the in-flight variant is still empty
	; (macOS show_loading parity). Streaming / on_success paint real text.
	preview_slots := []
	for _, s in state["slots"]
		preview_slots.Push(s)
	while (preview_slots.Length < variant_idx)
		preview_slots.Push(LLM_TOOLTIP_PLACEHOLDER)
	has_real_slot := false
	for _, s in preview_slots {
		if (s != "" and s != LLM_TOOLTIP_PLACEHOLDER) {
			has_real_slot := true
			break
		}
	}
	if has_real_slot {
		active_idx := 1
		for i, s in preview_slots {
			if (s != "" and s != LLM_TOOLTIP_PLACEHOLDER) {
				active_idx := i
				break
			}
		}
		LLM_Engine_OnResults(preview_slots, state["ctx"], active_idx, false)
	}

	state_ref := state
	; Streaming path: when enabled and the backend exposes a streaming
	; dispatcher, on_partial fires per token so the tooltip updates the
	; in-flight slot live. on_success closes the slot with the final
	; text just like the non-streaming path.
	if (state["streaming"] and state["dispatch_stream_fn"] != "") {
		this_slot_idx := state["slots"].Length + 1
		stream_fn := state["dispatch_stream_fn"]
		; ``(text, meta := "")`` signature matches both backends. The remote
		; path always passes meta with token usage; the Ollama path passes
		; only ``text`` and the default kicks in.
		stream_fn.Call(temp,
			(partial) => _LLM_Engine_OnStreamPartial(state_ref, this_slot_idx, partial),
			(text, meta := "") => _LLM_Engine_OnVariantSuccess(state_ref, text, meta),
			() => _LLM_Engine_OnVariantFail(state_ref))
		return
	}

	dispatch_fn := state["dispatch_fn"]
	; Same signature as the streaming branch — forward ``meta`` so the
	; finalize step can record token usage / cost. Without ``meta`` here
	; the API path silently zeroed those metrics in the keylogger event.
	dispatch_fn.Call(temp,
		(text, meta := "") => _LLM_Engine_OnVariantSuccess(state_ref, text, meta),
		() => _LLM_Engine_OnVariantFail(state_ref))
}

; Per-token streaming callback: paints the partial text into its slot in
; real time. The slot index is captured at dispatch time so multiple
; in-flight variants don't trip over each other. Same dedup is NOT applied
; here — we run the full text through dedup on on_success, where the
; comparison is meaningful.
_LLM_Engine_OnStreamPartial(state, slot_idx, partial) {
	global _LLM_Engine
	current_id := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	if (state["request_id"] != current_id)
		return
	preview := []
	for _, s in state["slots"]
		preview.Push(s)
	while (preview.Length < slot_idx - 1)
		preview.Push("")
	; Strip thinking tags during streaming; full parser runs on on_success.
	display := LLM_Parser_StripThinking(partial)
	preview.Push(display)
	; Active = the slot currently streaming, so Tab during streaming still
	; produces something sensible.
	LLM_Engine_OnResults(preview, state["ctx"], slot_idx, false)
}

_LLM_Engine_OnVariantSuccess(state, text, meta := "") {
	global _LLM_Engine
	current_id := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	if (state["request_id"] != current_id) {
		try LoggerInfo("LLM", "Variant success ignored — superseded by newer typing.")
		return
	}
	; Accumulate token usage / cost across variants. The Ollama path does
	; not pass meta (its sync /api/generate response carries different
	; fields we don't bill on); the API path does. Missing values stay 0.
	if (meta is Map) {
		state["prompt_tokens"]     := (state.Has("prompt_tokens")     ? state["prompt_tokens"]     : 0) + (meta.Has("prompt_tokens")     ? meta["prompt_tokens"]     : 0)
		state["completion_tokens"] := (state.Has("completion_tokens") ? state["completion_tokens"] : 0) + (meta.Has("completion_tokens") ? meta["completion_tokens"] : 0)
		state["total_tokens"]      := (state.Has("total_tokens")      ? state["total_tokens"]      : 0) + (meta.Has("total_tokens")      ? meta["total_tokens"]      : 0)
		state["est_cost_usd"]      := (state.Has("est_cost_usd")      ? state["est_cost_usd"]      : 0.0) + (meta.Has("est_cost_usd")    ? meta["est_cost_usd"]      : 0.0)
	}
	; Dedup against existing slots; skip empties. Comparison is case-SENSITIVE
	; via StrCompare(.., true): AHK v2's ``==`` operator is case-INSENSITIVE
	; for strings, so without StrCompare two predictions that differ only by
	; case ("Paris" vs "paris") would collapse into one slot.
	inserted := false
	parsed := _LLM_Engine_ParseSlots(text, state)
	if (parsed.Length > 0) {
	text := parsed[1]
	dup := false
	for _, s in state["slots"] {
		if (StrCompare(s, text, true) == 0) {
			dup := true
			break
		}
	}
		if !dup {
			state["slots"].Push(text)
			inserted := true
		}
		state["dedup_stats"]["candidates"] += 1
		if dup
			state["dedup_stats"]["duplicates"] += 1
		else
			state["dedup_stats"]["kept"] += 1
	}
	; Paint the current accumulated slots so the user sees the new
	; prediction land immediately, even if more variants are still in
	; flight. Active = the first un-filled slot OR the last filled when
	; full so Tab always lands on a real prediction.
	active_idx := state["slots"].Length > 0 ? state["slots"].Length : 1
	if (state["slots"].Length >= state["requested"]) {
		active_idx := 1
	}
	LLM_Engine_OnResults(state["slots"], state["ctx"], active_idx, false)
	_LLM_Engine_DispatchVariant(state)
}

_LLM_Engine_OnVariantFail(state) {
	global _LLM_Engine
	current_id := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	if (state["request_id"] != current_id) {
		try LoggerInfo("LLM", "Variant failure ignored — superseded by newer typing.")
		return
	}
	; Curl streaming is best-effort on Windows — fall back to WinHTTP async for
	; the remaining attempts in this request when a stream dies empty.
	if (state.Has("streaming") and state["streaming"]) {
		state["streaming"] := false
		try LoggerInfo("LLM", "Streaming failed — retrying via WinHTTP async.")
	}
	try LoggerWarn("LLM", "Variant {1}/{2} failed (model {3}).",
		state["attempt_index"] - 1, state["max_attempts"], state["model"])
	; The variant didn't yield a usable result. ``attempt_index`` already
	; advanced for the next attempt; the retry budget (max_attempts) caps
	; how often we keep trying. No special retry-temperature step here —
	; the diversity step bumps the temperature on the next variant anyway,
	; which is the same end effect.
	_LLM_Engine_DispatchVariant(state)
}

_LLM_Engine_FinalizeRequest(state) {
	global _LLM_Engine
	current_id := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	if (state["request_id"] != current_id)
		return
	if (state["slots"].Length == 0) {
		; Every variant failed — log a single ``llm_generation_failed`` so
		; the audit trail captures the failure instead of silently
		; dropping. The tooltip auto-dismisses via its own timer.
		try LoggerWarn("LLM", "All variants failed for model {1} — no tooltip rendered.", state["model"])
		try LLM_Tooltip_Hide()
		try {
			app_name := ""
			try app_name := WIGetFocused()["appId"]
			KL_LogLlmFailed(Map(
				"app",            app_name,
				"context",        state["ctx"],
				; Same ``tag`` shape as the HS log_llm_failed event so a
				; unified log tail can regex-filter both drivers identically.
				"tag",            "<llm_failed/>",
				"backend",        state["backend"],
				"model",          state["model"],
				"system_prompt",  state["system_prompt"],
				"user_prompt",    state["ctx"],
				"failure_reason", "all_variants_failed"
			))
		}
		return
	}
	_LLM_Engine["last_ctx"]     := state["ctx"]
	_LLM_Engine["last_results"] := state["slots"]
	; Keep ``last_result`` (singular) for the legacy cache hit path so any
	; external code still reading that field keeps working.
	_LLM_Engine["last_result"]  := state["slots"][1]

	try LLM_ApiCommon_LogSummary("sequential", state["requested"], state["dedup_stats"], state["slots"].Length)
	try LoggerInfo("LLM", "Prediction received — {1} suggestion(s).", state["slots"].Length)
	global _LLM_Ollama_IsReady
	_LLM_Ollama_IsReady := true

	; Keylogger event — same shape as HS (modules/keylogger/init.lua /
	; M.log_llm) so a tail of the unified log reads identically across
	; drivers. The ``predictions`` field carries the full slot array now
	; rather than a single string. Token usage / cost / latency are
	; populated by the backend when the provider exposes them in its
	; response (OpenAI's ``usage`` block, Anthropic's ``usage`` block).
	try {
		app_name := ""
		try app_name := WIGetFocused()["appId"]
		evt := Map(
			"app",           app_name,
			"context",       state["ctx"],
			"predictions",   state["slots"],
			; ``tag`` mirrors the HS log_llm shape (modules/keylogger/init.lua
			; M.log_llm) — a tail of the unified log can filter generations
			; with a single regex regardless of which driver produced them.
			"tag",           "<llm_generated></llm_generated>",
			"backend",       state["backend"],
			"model",         state["model"],
			"system_prompt", state["system_prompt"],
			"user_prompt",   state["ctx"]
		)
		; ``elapsed_ms`` is the round-trip latency from variant 1 dispatch to
		; the final render. Tracked via the ``request_start`` field stamped
		; into ``state`` at FirePrediction time so streaming + sequential +
		; batch all read the same wallclock.
		if state.Has("request_start") and state["request_start"] > 0
			evt["elapsed_ms"] := A_TickCount - state["request_start"]
		if state.Has("prompt_tokens")     and state["prompt_tokens"]     > 0
			evt["prompt_tokens"] := state["prompt_tokens"]
		if state.Has("completion_tokens") and state["completion_tokens"] > 0
			evt["completion_tokens"] := state["completion_tokens"]
		if state.Has("total_tokens")      and state["total_tokens"]      > 0
			evt["total_tokens"] := state["total_tokens"]
		if state.Has("est_cost_usd")      and state["est_cost_usd"]      > 0
			evt["est_cost_usd"] := state["est_cost_usd"]
		KL_LogLlm("generation", evt)
	}

	; ``llm_suggested`` fires once per final render so a tail of the log
	; pairs each suggestion with exactly one ``llm_accepted`` (Tab) or
	; ``llm_dismissed`` (timeout / typing past it). Acceptance rate is
	; the ratio of accepted vs suggested. Lives on the engine side so
	; both the tooltip flow and the inline-autotype flow contribute.
	try {
		app_name := ""
		try app_name := WIGetFocused()["appId"]
		KL_LogLlmSuggested(app_name, state["slots"].Length)
	}

	LLM_Engine_OnResults(state["slots"], state["ctx"], 1, true)
}

; Returns the max number of attempts for ``n`` requested predictions,
; honouring the retry policy loaded from the shared inference.json.
_LLM_Engine_MaxAttempts(n) {
	policy := LLM_ApiCommon_GetRetryPolicy()
	max_mult := policy[1]
	return Max(n, n * Max(1, Integer(max_mult)))
}

; Resolves the profile id for the currently-focused window. The user can
; map an app's process name (lower-cased) to a specific profile via the
; tray UI; the engine consults that map on every fire so changing apps
; mid-typing flips the prompt without any explicit toggle.
_LLM_Engine_ResolveProfileIdForApp(default_id) {
	global _LLM_Engine
	if !_LLM_Engine.Has("app_profile_overrides")
		return default_id
	overrides := _LLM_Engine["app_profile_overrides"]
	if !(overrides is Map) or overrides.Count == 0
		return default_id
	; Pull the focused process via the WindowInfo adapter. WIGetFocused() can throw when no
	; window is focused (lock screen, transient menu); fall back to the
	; default in that case rather than blowing up the prediction.
	app := ""
	try app := StrLower(WIGetFocused()["appId"])
	if (app == "")
		return default_id
	; Drop any trailing ``.exe`` so user-entered overrides ("slack") match
	; the OS-reported process name ("slack.exe").
	app := RegExReplace(app, "\.exe$", "")
	if overrides.Has(app)
		return overrides[app]
	return default_id
}

; Look up the active remote API entry from the engine state. Returns the entry
; record (Map or object) ready to feed into ``LLM_RemoteGenerate``, or "" when
; no entries are configured / no active id is set. Keeps the lookup logic out
; of the hot path so future changes (e.g. resolving by name, fallback chain)
; only touch one place.
; Parse raw model output into tooltip slot strings (macOS Parser + insert_prediction).
_LLM_Engine_ParseSlots(raw, state) {
	is_batch := state.Has("is_batch") and state["is_batch"]
	return LLM_Parser_ParseResponse(
		raw,
		state["ctx"],
		state.Has("ctx_tail") ? state["ctx_tail"] : state["ctx"],
		state.Has("min_words") ? state["min_words"] : 1,
		state.Has("max_words") ? state["max_words"] : 15,
		is_batch,
		state["requested"]
	)
}

_LLM_Engine_GetActiveApiEntry() {
	global _LLM_Engine
	entries := _LLM_Engine.Has("api_entries") ? _LLM_Engine["api_entries"] : []
	if (Type(entries) != "Array" or entries.Length == 0)
		return ""
	active_id := _LLM_Engine.Has("api_entry_id") ? _LLM_Engine["api_entry_id"] : ""
	if (active_id != "") {
		for , e in entries {
			id := (e is Map and e.Has("Id")) ? e["Id"] : (e.HasOwnProp("Id") ? e.Id : "")
			if (id == active_id)
				return e
		}
	}
	; Fallback: first entry. Better than silent zero predictions when the
	; user has at least one entry configured but has not picked one yet.
	return entries[1]
}

/**
 * Multi-prediction tooltip update callback. Invoked by the variant loop
 * every time a new slot fills in (intermediate) and once more when the
 * full set is finalised. Mirrors the HS on_success(results, ms, is_final)
 * signature minus the timing field, which lives in the per-variant logs.
 *
 * @param {Array}    slots     - Slot strings (empty string = in-flight placeholder).
 * @param {string}   ctx       - The context that produced these slots.
 * @param {Integer}  active    - 1-based active slot index (the one Tab fires on).
 * @param {boolean}  is_final  - True only on the last update of a request.
 */
LLM_Engine_OnResults(slots, ctx, active := 1, is_final := false) {
	global _LLM_Engine, _LLM_Bridge_Buffer
	; Inline auto-type mode (Copilot-style): the prediction is typed
	; directly into the active app instead of being shown in a tooltip.
	; We only auto-type on the FINAL render — typing per-token from
	; on_partial would race the user's own keystrokes with no clean way
	; to roll back. Letting the variant complete first means one
	; deterministic SendText burst with a known length.
	if (is_final and _LLM_Engine.Has("inline_autotype") and _LLM_Engine["inline_autotype"]) {
		; Delay (ms) before releasing the synthetic flag. The TextSend below is
		; asynchronous — the injected characters reach the InputHook a few ms
		; later; clearing inline would re-enable manual observation before the
		; burst has passed through. Mirrors LLM_Bridge_OnAccept (rule 5.2).
		static SYNTH_CLEAR_DELAY_MS := 80
		if (slots.Length > 0) {
			idx := Max(1, Min(active, slots.Length))
			text := slots[idx]
			if (text != "") {
				_LLM_Engine["inline_last_typed"] := text
				; Mute the hotstring InputHook so the injected characters do
				; not re-enter the engine and trigger false hotstring matches.
				if IsSet(PrefixWatcherSuppress)
					try PrefixWatcherSuppress(true)
				; Tag the auto-typed prediction as synthetic so the keylogger
				; keeps it out of the manual ``chars`` count and attributes it
				; to the LLM source — same PII guard as LLM_Bridge_OnAccept.
				; Without it the model output is recorded as words the human
				; typed (inflating WPM, polluting n-gram stats).
				try KL_MarkSynthetic("llm")
				TextSend(text, 0, 0)
				; Advance the rolling context buffer by the inserted text so the
				; next keystroke predicts against what the document actually
				; contains. Without this the engine's context desyncs from the
				; document and the following prediction runs on stale context.
				if IsSet(_LLM_Bridge_Buffer)
					_LLM_Bridge_Buffer .= text
				; Clear stale HSE and prefix buffers — cursor is now past the
				; injected text, so accumulated context is no longer valid.
				if IsSet(HSE_HardReset)
					try HSE_HardReset()
				if IsSet(_ResetPrefixBuffer)
					try _ResetPrefixBuffer()
				if IsSet(PrefixWatcherSuppress)
					SetTimer((*) => PrefixWatcherSuppress(false), -SYNTH_CLEAR_DELAY_MS)
				; Deferred release so any characters still queued in the OS
				; message loop are tagged synthetic before observation resumes.
				SetTimer((*) => KL_ClearSynthetic(), -SYNTH_CLEAR_DELAY_MS)
				; Don't fall through to the tooltip — inline mode owns
				; the entire UI surface for this prediction.
				return
			}
		}
	}

	; On the final render, enrich each completed slot with diff chunks so the
	; Gui-based tooltip can colourise corrections (green) vs. next-words
	; (orange). Streaming / intermediate renders pass plain strings — diff
	; against a partial token would be meaningless.
	display_slots := slots
	if (is_final and IsSet(LLM_Diff_Compute)) {
		buf_tail := _LLM_Engine.Has("last_ctx") ? _LLM_Engine["last_ctx"] : ""
		; Use only the last 200 chars of the context as the diff anchor — the
		; full context is too long and makes prefix-matching meaningless.
		if (StrLen(buf_tail) > 200)
			buf_tail := SubStr(buf_tail, -199)
		display_slots := []
		for _, s in slots {
			if (s != "")
				display_slots.Push(LLM_Diff_Compute(buf_tail, s))
			else
				display_slots.Push(s)
		}
	}

	_LLM_Engine_ApplyTooltipDisplayOpts(slots.Length)
	LLM_Tooltip_Show(display_slots, active, is_final)
	if is_final
		try LLM_Tooltip_MarkChainComplete()
}

_LLM_Engine_ResolveBackendLabel() {
	global _LLM_Engine
	backend := _LLM_Engine.Has("backend") ? _LLM_Engine["backend"] : "ollama"
	if (backend = "mlx")
		return "MLX 🚀"
	if (backend = "ollama")
		return "Ollama 🦙"
	return ""
}

_LLM_Engine_TrimProfileLabel(label) {
	if (Type(label) != "String" or label = "")
		return ""
	clean := Trim(label)
	if (clean = "")
		return ""
	if RegExMatch(clean, "^(.*?)\s*—", &m) {
		head := Trim(m[1])
		if (head != "")
			return head
	}
	return RegExReplace(clean, "\s*—\s*$", "")
}

_LLM_Engine_BuildInfoBarText(modelName, backend := "", profileName := "") {
	if (modelName = "")
		return ""
	pieces := [modelName]
	if (backend != "")
		pieces.Push(backend)
	shortProfile := _LLM_Engine_TrimProfileLabel(profileName)
	if (shortProfile != "")
		pieces.Push(shortProfile)
	out := ""
	for i, p in pieces
		out .= (i = 1) ? p : " — " . p
	return out
}

