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





; =======================================
; =======================================
; ======= 1/ Engine Configuration =======
; =======================================
; =======================================

; Runtime state — populated at first LLM_Engine_Init() call from LLM_Defaults
; (loaded by infra/llm_defaults.ahk at boot) so all values come from the shared
; defaults.json rather than being hardcoded here.
; Timer/cache keys are always initialised to their zero values regardless.
; String/numeric placeholder values — always overwritten by LLM_Engine_ApplySharedDefaults()
; which reads from LLM_Defaults (infra/llm_defaults.ahk → _shared/modules/llm/defaults.json).
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
	"language",                   "",
	"temperature",                "0.10",
	"instant_on_word_end",        true,
	"after_hotstring",            true,
	"reset_on_nav",               true,
	"disable_url_bars",           false,
	"disable_password_fields",    true,
	"disabled_apps",              [],
	"show_info_bar",              true,
	"streaming",                  true,
	"show_all_at_once",           true,
	"pred_indent",                0,
	"auto_raise_temp",            true,
	"nav_modifiers",              "",
	"val_modifiers",              "alt",
	"timer_active",               false,
	; Acceptance origin captured with the keystroke that arms a request. The
	; detached presentation record receives its own immutable copy at pixel
	; commit; no parallel rendered-source field exists in the engine.
	"request_accept_source",      "",
	"last_ctx",                   "",
	"last_result",                "",
	"last_results",               [],
	; Cache and callback ownership include the generation configuration. The
	; base signature is configuration-only; the request signature also carries
	; the effective per-application profile selected at fire time.
	"semantic_config_signature",  "",
	"active_request_signature",   "",
	"last_semantic_signature",    "",
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
	"api_entry_id",               "",
	"app_profile_overrides",      Map()
)

; Every option emitted by LLM_Menu_BuildOpts belongs to exactly one class.
; Generation-semantic values must invalidate cache and callbacks. Display-only
; values deliberately retain them. Runtime-policy values control when or where
; an otherwise identical result is requested/consumed, not what the model sees.
global LLM_ENGINE_SEMANTIC_CONFIG_KEYS := [
	"backend",
	"ollama_port",
	"model",
	"profile_id",
	"user_profiles",
	"n_predictions",
	"min_words",
	"max_words",
	"ctx_chars",
	"language",
	"temperature",
	"auto_raise_temp",
	"inline_autotype",
	"api_entries",
	"api_entry_id",
	"app_profile_overrides"
]

global LLM_ENGINE_DISPLAY_ONLY_CONFIG_KEYS := [
	"show_info_bar",
	"show_all_at_once",
	"pred_indent",
	"nav_modifiers",
	"val_modifiers"
]

LLM_BackendCapabilities(Backend) {
	; Windows has no typed/reliable partial-frame transport yet. The same
	; capability object drives both the menu and dispatch so an unsupported
	; backend can never persist a checked control that runtime overrides.
	return Map("streaming", false)
}

global LLM_ENGINE_RUNTIME_POLICY_CONFIG_KEYS := [
	"debounce_ms",
	"instant_on_word_end",
	"after_hotstring",
	"reset_on_nav",
	"disable_url_bars",
	"disable_password_fields",
	"disabled_apps",
	"streaming"
]

; Per-backend minimum interval (ms) between two prediction requests is now
; defined in ``static/ergopti_plus/_shared/modules/llm/inference.json`` and read via
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

/**
 * Length-prefixes one signature component so embedded delimiters are harmless.
 * @param {string} Value - Encoded component.
 * @returns {string} Collision-free framed component.
 */
_LLM_Engine_FrameSignaturePart(Value) {
	return StrLen(Value) . ":" . Value
}

/**
 * Sorts encoded Map/Object entries by their encoded key, case-sensitively.
 * @param {Array} Entries - Maps with `sort_key`, `key`, and `value` fields.
 */
_LLM_Engine_SortSignatureEntries(Entries) {
	Index := 2
	while (Index <= Entries.Length) {
		Current := Entries[Index]
		Previous := Index - 1
		while (Previous >= 1
				and StrCompare(Entries[Previous]["sort_key"], Current["sort_key"], true) > 0) {
			Entries[Previous + 1] := Entries[Previous]
			Previous -= 1
		}
		Entries[Previous + 1] := Current
		Index += 1
	}
}

/**
 * Canonically encodes nested configuration values without relying on Map order.
 * @param {*} Value - Scalar, Array, Map, or plain object to encode.
 * @returns {string} Deterministic, type-preserving encoding.
 */
_LLM_Engine_EncodeSemanticValue(Value) {
	if (Value is Array) {
		Encoded := "A" . Value.Length . ":"
		Index := 1
		while (Index <= Value.Length) {
			if Value.Has(Index) {
				Part := _LLM_Engine_EncodeSemanticValue(Value[Index])
				Encoded .= "P" . _LLM_Engine_FrameSignaturePart(Part)
			} else {
				Encoded .= "H"
			}
			Index += 1
		}
		return Encoded
	}

	if (Value is Map) {
		Entries := []
		for Key, Item in Value {
			EncodedKey := _LLM_Engine_EncodeSemanticValue(Key)
			Entries.Push(Map(
				"sort_key", EncodedKey,
				"key", EncodedKey,
				"value", _LLM_Engine_EncodeSemanticValue(Item)
			))
		}
		_LLM_Engine_SortSignatureEntries(Entries)
		; CaseSense changes lookup semantics even when the visible entries match
		; (notably for per-app overrides), so it is part of Map identity too.
		Encoded := "M" . _LLM_Engine_FrameSignaturePart(Value.CaseSense)
		Encoded .= Entries.Length . ":"
		for Entry in Entries {
			Encoded .= _LLM_Engine_FrameSignaturePart(Entry["key"])
			Encoded .= _LLM_Engine_FrameSignaturePart(Entry["value"])
		}
		return Encoded
	}

	if IsObject(Value) {
		Entries := []
		for Key, Item in Value.OwnProps() {
			EncodedKey := _LLM_Engine_EncodeSemanticValue(Key)
			Entries.Push(Map(
				"sort_key", EncodedKey,
				"key", EncodedKey,
				"value", _LLM_Engine_EncodeSemanticValue(Item)
			))
		}
		_LLM_Engine_SortSignatureEntries(Entries)
		Encoded := "O" . _LLM_Engine_FrameSignaturePart(Type(Value))
		Encoded .= Entries.Length . ":"
		for Entry in Entries {
			Encoded .= _LLM_Engine_FrameSignaturePart(Entry["key"])
			Encoded .= _LLM_Engine_FrameSignaturePart(Entry["value"])
		}
		return Encoded
	}

	ValueType := Type(Value)
	if (ValueType == "String")
		return "S" . _LLM_Engine_FrameSignaturePart(Value)
	if (ValueType == "Integer")
		return "I" . Value . ";"
	if (ValueType == "Float")
		return "F" . Format("{:.17g}", Value) . ";"
	return "T" . _LLM_Engine_FrameSignaturePart(ValueType)
		. _LLM_Engine_FrameSignaturePart(Value . "")
}

/**
 * Builds the one canonical signature for every generation-affecting setting.
 * @param {Map} State - Optional engine state; defaults to the live engine.
 * @returns {string} Canonical semantic configuration signature.
 */
_LLM_Engine_BuildSemanticConfigSignature(State := unset) {
	global _LLM_Engine, LLM_ENGINE_SEMANTIC_CONFIG_KEYS
	Source := IsSet(State) ? State : _LLM_Engine
	if !(Source is Map)
		return ""

	Semantic := Map()
	for Key in LLM_ENGINE_SEMANTIC_CONFIG_KEYS {
		if Source.Has(Key)
			Semantic[Key] := Source[Key]
		else
			Semantic[Key] := Map("engine_key_missing", Key)
	}
	return _LLM_Engine_EncodeSemanticValue(Semantic)
}

/**
 * Compares semantic signatures case-sensitively.
 * @param {string} Left - First signature.
 * @param {string} Right - Second signature.
 * @returns {Integer} One when the signatures are byte-semantically equal.
 */
_LLM_Engine_SignaturesEqual(Left, Right) {
	return (Type(Left) == "String" and Type(Right) == "String"
		and StrCompare(Left, Right, true) == 0)
}

/**
 * Invalidates cache, timers, transports, and callbacks after a semantic change.
 * @returns {Integer} One when the configuration changed.
 */
_LLM_Engine_RefreshSemanticConfig() {
	global _LLM_Engine
	PreviousCritical := Critical("On")
	try {
		Current := _LLM_Engine_BuildSemanticConfigSignature(_LLM_Engine)
		Previous := _LLM_Engine.Get("semantic_config_signature", "")
		if _LLM_Engine_SignaturesEqual(Current, Previous)
			return false

		; Publish only after invalidation succeeds. If timer cancellation ever
		; throws, the old signature forces a retry instead of authorizing stale state.
		LLM_Engine_StopGeneration()
		_LLM_Engine["semantic_config_signature"] := Current
		_LLM_Engine["last_request_tick"] := 0
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

/**
 * Binds the base configuration to the profile effective for the focused app.
 * @param {string} EffectiveProfileId - Profile selected for this request.
 * @param {Map|Object} EffectiveProfile - Optional already-resolved profile.
 * @returns {string} Request/cache semantic signature.
 */
_LLM_Engine_RequestSemanticSignature(EffectiveProfileId, EffectiveProfile := unset) {
	global _LLM_Engine
	Base := _LLM_Engine.Get("semantic_config_signature", "")
	Profile := IsSet(EffectiveProfile)
		? EffectiveProfile
		: LLM_GetActiveProfile(EffectiveProfileId,
			_LLM_Engine.Get("user_profiles", []))
	return _LLM_Engine_FrameSignaturePart(Base)
		. _LLM_Engine_FrameSignaturePart(_LLM_Engine_EncodeSemanticValue(EffectiveProfileId))
		. _LLM_Engine_FrameSignaturePart(_LLM_Engine_EncodeSemanticValue(Profile))
}

/**
 * Reports whether the cached result belongs to the current semantic request.
 * @param {string} RequestSignature - Signature for the request being fired.
 * @returns {Integer} One when the cache may be reused.
 */
_LLM_Engine_CacheOwnsRequest(RequestSignature) {
	global _LLM_Engine
	return _LLM_Engine_SignaturesEqual(
		_LLM_Engine.Get("last_semantic_signature", ""), RequestSignature)
}

LLM_Engine_ApplySharedDefaults()
_LLM_Engine["semantic_config_signature"] := _LLM_Engine_BuildSemanticConfigSignature(_LLM_Engine)





; ============================
; ============================
; ======= 2/ Lifecycle =======
; ============================
; ============================

/**
 * Initialises the prediction engine with user settings.
 * Must be called before any other LLM_Engine_* function.
 * @param {Map} opts - Map with optional keys: model, profile_id,
 *   n_predictions, min_words, max_words, debounce_ms, ctx_chars, language.
 */
LLM_Engine_Init(opts) {
	global _LLM_Engine, _I18nLocale
	if !(opts is Map)
		throw TypeError("LLM_Engine_Init options must be a Map.")
	static _optionKeys := ["model", "profile_id", "backend", "n_predictions",
		"min_words", "max_words", "debounce_ms", "ctx_chars", "language",
		"temperature", "instant_on_word_end", "after_hotstring", "reset_on_nav",
		"disable_url_bars", "disable_password_fields", "show_info_bar",
		"streaming", "show_all_at_once", "pred_indent", "auto_raise_temp",
		"nav_modifiers", "val_modifiers", "inline_autotype", "api_entry_id",
		"ollama_port", "user_profiles", "disabled_apps", "api_entries",
		"app_profile_overrides"]
	ValidatedOpts := Map()
	for Key in _optionKeys {
		if !opts.Has(Key)
			continue
		if !LLM_Option_TryNormalize(Key, opts[Key], &Normalized)
			throw TypeError("LLM_Engine_Init rejected invalid option '" . Key . "'.")
		ValidatedOpts[Key] := Normalized
	}
	PreviousCritical := Critical("On")
	try {
		_LLM_Engine["enabled"] := true

		static _keys := ["model", "profile_id", "backend", "n_predictions", "min_words", "max_words",
			"debounce_ms", "ctx_chars", "language", "temperature",
			"instant_on_word_end", "after_hotstring", "reset_on_nav",
			"disable_url_bars", "disable_password_fields",
			"show_info_bar", "streaming", "show_all_at_once",
			"pred_indent", "auto_raise_temp", "nav_modifiers", "val_modifiers",
			"inline_autotype", "api_entry_id"]

		for _, k in _keys
			if ValidatedOpts.Has(k)
				_LLM_Engine[k] := ValidatedOpts[k]

		; The prediction language follows the active UI locale (the i18n single source
		; of truth, infra/i18n.ahk) instead of a hardcoded "fr", so a user typing in their
		; own language gets predictions in it. An explicit opts["language"] still wins.
		if (!ValidatedOpts.Has("language") and IsSet(_I18nLocale) and _I18nLocale != "")
			_LLM_Engine["language"] := _I18nLocale

		; Arrays require explicit type validation before replacing live state.
		for Key in ["user_profiles", "disabled_apps", "api_entries",
			"app_profile_overrides"]
			if ValidatedOpts.Has(Key)
				_LLM_Engine[Key] := ValidatedOpts[Key]

		; A semantic change owns the same invalidation transaction regardless of
		; which tray setter or editor produced it. Display-only updates compare
		; equal and therefore retain both the cache and current callbacks.
		_LLM_Engine_RefreshSemanticConfig()
	} finally {
		Critical(PreviousCritical)
	}
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




#Include prediction_keylogger.ahk
#Include prediction_exec.ahk
