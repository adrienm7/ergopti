; modules/llm/prediction_live.ahk

; ==============================================================================
; MODULE: LLM Prediction Engine — Live Mode
; DESCRIPTION:
; Owns live mode, turned on and off by the llm_live_prompt_toggle action and
; the AI menu: while it is on, the automatic typing trigger asks for
; predictions with the prompt and count live mode was started with, after the
; debounce and with the minimum word count of _shared/ai/data/live.json.
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

#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk





; ==================================
; ==================================
; ======= 1/ Live Mode State =======
; ==================================
; ==================================

; The prompt and count live mode runs while it is on. Never persisted.
global _LLM_Live := Map("active", false, "profile_id", "", ConfigLeaf.NUM_PREDICTIONS, 0)

/**
 * Returns the decoded, validated live.json, read on first use.
 * @returns {Map} Map("debounce_ms", Ms, ConfigLeaf.MIN_WORDS, Words).
 */
LLM_Live_Config() {
	global _SharedDir
	static Config := ""
	if (Config is Map)
		return Config
	Path := _SharedDir . "\ai\data\live.json"
	Candidate := JsonParse(FSReadStrict(Path))
	_LLM_Live_ValidateConfig(Candidate, Path)
	Config := Map(ConfigLeaf.DEBOUNCE_MS, Candidate[ConfigLeaf.DEBOUNCE_MS],
		ConfigLeaf.MIN_WORDS, Candidate[ConfigLeaf.MIN_WORDS])
	return Config
}

; Throws unless Candidate holds a debounce the timer accepts and a word floor.
; @param {Map} Candidate The decoded file.
; @param {String} Path Its path, for the error.
_LLM_Live_ValidateConfig(Candidate, Path) {
	Reason := LLM_Live_ConfigRefusal(Candidate)
	if Reason != ""
		throw ValueError(Path . ": " . Reason . ".")
	; The same bounds as the menu's debounce: the timer period rule is shared
	if !LLM_Option_TryNormalize(ConfigLeaf.DEBOUNCE_MS, Candidate[ConfigLeaf.DEBOUNCE_MS], &Normalized)
		throw ValueError(Path . ": debounce_ms must be an integer the debounce setting accepts.")
}

/**
 * Why a decoded live.json is unusable: request_plan/live.lua `config`.
 * @param {Any} Decoded The decoded file.
 * @returns {String} The reason, "" when the file is usable.
 */
LLM_Live_ConfigRefusal(Decoded) {
	if !(Decoded is Map)
		return "live.json is missing or not JSON"
	if !(Decoded.Get(ConfigLeaf.DEBOUNCE_MS, "") is Integer) || Decoded[ConfigLeaf.DEBOUNCE_MS] < 0
		return "live.json debounce_ms is not a non-negative integer"
	if !(Decoded.Get(ConfigLeaf.MIN_WORDS, "") is Integer) || Decoded[ConfigLeaf.MIN_WORDS] < 0
		return "live.json min_words is not a non-negative integer"
	return ""
}

/**
 * What one live keystroke asks for: request_plan/live.lua `decide`. A deleted
 * prompt stops live mode: live typing never falls back to another prompt.
 * @param {Map} Config The validated live.json.
 * @param {Map} Receipt The prompt live mode started with: profile_id, and a
 *     num_predictions of its own when it has one.
 * @param {Integer} MenuCount The menu's prediction count.
 * @param {Map|Integer} Profile The prompt found now, 0 when it no longer exists.
 * @returns {Map} action "request" with num_predictions and min_words, or action
 *     "stop" with its cause.
 */
LLM_Live_Decide(Config, Receipt, MenuCount, Profile) {
	if !(Receipt.Get("profile_id", "") is String) || Receipt.Get("profile_id", "") == ""
		throw ValueError("receipt needs a profile_id")
	if !(MenuCount is Integer) || MenuCount < 1
		throw ValueError("menu_count must be a whole number from 1")
	Count := Receipt.Get(ConfigLeaf.NUM_PREDICTIONS, 0)
	if !(Count is Integer) || (Receipt.Has(ConfigLeaf.NUM_PREDICTIONS) && Count < 1)
		throw ValueError("receipt num_predictions must be a whole number from 1")
	if !(Profile is Map)
		return Map("action", "stop", "cause", "prompt deleted")
	return Map("action", "request", ConfigLeaf.NUM_PREDICTIONS, Count ? Count : MenuCount,
		ConfigLeaf.MIN_WORDS, Config[ConfigLeaf.MIN_WORDS])
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
		ConfigLeaf.NUM_PREDICTIONS, _LLM_Live[ConfigLeaf.NUM_PREDICTIONS], "live", true)
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
	return LLM_Engine_LiveIsActive() ? LLM_Live_Config()[ConfigLeaf.DEBOUNCE_MS]
		: _LLM_Engine[ConfigLeaf.DEBOUNCE_MS]
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
	Override := Map("profile_id", ProfileId, ConfigLeaf.NUM_PREDICTIONS, NumPredictions)
	if (TranslationTarget != "")
		Override["translation_target"] := TranslationTarget
	Checked := _LLM_Engine_NormalizePromptOverride(Override)
	Config := LLM_Live_Config()
	WasActive := _LLM_Live["active"]
	; A debounce armed by the last keystroke holds the previous prompt
	LLM_Engine_CancelTimer()
	_LLM_Live["profile_id"] := Checked["profile_id"]
	_LLM_Live[ConfigLeaf.NUM_PREDICTIONS] := Checked[ConfigLeaf.NUM_PREDICTIONS]
	if _LLM_Live.Has("translation_target")
		_LLM_Live.Delete("translation_target")
	if Checked.Has("translation_target")
		_LLM_Live["translation_target"] := Checked["translation_target"]
	_LLM_Live["active"] := true
	LoggerInfo("LLM", "Live mode {1} with '{2}' ({3} prediction(s), {4} ms debounce, {5} minimum word(s)).",
		WasActive ? "moved" : "on", Checked["profile_id"],
		Checked[ConfigLeaf.NUM_PREDICTIONS] > 0 ? Checked[ConfigLeaf.NUM_PREDICTIONS] : "the menu's",
		Config[ConfigLeaf.DEBOUNCE_MS], Config[ConfigLeaf.MIN_WORDS])
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
	_LLM_Live[ConfigLeaf.NUM_PREDICTIONS] := 0
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

/**
 * The llm.trigger.while_hotstring_tooltip choice the engine runs on: the value
 * LLM_Engine_Init published, the manifest default before the first one.
 * @returns {String} "wait" or "both".
 */
LLM_Engine_WhileHotstringTooltip() {
	global _LLM_Engine
	if (_LLM_Engine is Map) && _LLM_Engine.Has(ConfigLeaf.WHILE_HOTSTRING_TOOLTIP)
		return _LLM_Engine[ConfigLeaf.WHILE_HOTSTRING_TOOLTIP]
	return ManifestDefaultFor(ConfigKey.LLM_TRIGGER_WHILE_HOTSTRING_TOOLTIP)
}

/**
 * Tells whether a prediction must leave the shared surface to the hotstring
 * tooltip shown now. Covering it would retire a hotstring that can still
 * expand, so every request waits unless the user chose to see both; a live
 * request always waits, its tooltip following every keystroke. A prompt the
 * user asked for by name (a prompt action) is never held.
 * @param {Map|Integer} Override The request's prompt override, 0 for none.
 * @returns {Integer} True while the request must not paint.
 */
_LLM_Engine_HotstringTooltipHolds(Override) {
	global LLM_HOTSTRING_TOOLTIP_SHOW_BOTH
	IsLive := (Override is Map) && Override.Get("live", false)
	if (Override is Map) && !IsLive
		return false
	if !_LLM_Engine_HotstringTooltipShown()
		return false
	return IsLive || LLM_Engine_WhileHotstringTooltip() != LLM_HOTSTRING_TOOLTIP_SHOW_BOTH
}

/**
 * The same hold for a request already dispatched, from the override it recorded.
 * @param {Integer} RequestId The request.
 * @returns {Integer} True while that request must not paint.
 */
_LLM_Engine_RequestHeldByHotstring(RequestId) {
	global _LLM_Engine
	Override := _LLM_Engine.Get("request_prompt_override", "")
	Owned := (Override is Map) && Override["request_id"] == RequestId
	return _LLM_Engine_HotstringTooltipHolds(Owned ? Override : 0)
}
