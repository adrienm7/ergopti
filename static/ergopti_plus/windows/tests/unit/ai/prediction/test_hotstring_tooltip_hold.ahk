; static/ergopti_plus/windows/tests/unit/ai/prediction/test_hotstring_tooltip_hold.ahk

; ==============================================================================
; MODULE: AI Prediction While a Hotstring Tooltip Shows (Windows)
; DESCRIPTION:
; Drives the automatic typing trigger through the real bridge and engine, with
; the network and the tooltip faked as in test_live_mode.ahk, whose fixture
; this file reuses. Pins llm.trigger.while_hotstring_tooltip: "wait" (the
; default) never lets a prediction cover a hotstring tooltip that can still
; expand, "both" runs the prediction beside it.
;
; ROOT CAUSE ENCODED:
; Only live mode re-checked the hotstring tooltip when the debounce fired and
; when the answer rendered. An ordinary request armed before the tooltip
; appeared, or answering while it showed, replaced it on the one shared
; surface and retired a hotstring the user could still expand.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ Shared fixture =======
; =================================
; =================================

; The live-mode fixture with an ordinary request admitted: one prediction, no
; word floor, and the hotstring choice the scenario names.
_LHTH_Run(Buffer, Choice, Body) {
	_LLV_Run(Buffer, _Inner)
	_Inner(Calls, Lines, Builds) {
		global _LLM_Engine
		_LLM_Engine[ConfigLeaf.MIN_WORDS] := 1
		_LLM_Engine["n_predictions"] := 1
		_LLM_Engine[ConfigLeaf.WHILE_HOTSTRING_TOOLTIP] := Choice
		Body(Calls, Lines)
	}
}

; The advanced profile's answer for "Je vous envoi…".
global LHTH_ANSWER := "TAIL_CORRECTED: Je vous envoie`nNEXT_WORDS: ce mail"





; ======================================
; ======================================
; ======= 2/ Wait (the default) ========
; ======================================
; ======================================

; The manifest owns the default, and it is to wait.
_LHTH_DefaultWaits() {
	global _LLM_Engine
	Saved := _LLM_Engine
	try {
		_LLM_Engine := Saved.Clone()
		if _LLM_Engine.Has(ConfigLeaf.WHILE_HOTSTRING_TOOLTIP)
			_LLM_Engine.Delete(ConfigLeaf.WHILE_HOTSTRING_TOOLTIP)
		AssertEqual(ManifestDefaultFor(ConfigKey.LLM_TRIGGER_WHILE_HOTSTRING_TOOLTIP),
			LLM_Engine_WhileHotstringTooltip(), "an engine without the option reads the manifest default")
		AssertEqual("wait", LLM_Engine_WhileHotstringTooltip(), "the shipped default waits")
	} finally {
		_LLM_Engine := Saved
	}
	AssertTrue(LLM_Option_TryNormalize(ConfigLeaf.WHILE_HOTSTRING_TOOLTIP, "both", &Both), "both is a value")
	AssertEqual("both", Both)
	AssertFalse(LLM_Option_TryNormalize(ConfigLeaf.WHILE_HOTSTRING_TOOLTIP, "always", &Refused),
		"a value the manifest does not list is refused")
	AssertFalse(LLM_Option_TryNormalize(ConfigLeaf.WHILE_HOTSTRING_TOOLTIP, 1, &Refused),
		"a non-string is refused")
}
Test("LLM hotstring tooltip: the manifest default waits (llm-hotstring-tooltip-wait)", _LHTH_DefaultWaits)

; An ordinary request armed before the preview appeared, or answering while it
; shows, never covers it; the request goes out once the preview is gone.
_LHTH_WaitNeverCoversThePreview() {
	_LHTH_Run("Je vous envoi", "wait", _Body)
	_Body(Calls, Lines) {
		global _TooltipActiveSurface
		Armed := _LLV_Type("t")
		_TooltipActiveSurface := {}
		AssertTrue(TooltipIsVisible(), "precondition: a hotstring tooltip is shown")
		_LLV_Fire(Armed)
		AssertEqual(0, Calls.Length, "a request armed before the preview waits for it")

		; The same text and answer as the control scenario below, which renders.
		_TooltipActiveSurface := 0
		_LLV_Fire(_LLV_Type(""))
		AssertEqual(1, Calls.Length, "the request is sent once the preview is gone")
		_TooltipActiveSurface := {}
		_LPP_Answer(Calls[1], LHTH_ANSWER)
		AssertEqual("", _LPP_LastFinalRender(), "an answer landing under a preview does not cover it")
		_TooltipActiveSurface := 0
	}
}
Test("LLM hotstring tooltip: waiting never covers a preview that can still expand (llm-hotstring-tooltip-wait)",
	_LHTH_WaitNeverCoversThePreview)

; Typing under the preview arms nothing while waiting.
_LHTH_WaitArmsNothingUnderThePreview() {
	_LHTH_Run("Je vous envoi", "wait", _Body)
	_Body(Calls, Lines) {
		global _TooltipActiveSurface
		_TooltipActiveSurface := {}
		Captured := _LLV_CaptureRealTimer(() => LLM_Bridge_OnChar("t"))
		AssertFalse(Captured.Active, "typing under a hotstring tooltip arms nothing")
		_TooltipActiveSurface := 0
		Captured := _LLV_CaptureRealTimer(() => LLM_Bridge_OnChar(" "))
		AssertTrue(Captured.Active, "the same keystroke arms once the preview is gone")
	}
}
Test("LLM hotstring tooltip: typing under a preview arms nothing while waiting (llm-hotstring-tooltip-wait)",
	_LHTH_WaitArmsNothingUnderThePreview)

; The control of the scenario above: without a preview the same answer renders.
_LHTH_AnswerRendersWithoutAPreview() {
	_LHTH_Run("Je vous envoit", "wait", _Body)
	_Body(Calls, Lines) {
		_LLV_Fire(_LLV_Type(""))
		AssertEqual(1, Calls.Length, "the request is sent")
		_LPP_Answer(Calls[1], LHTH_ANSWER)
		AssertTrue(IsObject(_LPP_LastFinalRender()), "with no preview shown the answer renders")
	}
}
Test("LLM hotstring tooltip: with no preview the answer renders (llm-hotstring-tooltip-wait)",
	_LHTH_AnswerRendersWithoutAPreview)

; A prompt the user asked for by name is never held.
_LHTH_PromptActionIsNotHeld() {
	_LHTH_Run("Je vous envoit", "wait", _Body)
	_Body(Calls, Lines) {
		global _TooltipActiveSurface
		_TooltipActiveSurface := {}
		LLM_Engine_FirePrediction("Je vous envoit", , Map("profile_id", "advanced", "num_predictions", 1))
		AssertEqual(1, Calls.Length, "a prompt asked for by name is dispatched")
		_LPP_Answer(Calls[1], LHTH_ANSWER)
		AssertTrue(IsObject(_LPP_LastFinalRender()), "and rendered")
		_TooltipActiveSurface := 0
	}
}
Test("LLM hotstring tooltip: a prompt asked for by name is not held (llm-hotstring-tooltip-wait)",
	_LHTH_PromptActionIsNotHeld)

; Waiting keeps the chain after the preview; showing both drops it, since the
; prediction already runs beside the preview.
_LHTH_ChainFollowsTheChoice() {
	for Choice, Expected in Map("wait", true, "both", false)
		_LHTH_Run("Je vous envoit", Choice, _LHTH_AssertChain.Bind(Choice, Expected))
}

; One run of the scenario above, for one choice and the chain it expects.
_LHTH_AssertChain(Choice, Expected, Calls, Lines) {
	global _LLM_Engine
	_LLM_Engine["after_hotstring"] := true
	Chain := _LLV_CaptureRealTimer(
		() => LLM_Bridge_ScheduleAfterHotstring([{ Text: "x", DurationSec: 0.2 }]))
	AssertEqual(Expected, Chain.Active ? true : false,
		"the chain after the preview follows llm.trigger.while_hotstring_tooltip (" . Choice . ")")
}
Test("LLM hotstring tooltip: the chain after the preview follows the choice (llm-hotstring-tooltip-both)",
	_LHTH_ChainFollowsTheChoice)





; ==============================
; ==============================
; ======= 3/ Show both =========
; ==============================
; ==============================

; Shown together, the keystroke arms and the answer renders beside the preview.
_LHTH_BothRunsBesideThePreview() {
	_LHTH_Run("Je vous envoi", "both", _Body)
	_Body(Calls, Lines) {
		global _TooltipActiveSurface
		_TooltipActiveSurface := {}
		AssertTrue(TooltipIsVisible(), "precondition: a hotstring tooltip is shown")
		Captured := _LLV_CaptureRealTimer(() => LLM_Bridge_OnChar("t"))
		AssertTrue(Captured.Active, "typing under the preview arms the prediction")
		_LLV_Fire(Map("fn", Captured.Fn))
		AssertEqual(1, Calls.Length, "the request runs while the preview shows")
		_LPP_Answer(Calls[1], LHTH_ANSWER)
		AssertTrue(IsObject(_LPP_LastFinalRender()), "the answer renders beside the preview")
		_TooltipActiveSurface := 0
	}
}
Test("LLM hotstring tooltip: showing both runs the prediction beside the preview (llm-hotstring-tooltip-both)",
	_LHTH_BothRunsBesideThePreview)

; Live mode always waits, whatever the choice: its tooltip follows every keystroke.
_LHTH_LiveAlwaysWaits() {
	_LHTH_Run("on se voit", "both", _Body)
	_Body(Calls, Lines) {
		global _TooltipActiveSurface
		AssertTrue(_LLV_Toggle("translate_en|1"), "live mode on")
		Armed := _LLV_Type(" de")
		_TooltipActiveSurface := {}
		_LLV_Fire(Armed)
		AssertEqual(0, Calls.Length, "a live request waits for the preview even when both are shown")
		_TooltipActiveSurface := 0
	}
}
Test("LLM hotstring tooltip: live mode always waits for the preview (llm-hotstring-tooltip-both)",
	_LHTH_LiveAlwaysWaits)
