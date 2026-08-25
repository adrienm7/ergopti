; static/ergopti_plus/windows/tests/meta/test_llm_semantic_config_class.ahk

; ==============================================================================
; MODULE: LLM Semantic Configuration Class Guard
; DESCRIPTION:
; Structural class coverage for audit finding AHK-16. Every option emitted by
; LLM_Menu_BuildOpts must be classified exactly once as generation-semantic,
; display-only, or runtime policy. The guard also enumerates both cache branches
; and both request-state constructors so a sibling cannot silently omit semantic
; ownership during a later refactor.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Guard Utilities =======
; ==================================
; ==================================

_AHK16_ClassHas(Keys, Wanted) {
	for Key in Keys {
		if (StrCompare(Key, Wanted, true) == 0)
			return true
	}
	return false
}

_AHK16_CountOccurrences(Source, Needle) {
	Count := 0
	Position := 1
	while (Found := InStr(Source, Needle, true, Position)) {
		Count += 1
		Position := Found + StrLen(Needle)
	}
	return Count
}

_AHK16_AssertExactClass(Actual, Expected, Label) {
	AssertEqual(Expected.Length, Actual.Length,
		"AHK-16 " . Label . " class size changed; classify every option explicitly")
	for Key in Expected {
		AssertTrue(_AHK16_ClassHas(Actual, Key),
			"AHK-16 " . Label . " class must include '" . Key . "'")
	}
}





; ==============================================
; ==============================================
; ======= 2/ Exhaustive Option Partition =======
; ==============================================
; ==============================================

_AHK16_ConfigClassPartitionIsExhaustive() {
	global LLM_ENGINE_SEMANTIC_CONFIG_KEYS
	global LLM_ENGINE_DISPLAY_ONLY_CONFIG_KEYS
	global LLM_ENGINE_RUNTIME_POLICY_CONFIG_KEYS

	ExpectedSemantic := [
		"backend", "ollama_port", "model", "profile_id", "user_profiles", "n_predictions",
		"min_words", "max_words", "ctx_chars", "language", "temperature",
		"auto_raise_temp", "inline_autotype", "api_entries", "api_entry_id",
		"app_profile_overrides"
	]
	ExpectedDisplay := [
		"show_info_bar", "show_all_at_once", "pred_indent", "nav_modifiers", "val_modifiers"
	]
	ExpectedPolicy := [
		"debounce_ms", "instant_on_word_end", "after_hotstring", "reset_on_nav",
		"disable_url_bars", "disable_password_fields", "disabled_apps", "streaming"
	]
	_AHK16_AssertExactClass(LLM_ENGINE_SEMANTIC_CONFIG_KEYS, ExpectedSemantic, "semantic")
	_AHK16_AssertExactClass(LLM_ENGINE_DISPLAY_ONLY_CONFIG_KEYS, ExpectedDisplay, "display-only")
	_AHK16_AssertExactClass(LLM_ENGINE_RUNTIME_POLICY_CONFIG_KEYS, ExpectedPolicy, "runtime-policy")

	Classified := Map()
	for ClassName, Keys in Map(
			"semantic", LLM_ENGINE_SEMANTIC_CONFIG_KEYS,
			"display", LLM_ENGINE_DISPLAY_ONLY_CONFIG_KEYS,
			"policy", LLM_ENGINE_RUNTIME_POLICY_CONFIG_KEYS) {
		for Key in Keys {
			AssertFalse(Classified.Has(Key),
				"AHK-16 option '" . Key . "' is classified more than once")
			Classified[Key] := ClassName
		}
	}

	BuildOptsBody := _DriverFuncBody("LLM_Menu_BuildOpts")
	Assert(BuildOptsBody != "",
		"AHK-16 LLM_Menu_BuildOpts must exist before its configuration class can be audited")
	BuildOptsBody := _StripFullLineComments(BuildOptsBody)
	Emitted := Map()
	MatchCount := 0
	Position := 1
	while RegExMatch(BuildOptsBody, 'm)^\s*"([a-z_]+)",\s+', &Match, Position) {
		Key := Match[1]
		AssertFalse(Emitted.Has(Key),
			"AHK-16 LLM_Menu_BuildOpts emits duplicate option '" . Key . "'")
		Emitted[Key] := true
		MatchCount += 1
		Position := Match.Pos + Match.Len
	}
	Assert(MatchCount >= 20,
		"AHK-16 option scan must find the full BuildOpts return Map, not an empty fragment")
	AssertEqual(Classified.Count, MatchCount,
		"AHK-16 every BuildOpts option must belong to exactly one semantic/display/policy class")
	for Key, _ in Emitted {
		AssertTrue(Classified.Has(Key),
			"AHK-16 newly emitted option '" . Key . "' must be classified before it ships")
	}
	for Key, _ in Classified {
		AssertTrue(Emitted.Has(Key),
			"AHK-16 classified option '" . Key . "' must still be emitted by LLM_Menu_BuildOpts")
	}
}
Test("LLM semantic identity: BuildOpts has an exhaustive one-class partition (AHK-16)",
	_AHK16_ConfigClassPartitionIsExhaustive)





; =============================================
; =============================================
; ======= 3/ Every Request Path Owns It =======
; =============================================
; =============================================

_AHK16_EveryRequestPathCarriesSemanticIdentity() {
	InitBody := _DriverFuncBody("LLM_Engine_Init")
	Assert(InitBody != "", "AHK-16 LLM_Engine_Init must exist in driver source")
	Assert(InStr(InitBody, "_LLM_Engine_RefreshSemanticConfig()") > 0,
		"AHK-16 live configuration publication must route through canonical semantic invalidation")

	FireBody := _DriverFuncBody("LLM_Engine_FirePrediction")
	Assert(FireBody != "", "AHK-16 LLM_Engine_FirePrediction must exist in driver source")
	Assert(InStr(FireBody, "_LLM_Engine_RefreshSemanticConfig()") == 0,
		"AHK2-18 unchanged fires must consume the signature committed by LLM_Engine_Init, not re-encode the full option graph")
	AssertEqual(2, _AHK16_CountOccurrences(FireBody, "_LLM_Engine_CacheOwnsRequest("),
		"AHK-16 exact and prefix cache branches must both verify semantic ownership")
	AssertEqual(2, _AHK16_CountOccurrences(FireBody,
		'"semantic_signature", request_semantic_signature'),
		"AHK-16 batch and sequential request-state constructors must both capture semantic identity")
	AssertEqual(8, _AHK16_CountOccurrences(FireBody, "request_semantic_signature"),
		"AHK-16 request signature must be computed, published, checked by both caches, and stored by both state constructors")
	Assert(InStr(FireBody, "effective_profile_id, profile") > 0,
		"AHK-16 request identity must bind the resolved prompt profile, not its id alone")

	SignatureBody := _DriverFuncBody("_LLM_Engine_RequestSemanticSignature")
	Assert(SignatureBody != "", "AHK-16 request-signature builder must exist in driver source")
	Assert(InStr(SignatureBody, "_LLM_Engine_EncodeSemanticValue(Profile)") > 0,
		"AHK-16 request signature must encode the resolved prompt content")

	CurrentBody := _DriverFuncBody("_LLM_Engine_IsCurrent")
	Assert(CurrentBody != "", "AHK-16 _LLM_Engine_IsCurrent must exist in driver source")
	Assert(InStr(CurrentBody, 'state.Has("semantic_signature")') > 0,
		"AHK-16 callbacks missing semantic ownership must fail closed")
	Assert(InStr(CurrentBody, 'state["semantic_signature"]') > 0
		and InStr(CurrentBody, '"active_request_signature"') > 0,
		"AHK-16 callback currency must compare captured and active semantic signatures")

	FinalizeBody := _DriverFuncBody("_LLM_Engine_FinalizeRequest")
	Assert(FinalizeBody != "", "AHK-16 _LLM_Engine_FinalizeRequest must exist in driver source")
	Assert(InStr(FinalizeBody, '"last_semantic_signature"') > 0,
		"AHK-16 successful finalization must publish cache ownership with its result")
}
Test("LLM semantic identity: every cache and async request path carries the signature (AHK-16)",
	_AHK16_EveryRequestPathCarriesSemanticIdentity)
