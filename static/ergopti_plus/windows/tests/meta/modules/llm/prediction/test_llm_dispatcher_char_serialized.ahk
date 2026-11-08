; tests/meta/modules/llm/prediction/test_llm_dispatcher_char_serialized.ahk

; ==============================================================================
; MODULE: LLM Dispatcher Character Serialization Meta Test
; DESCRIPTION:
; Regression guard for a character dropped from the LLM rolling context. The
; dispatcher fallback's callback ran outside Critical, and LLM_Bridge_OnChar
; releases Critical between its entry snapshot and its append, so the callback
; of a later character could commit first; its generation check then dropped
; the earlier character (a hosted runner typed « canary », the context held
; « cnary »). The callback now serializes from admission, as _OnPrefixChar does.
;
; FEATURES & RATIONALE:
; 1. Source introspection, because thread interruption between two native
;    InputHook callbacks cannot be scheduled deterministically in a unit test.
; 2. Critical is taken before the first admission check and released in a
;    finally, so no early return can leave the script Critical.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================================
; ===============================================
; ======= 1/ Test implementation ================
; ===============================================
; ===============================================

_LDCS_DispatcherCharSerializedFromAdmission() {
	Body := _DriverFuncBody("_LLM_Bridge_OnDispatcherChar")
	Assert(Body != "", "_LLM_Bridge_OnDispatcherChar must exist in the driver source")
	CriticalAt := InStr(Body, 'PreviousCritical := Critical("On")')
	AdmissionAt := InStr(Body, "if A_IsSuspended")
	PrepareAt := InStr(Body, "_PrefixPrepareScalarContext(ch)")
	FeedAt := InStr(Body, "LLM_Bridge_OnChar(ch)")
	ReleaseAt := InStr(Body, "finally Critical(PreviousCritical)")
	Assert(CriticalAt > 0 && CriticalAt < AdmissionAt,
		"the dispatcher character callback must take Critical before its first admission check")
	Assert(AdmissionAt < PrepareAt && PrepareAt < FeedAt && FeedAt < ReleaseAt,
		"the scalar preparation and the rolling-context feed must both run before Critical is released")
}
Test("LLM: the dispatcher character callback serializes from admission (llm-dispatcher-char-serialized)",
	_LDCS_DispatcherCharSerializedFromAdmission)
