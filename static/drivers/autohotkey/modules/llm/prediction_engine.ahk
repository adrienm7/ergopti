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

; Default state — overridden by LLM_Engine_Init()
global _LLM_Engine := {
	enabled:      false,
	model:        "qwen2.5:3b",
	profile_id:   "basic",
	n_predictions: 1,
	min_words:    2,
	max_words:    8,
	debounce_ms:  600,
	ctx_chars:    300,
	language:     "fr",
	timer_active: false,
	last_ctx:     "",
	last_result:  "",
}




; ====================================
; ====================================
; ======= 2/ Lifecycle =======
; ====================================
; ====================================

/**
 * Initialises the prediction engine with user settings.
 * Must be called before any other LLM_Engine_* function.
 * @param {Object} opts - Map/object with optional keys: model, profile_id,
 *   n_predictions, min_words, max_words, debounce_ms, ctx_chars, language.
 */
LLM_Engine_Init(opts) {
	global _LLM_Engine
	_LLM_Engine.enabled := true

	if opts.Has("model")
		_LLM_Engine.model         := opts["model"]
	if opts.Has("profile_id")
		_LLM_Engine.profile_id    := opts["profile_id"]
	if opts.Has("n_predictions")
		_LLM_Engine.n_predictions := opts["n_predictions"]
	if opts.Has("min_words")
		_LLM_Engine.min_words     := opts["min_words"]
	if opts.Has("max_words")
		_LLM_Engine.max_words     := opts["max_words"]
	if opts.Has("debounce_ms")
		_LLM_Engine.debounce_ms   := opts["debounce_ms"]
	if opts.Has("ctx_chars")
		_LLM_Engine.ctx_chars     := opts["ctx_chars"]
	if opts.Has("language")
		_LLM_Engine.language      := opts["language"]
}

/**
 * Enables or disables the prediction engine at runtime.
 * @param {boolean} state - True to enable, false to disable.
 */
LLM_Engine_SetEnabled(state) {
	global _LLM_Engine
	_LLM_Engine.enabled := state
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
	if !_LLM_Engine.enabled
		return

	LLM_Engine_CancelTimer()

	; Trim context to the last ctx_chars characters
	ctx := SubStr(buffer, -_LLM_Engine.ctx_chars)

	; Arm debounce timer — closure captures current ctx value
	_LLM_Engine.last_ctx := ctx
	SetTimer(() => LLM_Engine_FirePrediction(ctx), -_LLM_Engine.debounce_ms)
	_LLM_Engine.timer_active := true
}

/**
 * Cancels any pending debounce timer.
 */
LLM_Engine_CancelTimer() {
	global _LLM_Engine
	if _LLM_Engine.timer_active {
		SetTimer(, 0)   ; Cancel the most recently set one-shot timer
		_LLM_Engine.timer_active := false
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
	_LLM_Engine.timer_active := false

	if !_LLM_Engine.enabled || ctx == ""
		return

	; Cache hit: re-display last result without an API call
	if (ctx == _LLM_Engine.last_ctx && _LLM_Engine.last_result != "") {
		LLM_Engine_OnResult(_LLM_Engine.last_result, ctx)
		return
	}

	; Resolve profile and build the system prompt
	profile     := LLM_GetActiveProfile(_LLM_Engine.profile_id)
	system_prompt := LLM_ResolveSystemPrompt(
		profile,
		_LLM_Engine.n_predictions,
		_LLM_Engine.min_words,
		_LLM_Engine.max_words,
		_LLM_Engine.language
	)
	system_prompt := StrReplace(system_prompt, "{context}", ctx)

	; Resolve Ollama tag from display name
	model_tag := LLM_ResolveOllamaTag(_LLM_Engine.model)

	; Call the backend (synchronous — runs in same thread)
	result := LLM_OllamaGenerate(model_tag, system_prompt, ctx)
	if (result == "")
		return

	_LLM_Engine.last_ctx    := ctx
	_LLM_Engine.last_result := result

	LLM_Engine_OnResult(result, ctx)
}

/**
 * Callback invoked with the generated prediction text.
 * Override or extend this function to hook up the tooltip UI.
 * @param {string} text - Generated completion text.
 * @param {string} ctx - The context that produced this result.
 */
LLM_Engine_OnResult(text, ctx) {
	; Default: delegate to tooltip module (loaded by llm_bridge.ahk)
	LLM_Tooltip_Show(text)
}
