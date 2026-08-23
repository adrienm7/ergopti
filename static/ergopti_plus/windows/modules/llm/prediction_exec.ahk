; modules/llm/prediction_exec.ahk

; ==============================================================================
; MODULE: LLM Prediction Engine — Prediction Execution
; DESCRIPTION:
; Fires LLM prediction requests after the debounce period, builds prompts via
; PromptBuilder, dispatches to the Ollama or remote API backends, and handles
; result display and caching.
;
; Included by modules/llm/prediction_engine.ahk after the keystroke-handler section.
; ==============================================================================





; =======================================
; =======================================
; ======= 1/ Prediction Execution =======
; =======================================
; =======================================

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
	return Max(5, maxTokens * n + n * LLM_PRED_TOKEN_OVERHEAD)
}

; Return a detached, fail-closed acceptance-source snapshot. Timer callers pass
; the source captured with the keystroke that armed them; direct/manual callers
; omit it and capture the currently focused control at dispatch time.
_LLM_Engine_NormalizeAcceptSource(AcceptSource := unset) {
	if !IsSet(AcceptSource)
		return _LLM_Engine_CaptureAcceptSource()
	if !(AcceptSource is Map)
		return Map("hwnd", 0, "control", 0)
	Hwnd := AcceptSource.Get("hwnd", 0)
	ControlToken := AcceptSource.Get("control", 0)
	if !(Hwnd is Integer and Hwnd > 0
			and ControlToken is Integer and ControlToken > 0)
		return Map("hwnd", 0, "control", 0)
	return Map("hwnd", Hwnd, "control", ControlToken)
}

; Resolve the source owned by the request whose tooltip is about to be painted.
; An id mismatch means the renderer cannot prove ownership and must publish an
; empty source, making Tab acceptance fail closed.
_LLM_Engine_RequestAcceptSourceForRender(RequestId := "") {
	global _LLM_Engine
	if (RequestId == "")
		return ""
	Source := _LLM_Engine.Get("request_accept_source", "")
	if !(Source is Map)
		return ""
	if (Source.Get("request_id", -1) != RequestId)
		return ""
	Hwnd := Source.Get("hwnd", 0)
	ControlToken := Source.Get("control", 0)
	if !(Hwnd is Integer and Hwnd > 0
			and ControlToken is Integer and ControlToken > 0)
		return ""
	return Map(
		"hwnd", Hwnd,
		"control", ControlToken,
		"request_id", Source.Get("request_id", 0),
		"app_name", Source.Get("app_name", "")
	)
}

_LLM_Engine_AppNameForAcceptSource(Source) {
	if !(Source is Map)
		return ""
	Hwnd := Source.Get("hwnd", 0)
	if !(Hwnd is Integer and Hwnd > 0)
		return ""
	AppName := ""
	try AppName := WinGetProcessName("ahk_id " . Hwnd)
	return AppName
}

; Pure consumer for the production privacy gate. Engine admission guarantees a
; flat string array; the defensive type check keeps the hot path fail-closed if
; a future internal writer bypasses that boundary.
_LLM_Engine_AppIsExcluded(AppId) {
	global _LLM_Engine
	if !(AppId is String) || AppId == ""
		return false
	Apps := _LLM_Engine.Get("disabled_apps", [])
	if !(Apps is Array)
		return true
	Needle := RegExReplace(StrLower(AppId), "\.exe$", "")
	for App in Apps {
		if !(App is String)
			return true
		if (RegExReplace(StrLower(App), "\.exe$", "") == Needle)
			return true
	}
	return false
}

; Owns the complete disabled-app privacy decision so the production caller and
; tests cannot disagree about invalid state, focus lookup, or name matching.
_LLM_Engine_ShouldSuppressForDisabledApps(FocusFn := 0) {
	global _LLM_Engine
	Apps := _LLM_Engine.Get("disabled_apps", [])
	if !(Apps is Array) {
		try LoggerError("LLM",
			"Prediction suppressed because disabled-app state is not a validated array.")
		return true
	}
	if (Apps.Length == 0)
		return false
	Focused := Map("appId", "")
	try Focused := HasMethod(FocusFn, "Call") ? FocusFn.Call() : WIGetFocused()
	AppId := (Focused is Map) ? Focused.Get("appId", "") : ""
	if !(AppId is String) || AppId == ""
		return false
	if !_LLM_Engine_AppIsExcluded(AppId)
		return false
	try LoggerInfo("LLM", "Prediction suppressed - '{1}' is on the disabled-apps list.",
		RegExReplace(StrLower(AppId), "\.exe$", ""))
	return true
}

/**
 * Fires the actual LLM call after the debounce period expires.
 * Skips the call if context is identical to the last result's context.
 * @param {string} buffer - Full typed buffer captured at debounce arm time.
 * @param {Map} AcceptSource - HWND/control snapshot captured when armed.
 */
LLM_Engine_FirePrediction(buffer, AcceptSource := unset) {
	global _LLM_Engine

	; A debounce timer outlives whatever armed it: it is scheduled with SetTimer
	; and fires from AHK's timer thread, long after the call site returned. If the
	; engine map has been replaced or torn down in the meantime, every read below
	; raises "Item has no value" from a timer thread — which no caller can catch,
	; so it kills the process rather than one prediction. Reading through .Has()
	; makes a stale timer a no-op, which is the only correct outcome: the state it
	; was armed for is gone.
	if (!(_LLM_Engine is Map) || !_LLM_Engine.Has("enabled")) {
		try LoggerWarn("LLM", "A debounce timer fired against a torn-down engine — prediction dropped.")
		return
	}
	_LLM_Engine["timer_active"] := false

	; Re-derive from live state at the request boundary as a backstop for editors
	; that mutate an Array/Map in place before calling Init. A missed writer can
	; therefore cause one cache miss, never a semantically stale cache hit.
	_LLM_Engine_RefreshSemanticConfig()

	; A debounce timer armed just before the user paused must not fire an HTTP
	; request or paint a prediction — « pause = tout éteint ».
	if A_IsSuspended
		return

	if !_LLM_Engine["enabled"] || buffer == ""
		return

	AcceptSource := _LLM_Engine_NormalizeAcceptSource(AcceptSource?)

	; Honour the disable_password_fields user preference: skip prediction in
	; password/secure fields to avoid leaking typed credentials into the LLM
	; context. Gate is only active when the flag is on to avoid the OS call
	; on every keystroke when the user has not opted in.
	;
	; MUST be the adapters/secure_field_detector.ahk port contract function
	; (SFD_IsSecureField) — not the keylogger's own KL_IsFocusedFieldPassword —
	; so this privacy gate has a single, directly-testable source of truth
	; shared with every other consumer of the SecureFieldDetector port instead
	; of duplicating Win32-class/style detection logic locally (MED-02: the
	; flag was stored from config but nothing ever consulted a detector at
	; prediction time, so enabling it in the tray menu had no effect).
	if (_LLM_Engine.Has("disable_password_fields") && _LLM_Engine["disable_password_fields"]) {
		; The adapter normally catches its own OS errors, but this keyboard-path
		; caller must still fail closed if a future port implementation throws.
		; Sending a password context is irreversible; suppressing one prediction
		; until the next safe buffer is always the correct privacy outcome.
		IsPw := true
		try IsPw := SFD_IsSecureField()
		if IsPw {
			try LoggerInfo("LLM", "Prediction suppressed — password field detected.")
			return
		}
	}

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
	RequestAcceptSource := AcceptSource.Clone()
	RequestAcceptSource["request_id"] := this_request_id
	RequestAcceptSource["app_name"] :=
		_LLM_Engine_AppNameForAcceptSource(RequestAcceptSource)
	_LLM_Engine["request_accept_source"] := RequestAcceptSource

	; Honour the disabled_apps user preference: skip prediction entirely when the focused
	; app is on the user's exclusion list, so typed context never leaves an app the user
	; opted out of (privacy parity with macOS app_filter.is_blocked). The flag is persisted
	; and shown in the menu but was previously never enforced. Resolve the focused process
	; only when the list is non-empty, so no OS call runs on the per-fire path when the user
	; has not excluded any app (llm-app-filter-enforced).
	if _LLM_Engine_ShouldSuppressForDisabledApps()
		return

	backend_now := _LLM_Engine.Has("backend") ? _LLM_Engine["backend"] : "ollama"
	if (backend_now = "ollama" and IsSet(LLM_OllamaAllowInference) and !LLM_OllamaAllowInference()) {
		static _LLM_LastDeferLogTick := 0
		; Wrap-safe tick delta: A_TickCount overflows at ~49.7 days
		if (((A_TickCount - _LLM_LastDeferLogTick + 0x100000000) & 0xFFFFFFFF) > 5000) {
			_LLM_LastDeferLogTick := A_TickCount
			try LoggerInfo("LLM", "Ollama warmup in progress — prediction deferred (retry shortly).")
		}
		if IsSet(LLM_OllamaScheduleWarmupRetry)
			LLM_OllamaScheduleWarmupRetry(_LLM_Engine["model"])
		retry_ms := Max(500, Min(_LLM_Engine["debounce_ms"], 2000))
		_LLM_Engine["pending_timer"] := LLM_Engine_FirePrediction.Bind(buffer, AcceptSource)
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
		"max_words",            _LLM_Engine["max_words"],
		"min_words",            _LLM_Engine["min_words"],
		"num_predictions",      _LLM_Engine["n_predictions"],
		"temperature",          _LLM_Engine["temperature"] + 0.0,
		"auto_raise_temp",      _LLM_Engine["auto_raise_temp"],
		"language",             _LLM_Engine["language"],
		; The user's llm_context_length. Omitting it is why the setting had no
		; effect on the automatic path: the menu wrote it, the manual trigger
		; shortcut honoured it, and every automatic prediction ignored it.
		"context_window_chars", _LLM_Engine["ctx_chars"]
	)
	params := pb.Build(buffer, pb_cfg)
	ctx := params["context"]
	tail := params["context_tail"]
	req_temp := params["temperature"]
	; The focused application can select a different prompt without changing the
	; configuration Map. Resolve it before both cache probes and bind it into the
	; request signature so identical text in two overridden apps cannot share an
	; answer generated from different instructions.
	effective_profile_id := _LLM_Engine_ResolveProfileIdForApp(_LLM_Engine["profile_id"])
	profile := LLM_GetActiveProfile(effective_profile_id,
		_LLM_Engine.Has("user_profiles") ? _LLM_Engine["user_profiles"] : [])
	request_semantic_signature := _LLM_Engine_RequestSemanticSignature(
		effective_profile_id, profile)
	_LLM_Engine["active_request_signature"] := request_semantic_signature
	; Per-prediction output-token budget computed once by the shared PromptBuilder
	; (max(15, max_words*6+10), default 150) — the single cross-driver source.
	; Threaded to every backend below so AHK no longer re-derives its own cap
	; (Ollama's mw*4 / remote's hardcoded 256), matching the macOS driver.
	max_tokens := Integer(params["max_tokens"])

	if (tail == "" or StrLen(tail) < 2) {
		try LoggerInfo("LLM", "Context too short — prediction skipped.")
		return
	}

	; Log the SIZE of the context, never its content. This used to emit
	; SubStr(tail, -40), so the daily log accumulated a rolling 40-character
	; sample of everything the user typed while the LLM was on — a plaintext
	; keystroke sink outside the keylogger's privacy policy, which governs
	; today.log and data.sql only. macOS already logs a length here.
	try LoggerInfo("LLM", "Prediction request queued — {1} chars of context.", StrLen(tail))

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
			and _LLM_Engine["last_results"].Length > 0
			and _LLM_Engine_CacheOwnsRequest(request_semantic_signature)) {
		; Cancel both curl streams and in-flight WinHTTP requests so no stale
		; response lands after the cache hit is already rendered. The remote
		; sibling has to be cancelled too: its result was already discarded by the
		; request-id check, but without this its curl child and the temp files
		; carrying the typed context survive until the poll tick reaps them.
		try LLM_OllamaCancelAllAsync()
		try LLM_RemoteCancelAllAsync()
		LLM_Engine_OnResults(_LLM_Engine["last_results"], ctx, 1, true,
			this_request_id, request_semantic_signature)
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
			and _LLM_Engine_CacheOwnsRequest(request_semantic_signature)
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
			; Same race fix as the exact-match cache branch above: cancel all
			; in-flight WinHTTP requests and curl streams — local AND remote — so
			; no stale response clobbers the cache hit render and no orphaned curl
			; child keeps a PII temp file alive.
			try LLM_OllamaCancelAllAsync()
			try LLM_RemoteCancelAllAsync()
			LLM_Engine_OnResults(sliced, ctx, 1, true, this_request_id,
				request_semantic_signature)
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
	; Wrap-safe delta: A_TickCount overflows at ~49.7 days; the mask keeps the
	; result in [0, 0xFFFFFFFF] regardless of counter direction
	elapsed_since_last := (now - last + 0x100000000) & 0xFFFFFFFF
	if (last > 0 and elapsed_since_last < min_interval) {
		remaining := min_interval - elapsed_since_last
		; Same reasoning as LLM_Engine_OnKeystroke: keep a reference to the
		; closure so the next CancelTimer call can actually cancel it.
		_LLM_Engine["pending_timer"] := LLM_Engine_FirePrediction.Bind(buffer, AcceptSource)
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
		if (entry == "") {
			; AHK-26: fail fast with a diagnostic — a silent return here left the
			; user with no tooltip and no log, indistinguishable from a working state
			try LoggerWarn("LLM", "API backend selected but no entry configured — prediction skipped.")
			return
		}
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
			"semantic_signature", request_semantic_signature,
			"backend",       backend,
			"model",         log_model,
			"system_prompt", system_prompt,
			"requested",     n_predictions,
			"base_temp",     req_temp,
			"dedup_stats",   LLM_ApiCommon_NewDedupStats(),
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
		"semantic_signature", request_semantic_signature,
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
		"show_all_at_once",  _LLM_Engine.Has("show_all_at_once") and _LLM_Engine["show_all_at_once"],
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
	RequestId := _LLM_Engine.Get("request_id", 0)
	SemanticSignature := _LLM_Engine.Get("active_request_signature", "")
	Source := _LLM_Engine_RequestAcceptSourceForRender(RequestId)
	Meta := Map(
		"offer_id", RequestId,
		"accept_source", Source,
		"app_name", (Source is Map) ? Source.Get("app_name", "") : "",
		"render_guard", _LLM_Engine_RenderIdentityIsCurrent.Bind(
			RequestId, SemanticSignature)
	)
	try LLM_Tooltip_ShowLoading(Meta)
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
	if !_LLM_Engine_IsCurrent(state)
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
	state["slots"] := slots
	_LLM_Engine_FinalizeRequest(state)
}

_LLM_Engine_OnBatchFail(state) {
	; Batch failures don't retry — the cost of a re-request is much higher
	; than for a single variant, and the user has already paid the latency
	; of the first attempt. Let the tooltip fade via its auto-dismiss
	; timer instead.
	global _LLM_Engine
	if !_LLM_Engine_IsCurrent(state)
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
; ``max_count`` (default 0 = unlimited) caps the output to prevent a
; hallucinating model from generating dozens of separators and saturating the
; tooltip or parser with unbounded allocations (llm-split-batch-no-cap).
_LLM_Engine_SplitBatchBlocks(raw, max_count := 0) {
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
		; Stop early when the caller requested a hard cap (llm-split-batch-no-cap)
		if (max_count > 0 and blocks.Length >= max_count)
			break
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
	if !_LLM_Engine_IsCurrent(state)
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
	pad_to := Min(variant_idx, state["requested"])
	while (preview_slots.Length < pad_to)
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
		LLM_Engine_OnResults(preview_slots, state["ctx"], active_idx, false,
			state["request_id"], state["semantic_signature"])
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
			(failure := "") => _LLM_Engine_OnVariantFail(state_ref, failure))
		return
	}

	dispatch_fn := state["dispatch_fn"]
	; Same signature as the streaming branch — forward ``meta`` so the
	; finalize step can record token usage / cost. Without ``meta`` here
	; the API path silently zeroed those metrics in the keylogger event.
	dispatch_fn.Call(temp,
		(text, meta := "") => _LLM_Engine_OnVariantSuccess(state_ref, text, meta),
		(failure := "") => _LLM_Engine_OnVariantFail(state_ref, failure))
}

; Per-token streaming callback: paints the partial text into its slot in
; real time. The slot index is captured at dispatch time so multiple
; in-flight variants don't trip over each other. Same dedup is NOT applied
; here — we run the full text through dedup on on_success, where the
; comparison is meaningful.
_LLM_Engine_OnStreamPartial(state, slot_idx, partial) {
	global _LLM_Engine
	if !_LLM_Engine_IsCurrent(state)
		return
	if state.Has("show_all_at_once") and state["show_all_at_once"]
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
	LLM_Engine_OnResults(preview, state["ctx"], slot_idx, false,
		state["request_id"], state["semantic_signature"])
}

_LLM_Engine_OnVariantSuccess(state, text, meta := "") {
	global _LLM_Engine
	if !_LLM_Engine_IsCurrent(state) {
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
	if !(state.Has("show_all_at_once") and state["show_all_at_once"])
		LLM_Engine_OnResults(state["slots"], state["ctx"], active_idx, false,
			state["request_id"], state["semantic_signature"])
	_LLM_Engine_DispatchVariant(state)
}

_LLM_Engine_OnVariantFail(state, failure := "") {
	global _LLM_Engine
	if !_LLM_Engine_IsCurrent(state) {
		try LoggerInfo("LLM", "Variant failure ignored — superseded by newer typing.")
		return
	}
	; Curl streaming is best-effort on Windows — fall back to WinHTTP async for
	; the remaining attempts in this request when a stream dies empty.
	if (state.Has("streaming") and state["streaming"]) {
		state["streaming"] := false
		try LoggerInfo("LLM", "Streaming failed — retrying via WinHTTP async.")
	}
	Reason := ""
	if (failure is Map and failure.Has("message"))
		Reason := failure["message"]
	else if (Type(failure) == "String")
		Reason := failure
	try LoggerWarn("LLM", "Variant {1}/{2} failed (model {3}): {4}.",
		state["attempt_index"] - 1, state["max_attempts"], state["model"], Reason)
	; The variant didn't yield a usable result. ``attempt_index`` already
	; advanced for the next attempt; the retry budget (max_attempts) caps
	; how often we keep trying. No special retry-temperature step here —
	; the diversity step bumps the temperature on the next variant anyway,
	; which is the same end effect.
	_LLM_Engine_DispatchVariant(state)
}

/**
 * True while `state` still describes the request the engine is waiting for.
 *
 * The engine bumps ``request_id`` on every fire, while the semantic signature
 * binds the callback to the model/prompt/API configuration that dispatched it.
 * Both must still match: request-id alone cannot distinguish two generations
 * for identical text across a live configuration or per-application profile
 * change. The check is repeated after every yielding finalization stage so a
 * stale callback cannot paint or re-seed the cache.
 * @param {Map} state The per-request state carried by the callback.
 * @returns {Integer} 1 when the request is still current.
 */
_LLM_Engine_IsCurrent(state) {
	global _LLM_Engine
	if !(state is Map) or !state.Has("request_id") or !state.Has("semantic_signature")
		return false
	current_id := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	return (state["request_id"] == current_id
		and _LLM_Engine_SignaturesEqual(
			state["semantic_signature"], _LLM_Engine.Get("active_request_signature", "")))
}

_LLM_Engine_RenderIdentityIsCurrent(RequestId, SemanticSignature) {
	return _LLM_Engine_IsCurrent(Map(
		"request_id", RequestId,
		"semantic_signature", SemanticSignature))
}

_LLM_Engine_FinalizeRequest(state) {
	global _LLM_Engine
	if !_LLM_Engine_IsCurrent(state)
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
	try LLM_ApiCommon_LogSummary((state.Has("is_batch") and state["is_batch"]) ? "batch" : "sequential", state["requested"], state["dedup_stats"], state["slots"].Length)
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
			; Wrap-safe: A_TickCount rolls over at ~49.7 days
			evt["elapsed_ms"] := (A_TickCount - state["request_start"] + 0x100000000) & 0xFFFFFFFF
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

	; Re-checked HERE — as the LAST statement before anything observable. The
	; entry check alone was never enough, but neither was a check placed above the
	; block: the summary log, the focused-window query and the keylogger write all
	; yield, and a keystroke arriving in that window supersedes this request.
	; Painting anyway shows a prediction for text the user has already left (the
	; deferred tooltip hide that should correct it is skipped on the generation
	; mismatch the render itself creates), and seeding last_ctx with it hands the
	; stale context to the next request too, which then replays it from cache.
	if !_LLM_Engine_IsCurrent(state) {
		try LoggerInfo("LLM", "Prediction superseded before render — discarding request #{1}.", state["request_id"])
		return
	}
	_LLM_Engine["last_ctx"]     := state["ctx"]
	_LLM_Engine["last_results"] := state["slots"]
	_LLM_Engine["last_semantic_signature"] := state["semantic_signature"]
	; Keep ``last_result`` (singular) for the legacy cache hit path so any
	; external code still reading that field keeps working.
	_LLM_Engine["last_result"]  := state["slots"][1]

	; ``request_id`` is threaded through so the render can gate once more on its
	; own side: LLM_Diff_Compute and the display-opts resolution run between here
	; and the paint, and both can yield.
	LLM_Engine_OnResults(state["slots"], state["ctx"], 1, true,
		state["request_id"], state["semantic_signature"])
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
	is_batch  := state.Has("is_batch") and state["is_batch"]
	; Defensive: batch state did not always include dedup_stats before the fix;
	; fall back to a fresh stats object so a missing key never throws in the
	; async callback (which swallows exceptions silently).
	dedup_ref := state.Has("dedup_stats") ? state["dedup_stats"] : LLM_ApiCommon_NewDedupStats()
	result    := LLM_Parser_ParseResponse(
		raw,
		state["ctx"],
		state.Has("ctx_tail") ? state["ctx_tail"] : state["ctx"],
		state.Has("min_words") ? state["min_words"] : 1,
		state.Has("max_words") ? state["max_words"] : 15,
		is_batch,
		state["requested"],
		&dedup_ref
	)
	state["dedup_stats"] := dedup_ref
	return result
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
 * @param {Array}    slots      - Slot strings (empty string = in-flight placeholder).
 * @param {string}   ctx        - The context that produced these slots.
 * @param {Integer}  active     - 1-based active slot index (the one Tab fires on).
 * @param {boolean}  is_final   - True only on the last update of a request.
 * @param {string}   request_id - Monotonic request identity that owns this render.
 * @param {string}   semantic_signature - Generation configuration that owns it.
 */
LLM_Engine_OnResults(slots, ctx, active := 1, is_final := false, request_id := "", semantic_signature := "") {
	global _LLM_Engine, _LLM_Bridge_Buffer
	; Inline auto-type mode (Copilot-style): the prediction is typed
	; directly into the active app instead of being shown in a tooltip.
	; We only auto-type on the FINAL render — typing per-token from
	; on_partial would race the user's own keystrokes with no clean way
	; to roll back. Letting the variant complete first means one
	; deterministic SendText burst with a known length.
	if (is_final and _LLM_Engine.Has("inline_autotype") and _LLM_Engine["inline_autotype"]) {
		if (slots.Length > 0) {
			idx := Max(1, Min(active, slots.Length))
			text := slots[idx]
			if (text != "") {
				; The request may have finished while the driver was suspended. Do
				; not turn a stale final result into synthetic foreground input.
				if A_IsSuspended {
					try LoggerInfo("LLM", "Inline auto-type skipped while suspended.")
					return
				}
				; The SAME staleness gate the tooltip render performs further down,
				; applied here because this branch returns before ever reaching it.
				; That gate exists because this thread can be pre-empted between the
				; caller check and the paint, and the consequence is far worse on this
				; path: a superseded tooltip paints a stale suggestion the user can
				; ignore, while a superseded inline auto-type SendTexts model output for
				; ABANDONED text straight into the document, where nothing takes it back
				; (llm-inline-autotype-injects-superseded-prediction).
				if (request_id != "" and !_LLM_Engine_IsCurrent(Map(
						"request_id", request_id, "semantic_signature", semantic_signature))) {
					try LoggerInfo("LLM", "Inline auto-type skipped — prediction superseded during render (request #{1}).", request_id)
					return
				}
				; Capture the request-owned target and all input generations. TextSend
				; rechecks them at the real direct/paste boundary, then emits through
				; SendInput and commits every RAM mirror before physical input resumes.
				Source := _LLM_Engine_RequestAcceptSourceForRender(request_id)
				AdmissionSeed := _LLM_Bridge_CaptureAdmissionSeed(Source)
				Transaction := _LLM_Bridge_NewInjectionTransaction(
					text, AdmissionSeed, request_id, true, slots, idx)
				TextSend(text, _LLM_Bridge_InjectionOptions(Transaction),
					LLM_Engine_OnInlineInjectComplete.Bind(Transaction))
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
		; Use the context that produced THIS prediction as the diff anchor,
		; not last_ctx — which is only updated on success and would be stale
		; after a failed request, causing the diff to compute against the
		; wrong baseline if the user typed more since the last accepted prediction
		buf_tail := ctx
		; Use only the last 200 chars of the context as the diff anchor — the
		; full context is too long and makes prefix-matching meaningless
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
	; Last staleness gate, on the render's own side. LLM_Diff_Compute runs a
	; RegExMatch per character over each slot and the display-opts resolution
	; queries the focused window, so this thread can be pre-empted between the
	; caller's check and the paint. Painting after a supersede leaves a prediction
	; for abandoned text on screen that the keystroke's deferred hide can no longer
	; dismiss, because the paint itself bumps the tooltip generation it compares.
	if (request_id != "" and !_LLM_Engine_IsCurrent(Map(
			"request_id", request_id, "semantic_signature", semantic_signature))) {
		try LoggerInfo("LLM", "Prediction superseded during render — discarding request #{1}.", request_id)
		return
	}
	; Freeze the chain timings BEFORE the final render, not after it. The render
	; reads TtftMs / TtltMs synchronously while building the info bar, so this
	; ordering shows the same durations in a single rebuild — where the previous
	; order paid one full tooltip rebuild for the prediction and a second one whose
	; only purpose was to print the duration onto it.
	if is_final
		try LLM_Tooltip_MarkChainTimingOnly(A_TickCount)
	RenderAcceptSource := _LLM_Engine_RequestAcceptSourceForRender(request_id)
	PresentationMeta := Map(
		"offer_id", request_id,
		"accept_source", RenderAcceptSource,
		"app_name", (RenderAcceptSource is Map)
			? RenderAcceptSource.Get("app_name", "") : "",
		"is_final", is_final ? true : false
	)
	if request_id != ""
		PresentationMeta["render_guard"] :=
			_LLM_Engine_RenderIdentityIsCurrent.Bind(
				request_id, semantic_signature)
	; The common surface transaction publishes pixels, slots, active index,
	; acceptance target and lifecycle metrics as one owner. A refused/stale render
	; therefore cannot emit llm_suggested or replace the source of visible A.
	LLM_Tooltip_Show(display_slots, active, is_final, PresentationMeta)
}

LLM_Engine_OnInlineInjectComplete(Transaction, Ok := true, ErrorMessage := "") {
	if !Ok {
		try LoggerWarn("LLM", "Inline auto-type was not injected: {1}", ErrorMessage)
		return
	}
	if (ErrorMessage != "")
		try LoggerWarn("LLM", "Inline output completed with a non-retryable warning: {1}", ErrorMessage)
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
