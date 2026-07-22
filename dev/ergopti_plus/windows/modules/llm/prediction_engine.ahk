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
; which reads from LLM_Defaults (lib/llm_defaults.ahk → _shared/modules/llm/defaults.json).
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
	global _LLM_Engine, _I18nLocale
	; Stop any in-flight generation when the backend changes so a WinHTTP
	; response from the old provider cannot land into the new backend's context.
	if (IsSet(_LLM_Engine) and _LLM_Engine.Has("backend") and opts.Has("backend") and _LLM_Engine["backend"] != opts["backend"]) {
		try LLM_Engine_StopGeneration()
		if IsSet(_LLM_Engine)
			_LLM_Engine["last_request_tick"] := 0
	}
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

	; The prediction language follows the active UI locale (the i18n single source
	; of truth, lib/i18n.ahk) instead of a hardcoded "fr", so a user typing in their
	; own language gets predictions in it. An explicit opts["language"] still wins.
	if (!opts.Has("language") and IsSet(_I18nLocale) and _I18nLocale != "")
		_LLM_Engine["language"] := _I18nLocale

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




#Include prediction_keylogger.ahk
#Include prediction_exec.ahk
