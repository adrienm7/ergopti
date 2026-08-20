; tests/unit/test_llm_sync_target.ahk

; ==============================================================================
; MODULE: Detached LLM feature synchronization
; DESCRIPTION:
; Proves that full-save collection can reconcile menu state into a detached
; Features candidate without mutating the live feature tree before persistence.
; ==============================================================================

#Requires AutoHotkey v2.0

_LLMST_Features(Enabled, Model, Backend) {
	return Map("llm", Map(
		"enabled", Enabled,
		"models", Map("ollama", Model, "selected", Backend),
		"profiles", Map(
			"active", "basic",
			"num_predictions", 1,
			"auto_profile_for_model", false),
		"generation", Map(
			"temperature", 0.1,
			"min_words", 1,
			"max_words", 5,
			"context_length", 100,
			"auto_raise_temp", false,
			"reset_on_nav", false),
		"display", Map(
			"show_info_bar", false,
			"streaming", false,
			"streaming_multi", false,
			"pred_indent", 0),
		"trigger", Map(
			"debounce_ms", 100,
			"instant_on_word_end", false,
			"after_hotstring", false,
			"inline_autotype", false,
			"url_bar_filter_enabled", false,
			"secure_filter_enabled", false),
		"navigation", Map("val_modifiers", [])))
}

_LLMST_Menu() {
	return Map(
		"enabled", true,
		"model", "candidate-model",
		"backend", "ollama",
		"profile_id", "advanced",
		"n_predictions", 4,
		"auto_profile_for_model", true,
		"temperature", "0.7",
		"min_words", 2,
		"max_words", 12,
		"ctx_chars", 800,
		"auto_raise_temp", true,
		"reset_on_nav", true,
		"show_info_bar", true,
		"streaming", true,
		"show_all_at_once", true,
		"pred_indent", 2,
		"debounce_ms", 250,
		"instant_on_word_end", true,
		"after_hotstring", true,
		"inline_autotype", true,
		"disable_url_bars", true,
		"disable_password_fields", true,
		"val_modifiers", "alt+shift")
}

_LLMST_SyncUsesExplicitTarget() {
	global Features, _LLM_Menu
	SavedFeatures := Features
	HadMenu := IsSet(_LLM_Menu)
	if HadMenu
		SavedMenu := _LLM_Menu
	try {
		Features := _LLMST_Features(false, "live-model", "remote")
		Candidate := _HSDeepCloneMap(Features)
		_LLM_Menu := _LLMST_Menu()

		ExplicitMenu := _LLMST_Menu()
		ExplicitMenu["model"] := "explicit-model"
		AssertTrue(_LLM_Menu_SyncToFeatures(Candidate, ExplicitMenu),
			"an explicit detached Features target must be accepted")
		AssertFalse(Features["llm"]["enabled"],
			"detached reconciliation must not publish into live Features")
		AssertEqual("live-model", Features["llm"]["models"]["ollama"])
		AssertTrue(Candidate["llm"]["enabled"])
		AssertEqual("explicit-model", Candidate["llm"]["models"]["ollama"],
			"explicit collection must derive from the detached menu candidate, "
			. "not from the live global")
		AssertEqual("ollama", Candidate["llm"]["models"]["selected"])

		AssertTrue(_LLM_Menu_SyncToFeatures(),
			"the legacy no-argument call must still publish to live Features")
		AssertTrue(Features["llm"]["enabled"])
		AssertEqual("candidate-model", Features["llm"]["models"]["ollama"])
	} finally {
		Features := SavedFeatures
		if HadMenu
			_LLM_Menu := SavedMenu
		else
			_LLM_Menu := unset
	}
}

Test("LLM persistence: synchronization honors explicit detached targets (llm-sync-explicit-candidate)",
	_LLMST_SyncUsesExplicitTarget)
