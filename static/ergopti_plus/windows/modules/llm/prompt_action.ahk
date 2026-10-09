; modules/llm/prompt_action.ahk

; ==============================================================================
; MODULE: Prompt Action Parameter (AHK)
; DESCRIPTION:
; AutoHotkey port of _shared/lua/llm/prompt_action.lua. Encodes and decodes
; the per-binding parameter of the "llm_prompt_prediction" action: which prompt
; profile to run and how many predictions to request.
;
; FEATURES & RATIONALE:
; 1. A binding stores one string, so the value is "<profile_id>" (use the AI
;    menu's prediction count) or "<profile_id>|<count>" (a count of its own).
; 2. Only the syntax is validated here. Whether the profile still exists is a
;    run-time question: deleting a custom prompt must not silently wipe the
;    bindings that name it when the configuration is next loaded.
; 3. Profile ids are the built-in ids and the generated custom ids
;    ("user_…", "custom_…"): ASCII letters, digits, "_" and "-" only, so "|"
;    can never be part of an id.
;
; Pinned with the Lua module and the action picker page by
; _shared/tests/corpus/action_parameters/llm_prompt_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Module Constants =========
; =====================================
; =====================================

; Separator between the profile id and the prediction count
global LLM_PROMPT_ACTION_SEPARATOR := "|"

; Bounds of a binding's own prediction count, those of the AI menu's setting
global LLM_PROMPT_ACTION_MIN_PREDICTIONS := 1
global LLM_PROMPT_ACTION_MAX_PREDICTIONS := 10

; Longest accepted profile id; generated custom ids stay well below it
global LLM_PROMPT_ACTION_MAX_ID_LENGTH := 128





; ================================
; ================================
; ======= 2/ Public API ==========
; ================================
; ================================

/**
 * Parses a binding value. \z anchors the patterns at the very end: PCRE's $
 * would also accept a trailing line break the Lua pattern refuses.
 * @param {String} Value The stored parameter.
 * @param {VarRef} Reason Receives why the value is invalid ("" when valid).
 * @returns {Map|Integer} Map("profile_id", Id) plus "num_predictions" when the
 *     binding has a count of its own (absent = the menu setting), or false.
 */
LLM_PromptAction_Parse(Value, &Reason := "") {
	global LLM_PROMPT_ACTION_SEPARATOR, LLM_PROMPT_ACTION_MAX_ID_LENGTH
	global LLM_PROMPT_ACTION_MIN_PREDICTIONS, LLM_PROMPT_ACTION_MAX_PREDICTIONS
	Reason := ""
	if !(Value is String) {
		Reason := "not a string"
		return false
	}
	SeparatorAt := InStr(Value, LLM_PROMPT_ACTION_SEPARATOR, true)
	ProfileId := SeparatorAt ? SubStr(Value, 1, SeparatorAt - 1) : Value
	if (ProfileId == "") {
		Reason := "empty profile id"
		return false
	}
	if (StrLen(ProfileId) > LLM_PROMPT_ACTION_MAX_ID_LENGTH) {
		Reason := "profile id too long"
		return false
	}
	if !RegExMatch(ProfileId, "^[A-Za-z0-9_\-]+\z") {
		Reason := "invalid profile id"
		return false
	}
	if !SeparatorAt
		return Map("profile_id", ProfileId)
	Count := SubStr(Value, SeparatorAt + 1)
	TranslationTarget := ""
	TargetAt := InStr(Count, LLM_PROMPT_ACTION_SEPARATOR, true)
	if TargetAt {
		TranslationTarget := SubStr(Count, TargetAt + 1)
		Count := SubStr(Count, 1, TargetAt - 1)
		if (!(ProfileId == "translate") || !LLM_Translate_IsLanguageText(TranslationTarget)) {
			Reason := "invalid translation target"
			return false
		}
	}
	if !RegExMatch(Count, "^[0-9]+\z") {
		Reason := "invalid prediction count"
		return false
	}
	; Leading zeros are digits like any other ("03" is 3). Past two significant
	; digits the count is out of range whatever it is, and Integer() is never
	; asked to convert a string too long for a 64-bit integer.
	Significant := LTrim(Count, "0")
	if (StrLen(Significant) > 2) {
		Reason := "prediction count out of range"
		return false
	}
	Predictions := (Significant == "") ? 0 : Integer(Significant)
	if (Predictions < LLM_PROMPT_ACTION_MIN_PREDICTIONS
			|| Predictions > LLM_PROMPT_ACTION_MAX_PREDICTIONS) {
		Reason := "prediction count out of range"
		return false
	}
	Parsed := Map("profile_id", ProfileId, "num_predictions", Predictions)
	if TargetAt
		Parsed["translation_target"] := TranslationTarget
	return Parsed
}

/**
 * Tells whether a binding value is syntactically valid.
 * @param {String} Value The stored parameter.
 * @returns {Integer} True when LLM_PromptAction_Parse accepts it.
 */
LLM_PromptAction_IsValid(Value) {
	return LLM_PromptAction_Parse(Value) is Map
}

/**
 * Builds a binding value; throws when the result would not parse.
 * @param {String} ProfileId A valid profile id.
 * @param {Integer} NumPredictions A count of its own, or 0 for the menu setting.
 * @returns {String} The encoded parameter.
 */
LLM_PromptAction_Format(ProfileId, NumPredictions := 0, TranslationTarget := "") {
	global LLM_PROMPT_ACTION_SEPARATOR
	Value := (NumPredictions == 0) ? ProfileId
		: ProfileId . LLM_PROMPT_ACTION_SEPARATOR . NumPredictions
	if (TranslationTarget != "")
		Value .= LLM_PROMPT_ACTION_SEPARATOR . TranslationTarget
	if !(LLM_PromptAction_Parse(Value, &Reason) is Map)
		throw ValueError("LLM_PromptAction_Format: " . Reason . ".")
	return Value
}
