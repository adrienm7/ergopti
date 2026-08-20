; static/ergopti_plus/windows/tests/unit/test_llm_semantic_config_identity.ahk

; ==============================================================================
; MODULE: LLM Semantic Configuration Identity Regression Tests
; DESCRIPTION:
; Behavioural coverage for audit finding AHK-16. The same typed context is not
; the same generation when its model, resolved prompt, language, temperature,
; API entry, user profiles, or per-application override changes. These tests
; exercise the real engine state transition, cache gate, and callback predicate
; without starting HTTP: the API backend is configured with no active entry, so
; a cache miss stops at the production fail-fast guard.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ Test Fixtures =======
; ================================
; ================================

_AHK16_BaselineOpts() {
	return Map(
		"model",                   "model-a",
		"profile_id",              "basic",
		"user_profiles",           [Map("id", "custom-a", "raw_prompt", "Prompt A", "batch", false)],
		"n_predictions",           1,
		"min_words",               3,
		"max_words",               15,
		"language",                "en",
		"debounce_ms",             500,
		"ctx_chars",               500,
		"temperature",             "0.10",
		"instant_on_word_end",     true,
		"after_hotstring",         true,
		"reset_on_nav",            true,
		"disable_url_bars",        false,
		"disable_password_fields", false,
		"disabled_apps",           [],
		"show_info_bar",           false,
		"streaming",               false,
		"show_all_at_once",        true,
		"pred_indent",             0,
		"auto_raise_temp",         true,
		"nav_modifiers",           "",
		"val_modifiers",           "alt",
		"backend",                 "api",
		"api_entries",             [],
		"api_entry_id",            "",
		"inline_autotype",         false,
		"app_profile_overrides",   Map()
	)
}

_AHK16_WithIsolatedEngine(Body) {
	global _LLM_Engine, _I18nLocale, _Stub_LlmTooltipCalls, _Stub_LlmSuggestedCalls
	PreviousEngine := _LLM_Engine
	PreviousLocale := _I18nLocale
	PreviousTooltipCalls := _Stub_LlmTooltipCalls
	PreviousSuggestedCalls := _Stub_LlmSuggestedCalls
	_LLM_Engine := PreviousEngine.Clone()
	_I18nLocale := "en"
	_Stub_LlmTooltipCalls := []
	_Stub_LlmSuggestedCalls := []
	Base := _AHK16_BaselineOpts()
	try {
		LLM_Engine_Init(Base)
		_LLM_Engine["last_request_tick"] := 0
		Body.Call(Base)
	} finally {
		try LLM_Engine_CancelTimer()
		_LLM_Engine := PreviousEngine
		_I18nLocale := PreviousLocale
		_Stub_LlmTooltipCalls := PreviousTooltipCalls
		_Stub_LlmSuggestedCalls := PreviousSuggestedCalls
	}
}

_AHK16_SeedOwnedCache(Context, Result, RequestSignature) {
	global _LLM_Engine
	_LLM_Engine["last_ctx"] := Context
	_LLM_Engine["last_results"] := [Result]
	_LLM_Engine["last_result"] := Result
	_LLM_Engine["last_semantic_signature"] := RequestSignature
	_LLM_Engine["active_request_signature"] := RequestSignature
}

_AHK16_SemanticVariants() {
	return Map(
		"backend",               "ollama",
		"model",                 "model-b",
		"profile_id",            "rewrite",
		"user_profiles",         [Map("id", "custom-b", "raw_prompt", "Prompt B", "batch", true)],
		"n_predictions",         2,
		"min_words",             2,
		"max_words",             22,
		"ctx_chars",             700,
		"language",              "de",
		"temperature",           "0.25",
		"auto_raise_temp",       false,
		"inline_autotype",       true,
		"api_entries",           [Map("Id", "entry-b", "Provider", "openai", "Model", "model-b")],
		"api_entry_id",          "entry-b",
		"app_profile_overrides", Map("notepad", "rewrite")
	)
}

_AHK16_DisplayVariants() {
	return Map(
		"show_info_bar",    true,
		"show_all_at_once", false,
		"pred_indent",      2,
		"nav_modifiers",    "ctrl",
		"val_modifiers",    "ctrl"
	)
}





; ====================================================
; ====================================================
; ======= 2/ Semantic Changes Invalidate State =======
; ====================================================
; ====================================================

_AHK16_EverySemanticChangeInvalidatesBody(Base) {
	global _LLM_Engine
	for Key, NewValue in _AHK16_SemanticVariants() {
		LLM_Engine_Init(Base)
		OldConfigSignature := _LLM_Engine["semantic_config_signature"]
		OldRequestSignature := _LLM_Engine_RequestSemanticSignature(Base["profile_id"])
		_AHK16_SeedOwnedCache("same semantic context", "old answer", OldRequestSignature)
		OldRequestId := _LLM_Engine["request_id"]
		OldCallback := Map(
			"request_id", OldRequestId,
			"semantic_signature", OldRequestSignature
		)
		_LLM_Engine["timer_active"] := true
		_LLM_Engine["pending_timer"] := ""

		Delta := Map("language", Base["language"])
		Delta[Key] := NewValue
		LLM_Engine_Init(Delta)

		AssertFalse(_LLM_Engine_SignaturesEqual(
			OldConfigSignature, _LLM_Engine["semantic_config_signature"]),
			"AHK-16 semantic key '" . Key . "' must change the canonical configuration signature")
		Assert(_LLM_Engine["request_id"] > OldRequestId,
			"AHK-16 semantic key '" . Key . "' must invalidate every in-flight callback")
		AssertFalse(_LLM_Engine_IsCurrent(OldCallback),
			"AHK-16 callback born under semantic key '" . Key . "' must be rejected after it changes")
		AssertEqual("", _LLM_Engine["last_ctx"],
			"AHK-16 semantic key '" . Key . "' must evict the context cache")
		AssertEqual(0, _LLM_Engine["last_results"].Length,
			"AHK-16 semantic key '" . Key . "' must evict cached results")
		AssertEqual("", _LLM_Engine["last_semantic_signature"],
			"AHK-16 semantic key '" . Key . "' must retire cache ownership")
		AssertFalse(_LLM_Engine["timer_active"],
			"AHK-16 semantic key '" . Key . "' must cancel the pending request timer")
	}
}

_AHK16_EverySemanticChangeInvalidates() {
	_AHK16_WithIsolatedEngine(_AHK16_EverySemanticChangeInvalidatesBody)
}
Test("LLM semantic identity: every generation-affecting option invalidates cache and callbacks (AHK-16)",
	_AHK16_EverySemanticChangeInvalidates)


_AHK16_SameIdDifferentSignatureIsStaleBody(Base) {
	global _LLM_Engine
	_LLM_Engine["request_id"] := 71
	_LLM_Engine["active_request_signature"] := "current-semantic-config"
	Stale := Map(
		"request_id", 71,
		"semantic_signature", "stale-semantic-config"
	)
	AssertFalse(_LLM_Engine_IsCurrent(Stale),
		"AHK-16 request_id equality alone must not authorize a callback from another semantic configuration")
}

_AHK16_SameIdDifferentSignatureIsStale() {
	_AHK16_WithIsolatedEngine(_AHK16_SameIdDifferentSignatureIsStaleBody)
}
Test("LLM semantic identity: equal request ids cannot authorize a stale configuration callback (AHK-16)",
	_AHK16_SameIdDifferentSignatureIsStale)


_AHK16_ResolvedPromptContentParticipatesBody(Base) {
	First := _LLM_Engine_RequestSemanticSignature("basic",
		Map("id", "basic", "raw_prompt", "Prompt A", "batch", false))
	Second := _LLM_Engine_RequestSemanticSignature("basic",
		Map("id", "basic", "raw_prompt", "Prompt B", "batch", false))
	AssertFalse(_LLM_Engine_SignaturesEqual(First, Second),
		"AHK-16 resolved prompt content must participate even when profile id and base settings match")
}

_AHK16_ResolvedPromptContentParticipates() {
	_AHK16_WithIsolatedEngine(_AHK16_ResolvedPromptContentParticipatesBody)
}
Test("LLM semantic identity: resolved prompt content participates in request ownership (AHK-16)",
	_AHK16_ResolvedPromptContentParticipates)





; ===============================================
; ===============================================
; ======= 3/ Cache Uses Request Semantics =======
; ===============================================
; ===============================================

_AHK16_CacheRejectsDifferentEffectiveProfileBody(Base) {
	global _LLM_Engine, _Stub_LlmTooltipCalls
	Context := "semantic cache context"
	_AHK16_SeedOwnedCache(Context, "cached answer", "stale-effective-profile")
	_Stub_LlmTooltipCalls := []

	; With no configured API entry, a genuine miss stops before any tooltip. If
	; the cache gate ignores its semantic owner, the stale answer paints here.
	LLM_Engine_FirePrediction(Context)
	AssertEqual(0, _Stub_LlmTooltipCalls.Length,
		"AHK-16 identical text under another effective profile must bypass the stale cache")

	; Prove the preceding zero is caused by signature mismatch, not by a cache
	; path that can never render in this harness.
	CurrentRequestSignature := _LLM_Engine_RequestSemanticSignature(Base["profile_id"])
	_AHK16_SeedOwnedCache(Context, "cached answer", CurrentRequestSignature)
	_Stub_LlmTooltipCalls := []
	LLM_Engine_FirePrediction(Context)
	AssertEqual(1, _Stub_LlmTooltipCalls.Length,
		"AHK-16 a cache entry owned by the current effective profile must still render")
	AssertEqual("cached answer", _Stub_LlmTooltipCalls[1].slots[1],
		"AHK-16 the retained current-semantic cache must return its stored answer")
}

_AHK16_CacheRejectsDifferentEffectiveProfile() {
	_AHK16_WithIsolatedEngine(_AHK16_CacheRejectsDifferentEffectiveProfileBody)
}
Test("LLM semantic identity: per-app effective profile participates in cache identity (AHK-16)",
	_AHK16_CacheRejectsDifferentEffectiveProfile)





; =============================================
; =============================================
; ======= 4/ Display Settings Retain It =======
; =============================================
; =============================================

_AHK16_DisplayChangesRetainCacheBody(Base) {
	global _LLM_Engine
	for Key, NewValue in _AHK16_DisplayVariants() {
		LLM_Engine_Init(Base)
		OldConfigSignature := _LLM_Engine["semantic_config_signature"]
		OldRequestSignature := _LLM_Engine_RequestSemanticSignature(Base["profile_id"])
		_AHK16_SeedOwnedCache("same semantic context", "retained answer", OldRequestSignature)
		OldRequestId := _LLM_Engine["request_id"]
		CurrentCallback := Map(
			"request_id", OldRequestId,
			"semantic_signature", OldRequestSignature
		)
		_LLM_Engine["timer_active"] := true
		_LLM_Engine["pending_timer"] := ""

		Delta := Map("language", Base["language"])
		Delta[Key] := NewValue
		LLM_Engine_Init(Delta)

		AssertTrue(_LLM_Engine_SignaturesEqual(
			OldConfigSignature, _LLM_Engine["semantic_config_signature"]),
			"AHK-16 display-only key '" . Key . "' must not alter generation identity")
		AssertEqual(OldRequestId, _LLM_Engine["request_id"],
			"AHK-16 display-only key '" . Key . "' must not invalidate a valid callback")
		AssertTrue(_LLM_Engine_IsCurrent(CurrentCallback),
			"AHK-16 display-only key '" . Key . "' must retain current callback ownership")
		AssertEqual("same semantic context", _LLM_Engine["last_ctx"],
			"AHK-16 display-only key '" . Key . "' must retain cache context")
		AssertEqual("retained answer", _LLM_Engine["last_results"][1],
			"AHK-16 display-only key '" . Key . "' must retain cache result")
		AssertTrue(_LLM_Engine["timer_active"],
			"AHK-16 display-only key '" . Key . "' must not cancel pending generation")
	}
}

_AHK16_DisplayChangesRetainCache() {
	_AHK16_WithIsolatedEngine(_AHK16_DisplayChangesRetainCacheBody)
}
Test("LLM semantic identity: display-only options retain cache and callbacks (AHK-16)",
	_AHK16_DisplayChangesRetainCache)
