; static/ergopti_plus/windows/tests/test_inline_autotype_not_synthetic.ahk

; ==============================================================================
; MODULE: Inline Auto-type Synthetic-Tag Regression Test
; DESCRIPTION:
; Behavioural regression test for finding ``inline-autotype-not-synthetic``.
;
; In inline auto-type (Copilot-style) mode, LLM_Engine_OnResults injects the
; prediction directly into the document via TextSend. Those synthetic keystrokes
; re-enter the PrefixWatcher InputHook. Before the fix the engine did NOT tag the
; burst as synthetic, so the keylogger counted the model output as words the
; HUMAN typed (PII corruption + inflated WPM). It also never advanced the rolling
; context buffer, so the next prediction ran against stale context.
;
; The fix mirrors LLM_Bridge_OnAccept: KL_MarkSynthetic("llm") before TextSend,
; a deferred KL_ClearSynthetic() after, and an append of the inserted text to
; _LLM_Bridge_Buffer so the engine's context stays in sync with the document.
;
; LLM_Engine_OnResults is in the run_all include graph; KL_MarkSynthetic /
; KL_ClearSynthetic are stubbed (test_stubs.ahk, depth-counter on
; Keylogger.synth_active) and TextSend is the no-op'd adapter, so this is a
; headless-safe behavioural test. KL_ClearSynthetic is deferred via a negative
; SetTimer, so it never fires synchronously during the call and the synthetic
; depth stays incremented when we assert immediately after.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Synthetic-tag + buffer-advance =========
; ===================================================
; ===================================================

_IANS_InlineMarksSyntheticAndAdvancesBuffer() {
	global _LLM_Engine, _LLM_Bridge_Buffer
	; The keylogger stub tracks synthetic depth via Keylogger.synth_active.
	Keylogger.synth_active := 0
	Keylogger.synth_type   := "none"
	; Enable inline auto-type so LLM_Engine_OnResults takes the inject branch.
	_LLM_Engine := Map("inline_autotype", true)
	_LLM_Bridge_Buffer := "je voudrais "

	LLM_Engine_OnResults(["vous remercier"], "je voudrais ", 1, true)

	; (a) KL_MarkSynthetic("llm") must have run before TextSend. The deferred
	; KL_ClearSynthetic has not fired yet (negative SetTimer), so the depth is
	; still incremented and the source recorded.
	Assert(Keylogger.synth_active >= 1,
		"inline auto-type must call KL_MarkSynthetic before TextSend so model output is not counted as manual keystrokes")
	AssertEqual("llm", Keylogger.synth_type,
		"inline auto-type must tag the synthetic burst with the 'llm' source")

	; (b) The rolling context buffer must be advanced by the inserted text so the
	; next prediction sees what the document actually contains, not stale context.
	AssertEqual("je voudrais vous remercier", _LLM_Bridge_Buffer,
		"inline auto-type must append the inserted text to _LLM_Bridge_Buffer to keep context in sync with the document")
}
Test("prediction_engine: inline auto-type marks synthetic and advances buffer (inline-autotype-not-synthetic)", _IANS_InlineMarksSyntheticAndAdvancesBuffer)
