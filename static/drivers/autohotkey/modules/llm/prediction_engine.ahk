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
; ======================================
; ======= 1/ Engine Configuration =======
; ======================================
; ======================================

; Runtime state — populated at first LLM_Engine_Init() call from LLM_Defaults
; (loaded by lib/llm_defaults.ahk at boot) so all values come from the shared
; defaults.json rather than being hardcoded here.
; Timer/cache keys are always initialised to their zero values regardless.
global _LLM_Engine := Map(
	"enabled",                    false,
	"model",                      "qwen2.5:3b",
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
	"last_result",                ""
)

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
; ====================================
; ======= 2/ Lifecycle =======
; ====================================
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

	static _keys := ["model", "profile_id", "n_predictions", "min_words", "max_words",
		"debounce_ms", "ctx_chars", "language", "temperature",
		"instant_on_word_end", "after_hotstring", "reset_on_nav",
		"disable_url_bars", "disable_password_fields",
		"show_info_bar", "streaming", "show_all_at_once",
		"pred_indent", "auto_raise_temp", "nav_modifiers", "val_modifiers"]

	for k in _keys
		if opts.Has(k)
			_LLM_Engine[k] := opts[k]

	; Arrays require explicit copy to avoid shared references
	if opts.Has("user_profiles") && (opts["user_profiles"] is Array)
		_LLM_Engine["user_profiles"] := opts["user_profiles"]
	if opts.Has("disabled_apps") && (opts["disabled_apps"] is Array)
		_LLM_Engine["disabled_apps"] := opts["disabled_apps"]
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

	; Trim context to the last ctx_chars characters
	ctx := SubStr(buffer, -_LLM_Engine["ctx_chars"])

	; Arm debounce timer — closure captures current ctx value
	_LLM_Engine["last_ctx"] := ctx
	SetTimer(() => LLM_Engine_FirePrediction(ctx), -_LLM_Engine["debounce_ms"])
	_LLM_Engine["timer_active"] := true
}

/**
 * Cancels any pending debounce timer.
 */
LLM_Engine_CancelTimer() {
	global _LLM_Engine
	if _LLM_Engine["timer_active"] {
		SetTimer(, 0)
		_LLM_Engine["timer_active"] := false
	}
}




; ========================================
; ========================================
; ======= 4/ Prediction Execution =======
; ========================================
; ========================================

/**
 * Fires the actual LLM call after the debounce period expires.
 * Skips the call if context is identical to the last result's context.
 * @param {string} ctx - The context string captured at debounce arm time.
 */
LLM_Engine_FirePrediction(ctx) {
	global _LLM_Engine
	_LLM_Engine["timer_active"] := false

	if !_LLM_Engine["enabled"] || ctx == ""
		return

	; Cache hit: re-display last result without an API call
	if (ctx == _LLM_Engine["last_ctx"] && _LLM_Engine["last_result"] != "") {
		LLM_Engine_OnResult(_LLM_Engine["last_result"], ctx)
		return
	}

	; Resolve profile and build the system prompt
	profile       := LLM_GetActiveProfile(_LLM_Engine["profile_id"])
	system_prompt := LLM_ResolveSystemPrompt(
		profile,
		_LLM_Engine["n_predictions"],
		_LLM_Engine["min_words"],
		_LLM_Engine["max_words"],
		_LLM_Engine["language"]
	)
	system_prompt := StrReplace(system_prompt, "{context}", ctx)

	; Resolve Ollama tag from display name
	model_tag := LLM_ResolveOllamaTag(_LLM_Engine["model"])

	; Call the backend (synchronous — runs in same thread)
	result := LLM_OllamaGenerate(model_tag, system_prompt, ctx, Float(_LLM_Engine["temperature"]))
	if (result == "")
		return

	_LLM_Engine["last_ctx"]    := ctx
	_LLM_Engine["last_result"] := result

	LLM_Engine_OnResult(result, ctx)
}

/**
 * Callback invoked with the generated prediction text.
 * Override or extend this function to hook up the tooltip UI.
 * @param {string} text - Generated completion text.
 * @param {string} ctx - The context that produced this result.
 */
LLM_Engine_OnResult(text, ctx) {
	; Delegate to tooltip module (loaded by ErgoptiPlus.ahk before this file)
	LLM_Tooltip_Show(text)
}
