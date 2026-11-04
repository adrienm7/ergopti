; infra/ai_action_gate.ahk

; ==============================================================================
; MODULE: AI Action Gate
; DESCRIPTION:
; With the AI switched off nothing of it runs: a key bound to an AI action
; (llm_* in the shared catalogue) is not armed, so the key reaches the
; application instead of being claimed and refused. Switching the AI back on
; arms the keys again with no reload.
;
; FEATURES & RATIONALE:
; 1. One predicate for every key-claiming layer (tap-hold taps, tap keys, script
;    chords, keyboard slots, ordered pairs, the physical Win broker) and for the
;    gestures, so the layers cannot disagree about which actions the switch
;    covers. The same rule holds on macOS and Linux (ai_actions.lua).
; 2. Asked from #HotIf criteria on every press, so it only reads memory. Its own
;    file because the standalone harnesses load a key layer without the gestures
;    or the AI menu: only an AI action ever reads the switch.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Whether an action id is an AI action (prediction, prompts, screen reading,
 * tone, translation, agent, live mode).
 * @param {Any} Action An action id.
 * @returns {Boolean}
 */
AiActionIsAi(Action) {
	static Prefix := "llm_"
	return (Action is String) && SubStr(Action, 1, StrLen(Prefix)) == Prefix
}

/**
 * Whether a binding to this action must be left unarmed right now: an AI action
 * while the AI is switched off.
 * @param {Any} Action An action id.
 * @returns {Boolean}
 */
AiActionBlocked(Action) {
	return AiActionIsAi(Action) && !LLM_Menu_AiEnabled()
}
