; static/ergopti_plus/windows/tests/unit/test_llm_generate_prediction_feedback.ahk

; ==============================================================================
; MODULE: Regression — a manual prediction request says why it did nothing
;         (llm-manual-prediction-feedback)
; DESCRIPTION:
; LLM_Menu_TriggerPrediction is what a "generate a prediction" binding runs.
; It returned without a word when the script was paused, when the AI was off,
; when the backend was not ready, and when there was no typed context (the
; bridge buffer is cleared on every caret, focus or pointer move). A user who
; pressed the chord saw nothing happen and found nothing in the log.
;
; ROOT CAUSE ENCODED: every refusal now logs INFO with its reason and asks the
; tooltip layer for a localized notice. The notice is observed through the real
; tooltip core: TooltipShow publishes a pending request before its debounced
; render, and each case cancels it with a forced TooltipHide before any Gui is
; built. A pause cannot be simulated (A_IsSuspended is read-only), so its
; reason is checked through the pure decision function the trigger uses.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ Shared fixture =======
; =================================
; =================================

; A menu state with a resolvable API entry, so the real readiness predicate
; answers true without any dependency probe.
_LMPF_Menu(Enabled := true, Backend := "api") {
	return Map(
		"backend", Backend,
		"enabled", Enabled,
		"api_entry_id", "remote-a",
		"api_entries", (Backend == "api") ? [Map(
			"Id", "remote-a",
			"Provider", "openai",
			"BaseUrl", "https://example.invalid/v1",
			"Token", "secret",
			"Model", "model-a")] : [],
		"model", "local-a",
		"ctx_chars", 10,
		"bootstrap_pending", false)
}

; Runs Body with the menu state, the bridge buffer and a log capture in place,
; then restores all three and cancels any tooltip request the body left pending.
; @param {Map} Menu The _LLM_Menu to install.
; @param {String} Buffer The bridge buffer to install.
; @param {Func} Body Called with the captured log lines (Array).
_LMPF_Run(Menu, Buffer, Body) {
	global _LLM_Menu, _LLM_Bridge_Buffer, _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED
	SavedMenu := _LLM_Menu
	SavedBuffer := _LLM_Bridge_Buffer
	SavedSink := _LOGGER_TEST_SINK
	SavedInfo := _LOGGER_INFO_ENABLED
	Captured := []
	; Observe the published notice and retire it before its next-turn renderer.
	PreviousCritical := Critical("On")
	try {
		_LLM_Menu := Menu
		_LLM_Bridge_Buffer := Buffer
		_LOGGER_INFO_ENABLED := true
		LoggerSetTestSink((Line) => Captured.Push(Line))
		Body(Captured)
	} finally {
		TooltipHide("ManualPredictionTest", true)
		_LOGGER_TEST_SINK := SavedSink
		_LOGGER_INFO_ENABLED := SavedInfo
		_LLM_Menu := SavedMenu
		_LLM_Bridge_Buffer := SavedBuffer
		Critical(PreviousCritical)
	}
}

; The INFO lines that name a refusal reason.
; @param {Array} Lines Captured log lines.
; @param {String} Reason The reason id.
; @returns {Integer} How many INFO lines name it.
_LMPF_InfoLinesFor(Lines, Reason) {
	Count := 0
	for _, Line in Lines {
		if InStr(Line, "[INFO]") && InStr(Line, "Manual prediction refused")
				&& InStr(Line, "(" . Reason . ")")
			Count += 1
	}
	return Count
}

; The text of the tooltip request TooltipShow published, or "" when none.
; @returns {String}
_LMPF_PendingTooltipText() {
	global _TooltipPendingRequest
	if !IsObject(_TooltipPendingRequest)
		return ""
	Items := _TooltipPendingRequest.Items
	if (Items is Array)
		Items := Items.Length ? Items[1] : ""
	return (IsObject(Items) && Items.HasOwnProp("Text")) ? Items.Text : ""
}





; =======================================
; =======================================
; ======= 2/ Every refusal speaks =======
; =======================================
; =======================================

_LMPF_DisabledRefusalIsLoggedAndShown() {
	_LMPF_Run(_LMPF_Menu(false), "hello world", _Body)
	_Body(Lines) {
		Result := LLM_Menu_TriggerPrediction()
		AssertEqual(1, _LMPF_InfoLinesFor(Lines, "disabled"),
			"an AI switched off must be logged at INFO with its reason, not skipped silently")
		AssertEqual(t("llm.manual_prediction.disabled"), _LMPF_PendingTooltipText(),
			"the user must see why the chord did nothing")
		AssertFalse(Result, "a refused request must report that no prediction started")
	}
}
Test("LLM manual prediction: AI off is logged and shown (llm-manual-prediction-feedback)",
	_LMPF_DisabledRefusalIsLoggedAndShown)

_LMPF_BackendRefusalIsLoggedAndShown() {
	Menu := _LMPF_Menu(true)
	Menu["api_entries"] := []
	_LMPF_Run(Menu, "hello world", _Body)
	_Body(Lines) {
		Result := LLM_Menu_TriggerPrediction()
		AssertEqual(1, _LMPF_InfoLinesFor(Lines, "backend_not_ready"),
			"an unusable backend must be logged at INFO with its reason")
		AssertEqual(t("llm.manual_prediction.backend_not_ready"), _LMPF_PendingTooltipText(),
			"the user must see that the model is not ready")
		AssertFalse(Result, "a refused request must report that no prediction started")
	}
}
Test("LLM manual prediction: an unready backend is logged and shown (llm-manual-prediction-feedback)",
	_LMPF_BackendRefusalIsLoggedAndShown)

_LMPF_EmptyContextRefusalIsLoggedAndShown() {
	_LMPF_Run(_LMPF_Menu(true), "", _Body)
	_Body(Lines) {
		Result := LLM_Menu_TriggerPrediction()
		AssertEqual(1, _LMPF_InfoLinesFor(Lines, "empty_context"),
			"a buffer cleared by a caret move must be logged at INFO with its reason")
		AssertEqual(t("llm.manual_prediction.empty_context"), _LMPF_PendingTooltipText(),
			"the user must see that there is nothing to complete yet")
		AssertFalse(Result, "a refused request must report that no prediction started")
	}
}
Test("LLM manual prediction: an empty context is logged and shown (llm-manual-prediction-feedback)",
	_LMPF_EmptyContextRefusalIsLoggedAndShown)

_LMPF_ReadyRequestFiresTheTail() {
	_LMPF_Run(_LMPF_Menu(true), "0123456789abcdefghij", _Body)
	_Body(Lines) {
		Fired := []
		Result := LLM_Menu_TriggerPrediction((Ctx) => Fired.Push(Ctx))
		AssertTrue(Result, "a ready request must report that a prediction started")
		AssertEqual(1, Fired.Length, "a ready request must reach the engine exactly once")
		AssertEqual("abcdefghij", Fired[1],
			"the engine must receive the last ctx_chars characters of the buffer")
		AssertEqual("", _LMPF_PendingTooltipText(),
			"an accepted request must not show a refusal notice")
		Requested := 0
		for _, Line in Lines
			if InStr(Line, "[INFO]") && InStr(Line, "Manual prediction requested")
				Requested += 1
		AssertEqual(1, Requested, "an accepted request must be logged at INFO too")
	}
}
Test("LLM manual prediction: a ready request fires the buffer tail (llm-manual-prediction-feedback)",
	_LMPF_ReadyRequestFiresTheTail)

_LMPF_RefusalOrderAndKeys() {
	global LLM_MANUAL_PREDICTION_REFUSALS
	AssertEqual("paused", LLM_Menu_ManualPredictionRefusal(true, false, false, ""),
		"a pause outranks every other reason: nothing else may run while paused")
	AssertEqual("disabled", LLM_Menu_ManualPredictionRefusal(false, false, false, ""),
		"an AI switched off outranks an unready backend")
	AssertEqual("backend_not_ready", LLM_Menu_ManualPredictionRefusal(false, true, false, ""),
		"an unready backend outranks an empty context")
	AssertEqual("empty_context", LLM_Menu_ManualPredictionRefusal(false, true, true, ""),
		"an empty context is refused")
	AssertEqual("", LLM_Menu_ManualPredictionRefusal(false, true, true, "abc"),
		"a ready request with context is not refused")
	Checked := 0
	for Reason, Key in LLM_MANUAL_PREDICTION_REFUSALS {
		Assert(t(Key) != Key, "the notice for '" . Reason . "' must be translated (" . Key . ")")
		Checked += 1
	}
	AssertEqual(4, Checked, "the four refusal reasons must each own a notice")
}
Test("LLM manual prediction: refusal order and notice keys (llm-manual-prediction-feedback)",
	_LMPF_RefusalOrderAndKeys)

_LMPF_ActionRunsTheManualTrigger() {
	global GESTURE_ACTIONS
	Assert(GESTURE_ACTIONS.Has("llm_generate_prediction"),
		"the catalogue action must be registered in the gesture registry")
	_LMPF_Run(_LMPF_Menu(false), "hello world", _Body)
	_Body(Lines) {
		; Dispatched the way a binding dispatches it: with its binding id.
		GESTURE_ACTIONS["llm_generate_prediction"].Fn.Call("keyboard__win_space")
		AssertEqual(1, _LMPF_InfoLinesFor(Lines, "disabled"),
			"a bound gesture or keyboard slot must reach the manual trigger and its feedback")
		AssertEqual(t("llm.manual_prediction.disabled"), _LMPF_PendingTooltipText(),
			"the action must show the same notice as the trigger")
	}
}
Test("LLM manual prediction: the llm_generate_prediction action runs the trigger (llm-manual-prediction-feedback)",
	_LMPF_ActionRunsTheManualTrigger)
