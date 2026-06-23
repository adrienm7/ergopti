; static/ergopti_plus/windows/tests/unit/test_llm_api_common.ahk

; ==============================================================================
; MODULE: LLM API Common Tunables Tests
; DESCRIPTION:
; Regression coverage for modules/llm/api_common.ahk after the hardcoded
; LLM_COMMON_FALLBACK mirror was removed. The inference tunables now come
; exclusively from _shared/modules/llm/inference.json; a missing file or tunable raises
; (fail fast) instead of silently serving a diverging in-code copy.
; ==============================================================================




; ============================================
; ============================================
; ======= 1/ Tunables Come From JSON =========
; ============================================
; ============================================

_LLMCommon_TunablesSourcedFromInferenceJson() {
	; diversity_temperature.max_temperature is 1.30 in inference.json.
	AssertTrue(_LLM_Common_Cfg("diversity_temperature", "max_temperature") + 0 > 1.0)
	; retry.max_multiplier is a positive integer.
	AssertTrue(_LLM_Common_Cfg("retry", "max_multiplier") + 0 >= 1)
	; The ollama rate-limit floor is a positive number read from the JSON.
	AssertTrue(LLM_ApiCommon_GetRateLimitMs("ollama") + 0 > 0)
}
Test("LLMApiCommon: tunables are sourced from inference.json", _LLMCommon_TunablesSourcedFromInferenceJson)





; ============================================
; =============================================
; ======= 2/ Missing Tunable Fails Fast =======
; =============================================
; ============================================

_LLMCommon_MissingTunableFailsFast() {
	; A tunable that does not exist in inference.json must raise rather than
	; return a value from a hardcoded mirror (the old LLM_COMMON_FALLBACK path).
	threw := false
	try {
		_LLM_Common_Cfg("definitely_not_a_section", "nope")
	} catch as e {
		threw := true
	}
	AssertTrue(threw)
}
Test("LLMApiCommon: a missing tunable fails fast (no in-code fallback)", _LLMCommon_MissingTunableFailsFast)
