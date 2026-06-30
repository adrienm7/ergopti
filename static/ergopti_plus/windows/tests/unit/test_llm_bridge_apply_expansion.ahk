; tests/unit/test_llm_bridge_apply_expansion.ahk

; ==============================================================================
; MODULE: LLM Bridge Apply Expansion Unit Tests
; DESCRIPTION:
; Regression guard for AHK-23: physical characters typed inside the 60 ms
; post-expansion suppression window were dropped from _LLM_Bridge_Buffer because
; LLM_Bridge_FeedCharIfActive is called AFTER the suppressed-branch early-return
; in _OnPrefixChar. After every hotstring fire the LLM rolling context was
; permanently desynced: the trigger chars stayed in the buffer, the replacement
; text was never appended, and any chars typed during the drain window were lost.
; The LLM then predicted completions against a context that no longer matched
; the document.
;
; The fix adds LLM_Bridge_ApplyExpansionIfActive (llm_bridge.ahk), called from
; HSE_DispatchMatch right after HSE_ApplyExpansion, so the LLM buffer is updated
; to reflect the on-screen post-expansion state with the same trigger-strip +
; replacement-append semantics as HSE_ApplyExpansion.
;
; These unit tests assert:
;   (1) After LLM_Bridge_ApplyExpansionIfActive, _LLM_Bridge_Buffer equals
;       the replacement text (trigger stripped, replacement appended).
;   (2) Star-trigger expansion (no EndChar): buffer = replacement only.
;   (3) End-char expansion: buffer = replacement + EndChar.
;   (4) When the bridge is inactive, the call is a no-op (buffer unchanged).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Helpers ================================================
; ===================================================================
; ===================================================================

_TLBAE_MakeSpec(trigger) {
	Spec := {}
	Spec.Trigger := trigger
	Spec.Length := StrLen(trigger)
	return Spec
}

_TLBAE_SetupBuffer(buf) {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	_LLM_Bridge_Buffer := buf
	_LLM_Bridge_Active := true
}

_TLBAE_Teardown() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	_LLM_Bridge_Buffer := ""
	_LLM_Bridge_Active := false
}




; ===================================================================
; ===================================================================
; ======= 2/ Test cases =============================================
; ===================================================================
; ===================================================================

_TLBAE_TestStarTriggerNoEndChar() {
	; Simulate: user typed "teh" (star trigger, no end char), buffer has "teh"
	_TLBAE_SetupBuffer("teh")
	Spec := _TLBAE_MakeSpec("teh")
	LLM_Bridge_ApplyExpansionIfActive(Spec, "the")
	AssertEqual("the", _LLM_Bridge_Buffer,
		"AHK-23: after a star-trigger expansion the LLM buffer must contain the replacement 'the', not the original trigger 'teh'")
	_TLBAE_Teardown()
}

_TLBAE_TestEndCharExpansion() {
	; Simulate: user typed "teh " (end-char trigger, EndChar=" "), buffer = "word teh "
	_TLBAE_SetupBuffer("word teh ")
	Spec := _TLBAE_MakeSpec("teh")
	LLM_Bridge_ApplyExpansionIfActive(Spec, "the", " ")
	AssertEqual("word the ", _LLM_Bridge_Buffer,
		"AHK-23: after an end-char expansion the LLM buffer must contain the pre-trigger prefix + replacement + end char — trigger stripped, replacement and end char appended")
	_TLBAE_Teardown()
}

_TLBAE_TestInactiveIsNoOp() {
	; When bridge is not active, the call must be a no-op
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	_LLM_Bridge_Buffer := "unchanged"
	_LLM_Bridge_Active := false
	Spec := _TLBAE_MakeSpec("teh")
	LLM_Bridge_ApplyExpansionIfActive(Spec, "the", " ")
	AssertEqual("unchanged", _LLM_Bridge_Buffer,
		"AHK-23: LLM_Bridge_ApplyExpansionIfActive must be a no-op when the bridge is inactive")
	_TLBAE_Teardown()
}

_TLBAE_TestBufferShorterThanTrigger() {
	; Edge case: buffer drifted out of sync (shorter than trigger) — clear, then append
	_TLBAE_SetupBuffer("eh")
	Spec := _TLBAE_MakeSpec("teh")
	LLM_Bridge_ApplyExpansionIfActive(Spec, "the")
	AssertEqual("the", _LLM_Bridge_Buffer,
		"AHK-23: when the LLM buffer is shorter than the trigger (drift), the replacement must still be set correctly (buffer cleared then replacement appended)")
	_TLBAE_Teardown()
}


Test("unit ahk-23: LLM_Bridge_ApplyExpansionIfActive strips trigger and appends replacement for star triggers",
	_TLBAE_TestStarTriggerNoEndChar)

Test("unit ahk-23: LLM_Bridge_ApplyExpansionIfActive strips trigger and appends replacement + end char for end-char triggers",
	_TLBAE_TestEndCharExpansion)

Test("unit ahk-23: LLM_Bridge_ApplyExpansionIfActive is a no-op when bridge is inactive",
	_TLBAE_TestInactiveIsNoOp)

Test("unit ahk-23: LLM_Bridge_ApplyExpansionIfActive handles drifted buffer (shorter than trigger) gracefully",
	_TLBAE_TestBufferShorterThanTrigger)
