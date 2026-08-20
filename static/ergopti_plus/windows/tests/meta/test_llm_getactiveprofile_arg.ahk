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
	; Enumerate the three production callers. A whitespace-normalized body keeps
	; this guard insensitive to line wrapping while still requiring the actual
	; user_profiles expression at every site.
	Expected := Map(
		"_LLM_Engine_RequestSemanticSignature",
			'LLM_GetActiveProfile(EffectiveProfileId,_LLM_Engine.Get("user_profiles",[]))',
		"LLM_Engine_FirePrediction",
			'LLM_GetActiveProfile(effective_profile_id,_LLM_Engine.Has("user_profiles")?_LLM_Engine["user_profiles"]:[])',
		"_LLM_Engine_ApplyTooltipDisplayOpts",
			'LLM_GetActiveProfile(_LLM_Engine_ResolveProfileIdForApp(_LLM_Engine["profile_id"]),_LLM_Engine.Has("user_profiles")?_LLM_Engine["user_profiles"]:[])'
	)
	for FunctionName, RequiredCall in Expected {
		Body := RegExReplace(_DriverFuncBody(FunctionName), "\s+", "")
		Assert(Body != "", FunctionName . " must exist in the driver source")
		Assert(InStr(Body, RequiredCall, true) > 0,
			FunctionName . " must pass user_profiles as LLM_GetActiveProfile's second argument")
	}
}
Test("prediction_engine: LLM_GetActiveProfile called with user_profiles as second argument", _TLGAA_ProfileArgPresent)
