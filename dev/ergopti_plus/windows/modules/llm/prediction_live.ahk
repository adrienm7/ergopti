; modules/llm/prediction_live.ahk

; ==============================================================================
; MODULE: LLM Prediction Engine — Live Mode
; DESCRIPTION:
; Owns live mode, turned on and off by the llm_live_prompt_toggle action and
; the AI menu: while it is on, the automatic typing trigger asks for
; predictions with the prompt and count live mode was started with, after the
; debounce and with the minimum word count of _shared/modules/llm/live.json.
;
; FEATURES & RATIONALE:
; 1. One pipeline: live mode only redirects the automatic trigger through the
;    prompt-override request path. Leaving it restores the ordinary trigger.
; 2. The menu's active profile and settings are never changed.
; 3. Not persisted: live mode is off at every start, and pausing or turning the
;    AI off turns it off.
;
; Included by modules/llm/prediction_engine.ahk after the execution section.
; ==============================================================================





; ==================================
; ==================================
; ======= 1/ Live Mode State =======
; ==================================
; ==================================

; The prompt and count live mode runs while it is on. Never persisted.
global _LLM_Live := Map("active", false, "profile_id", "", "num_predictions", 0)

/**
 * Returns the decoded, validated live.json, read on first use.
 * @returns {Map} Map("debounce_ms", Ms, "min_words", Words).
 */
LLM_Live_Config() {
	global _SharedDir
	static Config := ""
	if (Config is Map)
		return Config
	Path := _SharedDir . "\modules\llm\live.json"
	Candidate := JsonParse(FSReadStrict(Path))
	_LLM_Live_ValidateConfig(Candidate, Path)
	Config := Map("debounce_ms", Candidate["debounce_ms"],
		"min_words", Candidate["min_words"])
	return Config
}

; Throws unless Candidate holds a debounce the timer accepts and a word floor.
; @param {Map} Candidate The decoded file.
; @param {String} Path Its path, for the error.
_LLM_Live_ValidateConfig(Candidate, Path) {
	if !(Candidate is Map)
		throw ValueError(Path . ": the root must be an object.")
	; The same bounds as the menu's debounce: the timer period rule is shared
	if !(Candidate.Get("debounce_ms", "") is Integer)
			|| !LLM_Option_TryNormalize("debounce_ms", Candidate["debounce_ms"], &Normalized)
		throw ValueError(Path . ": debounce_ms must be an integer the debounce setting accepts.")
	if !(Candidate.Get("min_words", "") is Integer) || Candidate["min_words"] < 0
		throw ValueError(Path . ": min_words must be a non-negative integer.")
}





; ==============================
; ==============================
; ======= 2/ Transitions =======
; ==============================
; ==============================

/**
 * Tells whether live mode is on.
 * @returns {Integer} True while live mode is on.
 */
LLM_Engine_LiveIsActive() {
	global _LLM_Live
	return _LLM_Live["active"] ? true : false
}

/**
 * The prompt override the automatic trigger arms while live mode is on.
 * @returns {Map|Integer} Map("profile_id", Id, "num_predictions", Count,
 *     "live", true), or 0 when live mode is off.
 */
LLM_Engine_LiveOverride() {
	global _LLM_Live
	if !_LLM_Live["active"]
		return 0
	Override := Map("profile_id", _LLM_Live["profile_id"],
		"num_predictions", _LLM_Live["num_predictions"], "live", true)
	if _LLM_Live.Has("translation_target")
		Override["translation_target"] := _LLM_Live["translation_target"]
	return Override
}

/**
 * The debounce of the automatic trigger: live.json's while live mode is on,
 * the menu's otherwise.
 * @returns {Integer} Milliseconds.
 */
LLM_Engine_LiveDebounceMs() {
	global _LLM_Engine
	return LLM_Engine_LiveIsActive() ? LLM_Live_Config()["debounce_ms"]
		: _LLM_Engine["debounce_ms"]
}

/**
 * Turns live mode on with a prompt, or moves it to another one. The caller
 * has checked that the prompt exists and that the AI can run.
 * @param {String} ProfileId The prompt to run.
 * @param {Integer} NumPredictions A count of its own, 0 for the menu's.
 */
LLM_Engine_LiveStart(ProfileId, NumPredictions := 0, TranslationTarget := "") {
	global _LLM_Live
	; Throws on a caller bug before anything changes
	Override := Map("profile_id", ProfileId, "num_predictions", NumPredictions)
	if (TranslationTarget != "")
		Override["translation_target"] := TranslationTarget
	Checked := _LLM_Engine_NormalizePromptOverride(Override)
	Config := LLM_Live_Config()
	WasActive := _LLM_Live["active"]
	; A debounce armed by the last keystroke holds the previous prompt
	LLM_Engine_CancelTimer()
	_LLM_Live["profile_id"] := Checked["profile_id"]
	_LLM_Live["num_predictions"] := Checked["num_predictions"]
	if _LLM_Live.Has("translation_target")
		_LLM_Live.Delete("translation_target")
	if Checked.Has("translation_target")
		_LLM_Live["translation_target"] := Checked["translation_target"]
	_LLM_Live["active"] := true
	LoggerInfo("LLM", "Live mode {1} with '{2}' ({3} prediction(s), {4} ms debounce, {5} minimum word(s)).",
		WasActive ? "moved" : "on", Checked["profile_id"],
		Checked["num_predictions"] > 0 ? Checked["num_predictions"] : "the menu's",
		Config["debounce_ms"], Config["min_words"])
}

/**
 * Turns live mode off and retires the live request armed or in flight.
 * @param {String} Reason Why, for the log.
 * @returns {Integer} True when live mode was on.
 */
LLM_Engine_LiveStop(Reason) {
	global _LLM_Live
	if !_LLM_Live["active"]
		return false
	if _LLM_Live.Has("translation_target")
		_LLM_Live.Delete("translation_target")
	_LLM_Live["active"] := false
	_LLM_Live["profile_id"] := ""
	_LLM_Live["num_predictions"] := 0
	LLM_Engine_CancelTimer()
	LLM_Engine_CancelInflight()
	LoggerInfo("LLM", "Live mode off ({1}).", Reason)
	return true
}

/**
 * Tells whether a request is a live one, from the override it recorded.
 * @param {Integer} RequestId The request.
 * @returns {Integer} True when that request runs live mode's prompt.
 */
_LLM_Engine_RequestIsLive(RequestId) {
	global _LLM_Engine
	Override := _LLM_Engine.Get("request_prompt_override", "")
	return (Override is Map && Override["request_id"] == RequestId
		&& Override.Get("live", false)) ? true : false
}

/**
 * Tells whether a hotstring preview or candidate tooltip is on screen. A live
 * prediction waits for it to go: LLM_Bridge_ScheduleAfterHotstring re-arms it.
 * @returns {Integer} True while a hotstring tooltip is shown.
 */
_LLM_Engine_HotstringTooltipShown() {
	return IsSet(TooltipIsVisible) && TooltipIsVisible()
}
