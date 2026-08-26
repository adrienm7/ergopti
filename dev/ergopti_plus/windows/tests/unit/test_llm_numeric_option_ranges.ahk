; tests/unit/test_llm_numeric_option_ranges.ahk

; ==============================================================================
; MODULE: LLM Numeric Option Range Tests
; DESCRIPTION:
; Proves that every public integer option owns one semantic range across direct
; normalization, persisted-menu restore, engine admission, and timer arming.
; ==============================================================================

#Requires AutoHotkey v2.0

_LNR_Ranges() {
	return Map(
		"n_predictions", Map("min", 1, "max", 10, "baseline", 3),
		"min_words", Map("min", 1, "max", 20, "baseline", 3),
		"max_words", Map("min", 0, "max", 10000, "baseline", 15),
		"debounce_ms", Map("min", 50, "max", 10000, "baseline", 500),
		"ctx_chars", Map("min", 50, "max", 10000, "baseline", 500),
		"pred_indent", Map("min", -7, "max", 7, "baseline", 0))
}

_LNR_InvalidValues(Key, Policy) {
	Values := [Policy["min"] - 1, Policy["max"] + 1]
	if (Policy["min"] > 0)
		Values.Push(0)
	else if (Key == "max_words")
		Values.Push(-1)
	return Values
}

_LNR_NormalizerOwnsEverySemanticRange() {
	for Key, Policy in _LNR_Ranges() {
		for Boundary in [Policy["min"], Policy["max"]] {
			Normalized := false
			AssertTrue(LLM_Option_TryNormalize(Key, Boundary, &Normalized),
				"(ahk2-06-numeric-option-ranges) valid boundary must normalize: "
				. Key . "=" . Boundary)
			AssertEqual(Boundary, Normalized)
		}
		for Bad in _LNR_InvalidValues(Key, Policy) {
			Normalized := "sentinel"
			AssertFalse(LLM_Option_TryNormalize(Key, Bad, &Normalized),
				"(ahk2-06-numeric-option-ranges) out-of-range value must fail: "
				. Key . "=" . Bad)
			AssertEqual(false, Normalized,
				"refusal must publish no normalized value")
		}
	}
}
Test("AHK2-06 numeric options: one normalizer owns every semantic range "
	. "(ahk2-06-numeric-option-ranges)",
	_LNR_NormalizerOwnsEverySemanticRange)

_LNR_RestoreRejectsEveryInvalidValue() {
	global _LLM_Menu, _LLM_Menu_Loaded
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	try {
		for Key, Policy in _LNR_Ranges() {
			for Bad in _LNR_InvalidValues(Key, Policy) {
				_LLM_Menu := LLM_Menu_DeepClone(SavedMenu)
				_LLM_Menu[Key] := Policy["baseline"]
				_LLM_Menu_Loaded := false
				AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(Map(Key, Bad)))
				AssertEqual(Policy["baseline"], _LLM_Menu[Key],
					"(ahk2-06-numeric-option-ranges) restore must retain the validated value: "
					. Key . "=" . Bad)
			}
		}
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
	}
}
Test("AHK2-06 numeric options: persisted invalid values never publish "
	. "(ahk2-06-numeric-option-ranges)",
	_LNR_RestoreRejectsEveryInvalidValue)

_LNR_BoundariesPublishThroughRestoreAndEngine() {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_Engine
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	SavedEngine := _LLM_Engine
	try {
		for Key, Policy in _LNR_Ranges() {
			for Boundary in [Policy["min"], Policy["max"]] {
				_LLM_Menu := LLM_Menu_DeepClone(SavedMenu)
				_LLM_Menu[Key] := Policy["baseline"]
				_LLM_Menu_Loaded := false
				AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(Map(Key, Boundary)))
				AssertEqual(Boundary, _LLM_Menu[Key],
					"(ahk2-06-numeric-option-ranges) restore must publish boundary: "
					. Key . "=" . Boundary)

				_LLM_Engine := SavedEngine.Clone()
				LLM_Engine_Init(Map(Key, Boundary))
				AssertEqual(Boundary, _LLM_Engine[Key],
					"(ahk2-06-numeric-option-ranges) engine must publish boundary: "
					. Key . "=" . Boundary)
			}
		}
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
		_LLM_Engine := SavedEngine
	}
}
Test("AHK2-06 numeric options: boundaries publish through restore and engine "
	. "(ahk2-06-numeric-option-ranges)",
	_LNR_BoundariesPublishThroughRestoreAndEngine)

_LNR_EngineAdmissionRejectsEveryInvalidValueAtomically() {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	try {
		for Key, Policy in _LNR_Ranges() {
			for Bad in _LNR_InvalidValues(Key, Policy) {
				_LLM_Engine := SavedEngine.Clone()
				_LLM_Engine["enabled"] := false
				_LLM_Engine["language"] := "safe-language"
				_LLM_Engine[Key] := Policy["baseline"]
				Thrown := false
				try LLM_Engine_Init(Map(
					"language", "must-not-publish",
					Key, Bad))
				catch as Err {
					Thrown := true
					AssertTrue(Err is TypeError)
				}
				AssertTrue(Thrown,
					"(ahk2-06-numeric-option-ranges) engine must reject: "
					. Key . "=" . Bad)
				AssertFalse(_LLM_Engine["enabled"])
				AssertEqual("safe-language", _LLM_Engine["language"],
					"an earlier valid option must not publish before range validation")
				AssertEqual(Policy["baseline"], _LLM_Engine[Key])
			}
		}
	} finally {
		_LLM_Engine := SavedEngine
	}
}
Test("AHK2-06 numeric options: engine admission is range-atomic "
	. "(ahk2-06-numeric-option-ranges)",
	_LNR_EngineAdmissionRejectsEveryInvalidValueAtomically)

_LNR_DebounceAlwaysProducesAPositiveOneShotDelay() {
	for Delay in [50, 500, 10000] {
		Period := LLM_Option_DebounceTimerPeriod(Delay)
		AssertTrue(Period < 0,
			"(ahk2-06-numeric-option-ranges) SetTimer period must stay one-shot")
		AssertEqual(Delay, Abs(Period),
			"the validated delay magnitude must be preserved")
	}
	for Bad in [-500, 0, 49, 10001] {
		Thrown := false
		try LLM_Option_DebounceTimerPeriod(Bad)
		catch
			Thrown := true
		AssertTrue(Thrown,
			"invalid debounce must never become a repeating SetTimer period: " . Bad)
	}
}
Test("AHK2-06 numeric options: debounce arming is always a positive one-shot delay "
	. "(ahk2-06-numeric-option-ranges)",
	_LNR_DebounceAlwaysProducesAPositiveOneShotDelay)

_LNR_ConfiguredDebounceConsumersArmOneShotTimers() {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	try {
		_LLM_Engine := SavedEngine.Clone()
		_LLM_Engine["enabled"] := true
		_LLM_Engine["debounce_ms"] := 500
		_LLM_Engine["pending_timer"] := ""
		_LLM_Engine["timer_active"] := false
		Calls := []
		ScheduleFn := (Callback, Period) => Calls.Push(Period)

		LLM_Engine_OnKeystroke("first", "", ScheduleFn)
		AssertEqual(1, Calls.Length)
		AssertEqual(-500, Calls[1],
			"(ahk2-06-numeric-option-ranges) keystroke debounce must arm one-shot")

		_LLM_Engine["pending_timer"] := ""
		_LLM_Engine["timer_active"] := false
		LLM_Engine_StartTimer("", "second", (*) => true, ScheduleFn)
		AssertEqual(2, Calls.Length)
		AssertEqual(-500, Calls[2],
			"(ahk2-06-numeric-option-ranges) explicit restart must arm one-shot")
	} finally {
		_LLM_Engine := SavedEngine
	}
}
Test("AHK2-06 numeric options: both configured debounce consumers arm one-shot timers "
	. "(ahk2-06-numeric-option-ranges)",
	_LNR_ConfiguredDebounceConsumersArmOneShotTimers)

_LNR_InvalidPromptValuesNotifyWithoutMutation() {
	global _LLM_Menu
	SavedMenu := _LLM_Menu
	Notices := []
	NotifyFn := (Body, Title) => Notices.Push(Map("body", Body, "title", Title))
	Normalized := "sentinel"
	try {
		_LLM_Menu := LLM_Menu_DeepClone(SavedMenu)
		_LLM_Menu["debounce_ms"] := 500
		IntegerCases := Map(
			"debounce_ms", "abc",
			"ctx_chars", "49",
			"min_words", "0",
			"max_words", "10001")
		for Key, Raw in IntegerCases {
			Before := Notices.Length
			AssertFalse(_LLM_Menu_TryNormalizeIntegerPrompt(
				"OK", Raw, Key, &Normalized, NotifyFn))
			AssertEqual(Before + 1, Notices.Length,
				"each invalid integer family must publish exactly one message: " . Key)
			AssertEqual(false, Normalized)
		}

		Before := Notices.Length
		AssertFalse(_LLM_Menu_TryNormalizePortPrompt(
			"OK", "70000", &Normalized, NotifyFn))
		AssertEqual(Before + 1, Notices.Length,
			"an invalid port must publish exactly one message")

		Before := Notices.Length
		AssertFalse(_LLM_Menu_TryNormalizeTemperaturePrompt(
			"OK", "abc", &Normalized, NotifyFn))
		AssertEqual(Before + 1, Notices.Length,
			"an invalid temperature must publish exactly one message")

		for Field in ["api_name", "api_model", "profile_create", "profile_edit"] {
			Before := Notices.Length
			AssertFalse(_LLM_Menu_TryRequiredPrompt(
				"OK", "  ", &Normalized, NotifyFn))
			AssertEqual(Before + 1, Notices.Length,
				"each required dialog family must publish exactly one message: " . Field)
		}

		Providers := Map("openai", Map())
		Before := Notices.Length
		AssertFalse(_LLM_Menu_TryProviderPrompt(
			"OK", "typo", Providers, &Normalized, NotifyFn))
		AssertEqual(Before + 1, Notices.Length,
			"an unknown provider must publish exactly one message")
		AssertEqual("", Normalized,
			"an unknown provider must never coerce to a different provider")
		AssertEqual(500, _LLM_Menu["debounce_ms"],
			"validation feedback must not mutate menu state")
		for Notice in Notices {
			AssertTrue(Notice["body"] != "",
				"invalid input feedback must resolve a localized body")
			AssertTrue(Notice["title"] != "",
				"invalid input feedback must resolve a localized title")
		}
	} finally _LLM_Menu := SavedMenu
}
Test("[ahk-022] invalid LLM prompt values notify once without mutation",
	_LNR_InvalidPromptValuesNotifyWithoutMutation)

_LNR_CancelledPromptsStaySilent() {
	Notices := []
	NotifyFn := (Body, Title) => Notices.Push(Body)
	Providers := Map("openai", Map())
	Normalized := "sentinel"
	AssertFalse(_LLM_Menu_TryNormalizeIntegerPrompt(
		"Cancel", "abc", "debounce_ms", &Normalized, NotifyFn))
	AssertFalse(_LLM_Menu_TryNormalizePortPrompt(
		"Cancel", "70000", &Normalized, NotifyFn))
	AssertFalse(_LLM_Menu_TryNormalizeTemperaturePrompt(
		"Cancel", "abc", &Normalized, NotifyFn))
	AssertFalse(_LLM_Menu_TryRequiredPrompt(
		"Cancel", "", &Normalized, NotifyFn))
	AssertFalse(_LLM_Menu_TryProviderPrompt(
		"Cancel", "typo", Providers, &Normalized, NotifyFn))
	AssertEqual(0, Notices.Length,
		"cancelling a native prompt must remain silent")
}
Test("[ahk-022] cancelled LLM prompts remain silent",
	_LNR_CancelledPromptsStaySilent)
