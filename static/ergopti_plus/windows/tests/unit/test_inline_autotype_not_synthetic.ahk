; static/ergopti_plus/windows/tests/unit/test_inline_autotype_not_synthetic.ahk

; ==============================================================================
; MODULE: Inline Auto-type Synthetic-Tag Regression Test
; DESCRIPTION:
; Behavioural regression test for finding ``inline-autotype-not-synthetic``.
;
; In inline auto-type (Copilot-style) mode, LLM_Engine_OnResults injects the
; prediction through TextSender's SendInput transaction. SendInput is ignored by
; InputHook, so a queue-wide synthetic flag is both unnecessary and harmful: it
; misclassifies physical input while a clipboard request waits. The state commit
; must instead advance every RAM mirror under Critical after the OS primitive.
; Completion owns only metrics and must never commit absent output by itself.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Sender-confirmed buffer advance =========
; ===================================================
; ===================================================

_IANS_InlineCompletionCommitsOnlySuccessfulOutput() {
	global _LLM_Engine, _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration
	global HSE_Buffer, HSE_StartIsWordBoundary
	global _PrefixBuffer, _PrefixFocusedControlToken
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	global _LSC_RING, _LSC_CURSOR, _LSC_LEN
	Saved := {
		Engine: _LLM_Engine,
		Bridge: _LLM_Bridge_Buffer,
		BridgeGeneration: _LLM_Bridge_ContentGeneration,
		Hse: HSE_Buffer,
		HseBoundary: HSE_StartIsWordBoundary,
		Prefix: _PrefixBuffer,
		PrefixControl: _PrefixFocusedControlToken,
		PrefixGeneration: _PrefixContentGeneration,
		ContextGeneration: _PrefixInputContextGeneration,
		LscRing: _LSC_RING.Clone(),
		LscCursor: _LSC_CURSOR,
		LscLen: _LSC_LEN
	}
	try {
		_LLM_Engine := Map("inline_autotype", true, "inline_last_typed", "")
		_LLM_Bridge_Buffer := "je voudrais "
		HSE_Buffer := "stale"
		_PrefixBuffer := "stale"
		Transaction := {
			Text: "vous remercier",
			Inline: true,
			SourceControl: 1001,
			Slots: ["vous remercier"],
			ActiveIdx: 1,
			SourceHwnd: 100
		}
		PreviousCritical := Critical("On")
		try
			Finalizer := _LLM_Bridge_CommitInjectedText(Transaction)
		finally
			Critical(PreviousCritical)
		AssertTrue(HasMethod(Finalizer, "Call"),
			"the atomic RAM commit may return only open-thread presentation work")
		AssertEqual("je voudrais vous remercier", _LLM_Bridge_Buffer,
			"inline output must enter rolling context in the sender-owned commit")
		AssertEqual("vous remercier", _LLM_Engine["inline_last_typed"],
			"inline_last_typed must publish in the same commit as visible output")
		AssertEqual("", HSE_Buffer,
			"the atomic output commit must invalidate the pre-output HSE context")
		AssertEqual("", _PrefixBuffer,
			"the atomic output commit must invalidate the pre-output preview context")
		AssertEqual("r", GetLastSentCharacterAt(-1),
			"the last-sent ring must end at the injected text in the same transaction")

		BeforeFailure := _LLM_Bridge_Buffer
		LLM_Engine_OnInlineInjectComplete(Transaction, false, "simulated sender failure")
		AssertEqual(BeforeFailure, _LLM_Bridge_Buffer,
			"a failure completion alone must never advance context without output")
	} finally {
		_LLM_Engine := Saved.Engine
		_LLM_Bridge_Buffer := Saved.Bridge
		_LLM_Bridge_ContentGeneration := Saved.BridgeGeneration
		HSE_Buffer := Saved.Hse
		HSE_StartIsWordBoundary := Saved.HseBoundary
		_PrefixBuffer := Saved.Prefix
		_PrefixFocusedControlToken := Saved.PrefixControl
		_PrefixContentGeneration := Saved.PrefixGeneration
		_PrefixInputContextGeneration := Saved.ContextGeneration
		_LSC_RING := Saved.LscRing
		_LSC_CURSOR := Saved.LscCursor
		_LSC_LEN := Saved.LscLen
	}
}
Test("prediction_engine: inline auto-type commits context only after sender success (inline-autotype-not-synthetic)", _IANS_InlineCompletionCommitsOnlySuccessfulOutput)
