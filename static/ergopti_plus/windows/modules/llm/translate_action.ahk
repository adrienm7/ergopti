; modules/llm/translate_action.ahk

; ==============================================================================
; MODULE: Selection Translation Action (AHK)
; DESCRIPTION:
; Runs the llm_translate_selection action: the selected text is translated by
; the AI menu's current text backend (modules/llm/translate.ahk) and offered
; as the prediction tooltip's one candidate. Accepting it replaces the
; selection with the translation, left selected; Escape, a dismissal or typing
; leaves the text untouched.
;
; FEATURES & RATIONALE:
; 1. The refusals of the manual prediction trigger (paused, AI off, backend not
;    ready) come first, then the binding: nothing is read for a request that
;    cannot run.
; 2. The selection is read like the tone ladder reads it (LLM_SelectionReader:
;    clipboard copy with restore). Nothing selected shows a notice.
; 3. One chat request to the AI menu's backend, through the screen answers'
;    sender (LLM_Vision_SendText): no PREFIX/TAIL, streaming off.
; 4. The translation is a tooltip candidate, accepted by the usual Tab path:
;    typed over the selection, it replaces it, then the typed text is selected
;    again (the slot's SelectAfterAccept, honoured by the bridge).
; 5. One translation at a time: each trigger takes a generation, and a
;    selection or an answer carrying an older one is dropped.
;
; Neither the selection nor the translation is ever logged: only their sizes.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================
; ===============================
; ======= 1/ Module State =======
; ===============================
; ===============================

; The context handed to the manual-prediction refusals before the selection is
; read: the selection is what gets translated, and its emptiness has a notice
; of its own
global LLM_TRANSLATE_REFUSAL_CONTEXT := "selection"

; The Lua %s class, as a PCRE character class: a selection of only these is empty
global LLM_TRANSLATE_BLANK_PATTERN := "^[ \t\n\x0B\f\r]*\z"

; Generation of the newest translation; a callback carrying an older one is stale
global _LLM_Translate_Generation := 0

; Test seam, 0 in production: () => Map("hwnd", "control"), the control an
; accept targets
global _LLM_Translate_SourceProbe := 0





; =============================
; =============================
; ======= 2/ Public API =======
; =============================
; =============================

/**
 * Runs one translation of the selection. The selection and the answer arrive
 * asynchronously; this call applies the refusals, supersedes any translation
 * in progress and starts reading the selection.
 * @param {String} Value The binding's llm_language parameter.
 * @returns {Boolean} True when the selection capture started.
 */
LLM_Translate_Trigger(Value) {
	global _LLM_Menu, _LLM_Translate_Generation, LLM_TRANSLATE_REFUSAL_CONTEXT
	Enabled := _LLM_Menu.Get("enabled", false)
	Refusal := LLM_Menu_ManualPredictionRefusal(A_IsSuspended, Enabled,
		Enabled && _LLM_Menu_BackendIsReadyForUse(), LLM_TRANSLATE_REFUSAL_CONTEXT)
	if (Refusal != "") {
		_LLM_Menu_ShowManualPredictionRefusal(Refusal, 0)
		return false
	}
	Config := LLM_Translate_Config()
	Names := LLM_Translate_LocaleNames()
	Target := LLM_Translate_Parse(Value, Config, Names)
	if (Target == "") {
		LoggerWarn("LLM", "Translation ignored: the binding's language parameter is invalid.")
		return false
	}
	Locale := LLM_Translate_TargetLocale(Target, Config, I18nGetLocale())
	Language := LLM_Translate_ResolveLanguage(Target, Config, Names, I18nGetLocale())
	if (Language == "") {
		LoggerError("LLM", "Translation refused: the locale '{1}' has no name in locale_names.json.", Locale)
		_LLM_Menu_ShowManualPredictionNotice("llm.translate.failed")
		return false
	}
	; The selection would leave an app the user excluded from the AI
	if _LLM_Engine_ShouldSuppressForDisabledApps() {
		LoggerInfo("LLM", "Translation refused: the focused app is excluded from the AI.")
		return false
	}
	_LLM_Translate_Generation += 1
	Flow := Map(
		"generation", _LLM_Translate_Generation,
		"locale", Locale,
		"language", Language,
		"config", Config
	)
	if !LLM_SelectionReader().Call(_LLM_Translate_OnSelection.Bind(Flow)) {
		LoggerInfo("LLM", "Translation #{1} skipped: the selection could not be read (paused or clipboard busy).",
			Flow["generation"])
		return false
	}
	return true
}





; =====================================
; =====================================
; ======= 3/ Request and Answer =======
; =====================================
; =====================================

; The selection arrived: send it, or say that nothing is selected.
; @param {Map} Flow The translation.
; @param {String} Text The selected text ("" when nothing is selected).
_LLM_Translate_OnSelection(Flow, Text) {
	global LLM_TRANSLATE_BLANK_PATTERN
	if !_LLM_Translate_IsCurrent(Flow) {
		LoggerInfo("LLM", "Translation #{1} dropped: a newer one superseded it before the selection arrived.",
			Flow["generation"])
		return
	}
	if A_IsSuspended {
		LoggerInfo("LLM", "Translation #{1} dropped: the driver is paused.", Flow["generation"])
		return
	}
	if !(Text is String) || Text == "" || RegExMatch(Text, LLM_TRANSLATE_BLANK_PATTERN) {
		LoggerInfo("LLM", "Translation #{1} skipped: nothing is selected.", Flow["generation"])
		_LLM_Menu_ShowManualPredictionNotice("llm.translate.no_selection")
		return
	}
	Config := Flow["config"]
	; The size of the selection, never its content: it is the user's own text
	LoggerStart("LLM", "Translation #{1}: {2} character(s) into '{3}'.",
		Flow["generation"], StrLen(Text), Flow["locale"])
	if !LLM_Vision_SendText(LLM_Translate_SystemPrompt(Config, Flow["language"]),
			LLM_Translate_UserText(Config, Text), Config["max_tokens"],
			_LLM_Translate_OnAnswer.Bind(Flow), _LLM_Translate_OnFail.Bind(Flow)) {
		LoggerWarn("LLM", "Translation #{1} failed: the API backend has no entry configured.", Flow["generation"])
		_LLM_Menu_ShowManualPredictionNotice("llm.translate.failed")
	}
}

; The model answered: offer the translation.
; @param {Map} Flow The translation.
; @param {String} Raw The model's answer.
; @param {Map} Meta Usage metadata (remote backend), unused.
_LLM_Translate_OnAnswer(Flow, Raw, Meta := "") {
	if !_LLM_Translate_IsCurrent(Flow) {
		LoggerInfo("LLM", "Translation #{1}: answer ignored, a newer translation superseded it.",
			Flow["generation"])
		return
	}
	if A_IsSuspended {
		LoggerInfo("LLM", "Translation #{1} dropped: the driver is paused.", Flow["generation"])
		return
	}
	Text := LLM_Translate_Extract(Flow["config"], Raw)
	if (Text == "") {
		LoggerWarn("LLM", "Translation #{1} failed: the answer holds no translation ({2} character(s)).",
			Flow["generation"], (Raw is String) ? StrLen(Raw) : 0)
		_LLM_Menu_ShowManualPredictionNotice("llm.translate.failed")
		return
	}
	_LLM_Translate_Show(Flow, Text)
	LoggerSuccess("LLM", "Translation #{1}: offered ({2} character(s)).", Flow["generation"], StrLen(Text))
}

; The request failed: nothing is offered.
; @param {Map} Flow The translation.
; @param {Map} Failure Failure details, when the backend gives them.
_LLM_Translate_OnFail(Flow, Failure := "") {
	if !_LLM_Translate_IsCurrent(Flow) {
		LoggerInfo("LLM", "Translation #{1}: failure ignored, a newer translation superseded it.",
			Flow["generation"])
		return
	}
	LoggerWarn("LLM", "Translation #{1} failed: the request failed ({2}).",
		Flow["generation"], _LLM_Vision_FailureReason(Failure))
	_LLM_Menu_ShowManualPredictionNotice("llm.translate.failed")
}





; ============================
; ============================
; ======= 4/ Candidate =======
; ============================
; ============================

; Publishes the translation as the tooltip's one candidate. Accepting it types
; it over the selection, which it replaces, then selects it again.
; @param {Map} Flow The translation.
; @param {String} Text The translation.
_LLM_Translate_Show(Flow, Text) {
	global _LLM_Translate_SourceProbe
	Source := HasMethod(_LLM_Translate_SourceProbe, "Call")
		? _LLM_Translate_SourceProbe.Call() : _LLM_Engine_CaptureAcceptSource()
	Meta := Map(
		"offer_id", "translate_" . Flow["generation"],
		"accept_source", Source,
		"app_name", _LLM_Engine_AppNameForAcceptSource(Source),
		"is_final", true,
		"render_guard", _LLM_Translate_RenderIsCurrent.Bind(Flow["generation"])
	)
	LLM_Tooltip_Show([{ Text: Text, SelectAfterAccept: true }], 1, true, Meta)
}

; @param {Map} Flow The translation.
; @returns {Boolean} True when no newer translation started.
_LLM_Translate_IsCurrent(Flow) {
	global _LLM_Translate_Generation
	return Flow["generation"] == _LLM_Translate_Generation
}

; Render guard of the candidate: a strict Boolean the tooltip checks before
; painting.
; @param {Integer} Generation The translation's generation.
; @returns {Integer}
_LLM_Translate_RenderIsCurrent(Generation) {
	global _LLM_Translate_Generation
	return (Generation == _LLM_Translate_Generation && !A_IsSuspended) ? true : false
}
