; static/ergopti_plus/windows/tests/unit/test_inline_autotype_not_synthetic.ahk

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
; then commits the inserted text to _LLM_Bridge_Buffer only from the sender's
; successful completion callback. A failed clipboard/direct injection must leave
; the rolling context unchanged, because the document did not receive the text.
;
; LLM_Engine_OnInlineInjectComplete is in the run_all include graph. Calling
; that completion directly keeps this regression test headless-safe while still
; exercising the causal state boundary: no output confirmation, no context commit.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Sender-confirmed buffer advance =========
; ===================================================
; ===================================================

_IANS_InlineCompletionCommitsOnlySuccessfulOutput() {
	global _LLM_Engine, _LLM_Bridge_Buffer
	_LLM_Engine := Map("inline_autotype", true)
	_LLM_Bridge_Buffer := "je voudrais "

	LLM_Engine_OnInlineInjectComplete("vous remercier", true)
	; A successful sender completion means the visible document contains text;
	; only then may the next prediction consume it as context.
	AssertEqual("je voudrais vous remercier", _LLM_Bridge_Buffer,
		"inline auto-type must append only sender-confirmed output to _LLM_Bridge_Buffer")
	AssertEqual("vous remercier", _LLM_Engine["inline_last_typed"],
		"inline auto-type must publish inline_last_typed only after sender success")

	LLM_Engine_OnInlineInjectComplete(" qui echoue", false, "simulated sender failure")
	AssertEqual("je voudrais vous remercier", _LLM_Bridge_Buffer,
		"failed inline injection must not advance context with output absent from the document")
	AssertEqual("vous remercier", _LLM_Engine["inline_last_typed"],
		"failed inline injection must not replace the last confirmed output")
}
Test("prediction_engine: inline auto-type commits context only after sender success (inline-autotype-not-synthetic)", _IANS_InlineCompletionCommitsOnlySuccessfulOutput)
