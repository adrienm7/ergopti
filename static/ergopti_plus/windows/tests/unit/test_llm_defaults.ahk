; static/ergopti_plus/windows/tests/unit/test_llm_defaults.ahk

; ==============================================================================
; MODULE: LLM Defaults Loader Tests
; DESCRIPTION:
; Regression coverage for lib/llm_defaults.ahk after the hardcoded-fallback
; removal. The 20-key _LLM_DEFAULTS_FALLBACK mirror is gone; only the genuinely
; AHK-local _LLM_LOCAL_DEFAULTS (model, backend) remains, and the loader sources
; every shared value from _shared/modules/llm/defaults.json, failing fast on a missing
; file or key instead of substituting a divergent in-code mirror.
; ==============================================================================




; ============================================
; ============================================
; ======= 1/ AHK-Local Defaults Map ==========
; ============================================
; ============================================

_LLMDefaults_LocalMapHoldsOnlyLocalKeys() {
	global _LLM_LOCAL_DEFAULTS
	AssertTrue(_LLM_LOCAL_DEFAULTS is Map)
	AssertTrue(_LLM_LOCAL_DEFAULTS.Has("llm_model"))
	AssertTrue(_LLM_LOCAL_DEFAULTS.Has("llm_backend"))
	; The shared values must NOT be mirrored here — the old 20-key fallback map
	; is gone, so a renamed/missing JSON key can no longer be silently masked.
	AssertTrue(!_LLM_LOCAL_DEFAULTS.Has("llm_temperature"))
	AssertTrue(!_LLM_LOCAL_DEFAULTS.Has("llm_min_words"))
	AssertTrue(!_LLM_LOCAL_DEFAULTS.Has("llm_max_words"))
	AssertTrue(!_LLM_LOCAL_DEFAULTS.Has("llm_num_predictions"))
}
Test("LLMDefaults: _LLM_LOCAL_DEFAULTS holds only the AHK-local keys", _LLMDefaults_LocalMapHoldsOnlyLocalKeys)




; ============================================
; ============================================
; ======= 2/ Loader sources from JSON ========
; ============================================
; ============================================

_LLMDefaults_LoaderSourcesSharedFromJson() {
	global LLM_Defaults
	LLM_Defaults_Load()
	AssertTrue(IsSet(LLM_Defaults))
	AssertTrue(LLM_Defaults is Map)
	; Shared keys must be sourced from defaults.json (present after a clean load).
	AssertTrue(LLM_Defaults.Has("llm_temperature"))
	AssertTrue(LLM_Defaults.Has("llm_min_words"))
	AssertTrue(LLM_Defaults.Has("llm_max_words"))
	AssertTrue(LLM_Defaults.Has("llm_num_predictions"))
	; Word bounds are coherent numbers from the single source.
	AssertTrue(LLM_Defaults["llm_min_words"] <= LLM_Defaults["llm_max_words"])
	; AHK-local keys are layered on top from _LLM_LOCAL_DEFAULTS.
	AssertEqual("ollama", LLM_Defaults["llm_backend"])
	AssertTrue(LLM_Defaults.Has("llm_model"))
}
Test("LLMDefaults: loader populates shared keys from defaults.json + local keys", _LLMDefaults_LoaderSourcesSharedFromJson)
