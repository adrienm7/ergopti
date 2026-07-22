; static/ergopti_plus/windows/tests/meta/test_b7_1_dead_shims_absent.ahk

; ==============================================================================
; MODULE: B7.1 Dead Shim Absence Guard
; DESCRIPTION:
; Regression guard ensuring the two backwards-compat shim functions removed in
; B7.1 (HealthCheck_Format and LLM_OllamaGenerate) have not been re-introduced
; anywhere in their respective source files. A re-introduction would silently
; add dead code paths and bypass the §5.6 "No Unused Fallback Code" rule.
; ==============================================================================


; =====================================================
; =====================================================
; ======= 1/ HealthCheck_Format absent (B7.1) ========
; =====================================================
; =====================================================

_B71_HealthCheckFormat_Absent() {
	Src := _DriverDirConcat("ui/healthcheck")
	; Column-0 function definition pattern; call sites are always indented.
	AssertTrue(!RegExMatch(Src, "m)^HealthCheck_Format\("),
		"HealthCheck_Format must not be defined — dead shim removed in B7.1 (§5.6)")
}
Test("B7.1: HealthCheck_Format shim is absent from ui/healthcheck source", _B71_HealthCheckFormat_Absent)


; =====================================================
; =====================================================
; ======= 2/ LLM_OllamaGenerate absent (B7.1) ========
; =====================================================
; =====================================================

_B71_LLMOllamaGenerate_Absent() {
	; Verify the ASYNC variant still exists (it is live and must not be removed).
	AsyncBody := _DriverFuncBody("LLM_OllamaGenerate_Async")
	AssertTrue(StrLen(AsyncBody) > 0, "LLM_OllamaGenerate_Async must still be defined")

	; The SYNC variant (zero callers) must be gone from the full LLM source tree.
	Src := _DriverDirConcat("modules/llm")
	AssertTrue(!RegExMatch(Src, "m)^LLM_OllamaGenerate\("),
		"LLM_OllamaGenerate (sync, 0 callers) must not be defined — dead code removed in B7.1 (§5.6)")
}
Test("B7.1: LLM_OllamaGenerate sync shim is absent from modules/llm source", _B71_LLMOllamaGenerate_Absent)
