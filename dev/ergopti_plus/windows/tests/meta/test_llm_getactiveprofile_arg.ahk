; tests/meta/test_llm_getactiveprofile_arg.ahk

; ==============================================================================
; MODULE: LLM_GetActiveProfile Second Argument Guard
; DESCRIPTION:
; Static source guard for the LLM_GetActiveProfile missing-argument fix in
; modules/llm/prediction_engine.ahk.
;
; ROOT CAUSE ENCODED:
; Several call sites inside prediction_engine.ahk called LLM_GetActiveProfile
; with only one argument (profile_id), omitting the required user_profiles array.
; The function signature expects two arguments; calling it with one caused it to
; treat the profiles list as empty, so per-user profile customisations were
; silently ignored and the engine always fell back to the global default.
;
; The fix ensures every call passes the user_profiles array as the second
; argument. This test checks that no bare single-argument call to
; LLM_GetActiveProfile exists in the live code.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================================================
; ==========================================================================
; ======= 1/ LLM_GetActiveProfile always receives user_profiles arg =========
; ==========================================================================
; ==========================================================================

_TLGAA_ProfileArgPresent() {
	Src := _DriverDirConcat("modules/llm")

	; The call must include user_profiles as the second argument
	; The fix uses _LLM_Engine["user_profiles"] or [] as fallback
	Assert(InStr(Src, "LLM_GetActiveProfile(effective_profile_id, _LLM_Engine.Has(" . Chr(0x22) . "user_profiles" . Chr(0x22) . ")") > 0,
		"LLM_GetActiveProfile must be called with user_profiles as second argument in prediction_engine.ahk")
}
Test("prediction_engine: LLM_GetActiveProfile called with user_profiles as second argument", _TLGAA_ProfileArgPresent)
