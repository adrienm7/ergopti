; tests/meta/test_llm_inline_autotype_staleness.ahk

; ==============================================================================
; MODULE: LLM Inline Auto-Type Staleness Gate Meta Test
; DESCRIPTION:
; Regression guard for llm-inline-autotype-injects-superseded-prediction.
;
; LLM_Engine_OnResults ends with a staleness gate whose own comment explains why
; it is needed: LLM_Diff_Compute runs a RegExMatch per character over each slot
; and the display-opts resolution queries the focused window, so this thread can
; be pre-empted between the caller's check and the paint. If the prediction has
; been superseded in that window, the render is discarded.
;
; ROOT CAUSE ENCODED: the inline auto-type branch sits ~35 lines ABOVE that gate
; and RETURNS, so it never reached it. The two outcomes are not comparable. A
; superseded tooltip paints a stale suggestion the user can ignore; a superseded
; inline auto-type SendTexts model output for text the user has already abandoned
; straight into their document, and nothing takes it back.
;
; The invariant: every path that acts on a FINAL result must clear the same
; staleness gate, and each must clear it before it acts — not after.
;
; SCOPE: source introspection by position. Driving the branch needs a live LLM
; request, a focused window and the tooltip stack; the ORDER of the gate relative
; to the injection is the whole property, and order is observable statically.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================================
; =====================================================================
; ======= 1/ The inline branch is gated before it injects ==============
; =====================================================================
; =====================================================================

_LIAS_Body() {
	Body := _DriverFuncBody("LLM_Engine_OnResults")
	Assert(Body != "", "LLM_Engine_OnResults() must exist in the driver source")
	return Body
}

_LIAS_InlineInjectionIsGated() {
	Body := _LIAS_Body()

	; Non-vacuity: the branch and the gate must both still be there, or the
	; ordering assertions below would pass against code that lost one of them.
	InjectPos := InStr(Body, "TextSend(text,")
	Assert(InjectPos > 0,
		"prerequisite: LLM_Engine_OnResults must still perform the inline auto-type injection — without it this "
		. "guard measures nothing")

	GateCount := 0
	Pos := 1
	while (Found := InStr(Body, "_LLM_Engine_IsCurrent(", , Pos)) {
		GateCount += 1
		Pos := Found + 1
	}
	Assert(GateCount >= 2,
		"both the inline auto-type path and the tooltip render path must consult the staleness gate (found "
		. GateCount . " call(s)). One gate means one of the two paths is still acting on a superseded prediction "
		. "(llm-inline-autotype-injects-superseded-prediction)")

	FirstGate := InStr(Body, "_LLM_Engine_IsCurrent(")
	Assert(FirstGate < InjectPos,
		"the staleness gate must be checked BEFORE the inline auto-type injects. Sitting below it — where the "
		. "tooltip render's gate is — leaves this branch returning before the check ever runs, and a superseded "
		. "prediction is SendText'd into the user's document for text they already abandoned "
		. "(llm-inline-autotype-injects-superseded-prediction)")

	; The gate must guard the injection, not merely precede it: a bail-out has to
	; return before any of the injection's side effects are armed.
	Between := SubStr(Body, FirstGate, InjectPos - FirstGate)
	Assert(InStr(Between, "return") > 0,
		"the staleness gate before the injection must RETURN on a supersede — logging it and falling through would "
		. "inject the stale text anyway")

	; The synthetic-guard and metrics side effects must also sit AFTER the gate, or
	; a superseded result still marks synthetic input and counts a suggestion.
	MarkPos := InStr(Body, "KL_MarkSynthetic(")
	Assert(MarkPos > 0, "prerequisite: the inline path must still tag its injection as synthetic")
	Assert(FirstGate < MarkPos,
		"the staleness gate must precede the synthetic tagging and the suggestion accounting too: a superseded "
		. "result that still marks synthetic input leaves the keylogger's guard depth and the suggested/accepted "
		. "pairing describing an injection that never happened")
}

; Suspend is the OTHER reason this branch must not act, and it was already
; handled. Pin it so the new gate cannot be introduced by replacing it.
_LIAS_SuspendGateSurvives() {
	Body := _LIAS_Body()
	SuspendPos := InStr(Body, "A_IsSuspended")
	InjectPos := InStr(Body, "TextSend(text,")
	Assert(SuspendPos > 0 and SuspendPos < InjectPos,
		"the inline auto-type must still refuse to inject while the driver is suspended — a paused driver must "
		. "produce ZERO synthetic foreground input, and this check must stay ahead of the injection")
}


Test("meta llm-inline: the auto-type path clears the staleness gate before injecting (llm-inline-autotype-injects-superseded-prediction)",
	_LIAS_InlineInjectionIsGated)
Test("meta llm-inline: the auto-type path still refuses to inject while suspended (llm-inline-autotype-injects-superseded-prediction)",
	_LIAS_SuspendGateSurvives)
