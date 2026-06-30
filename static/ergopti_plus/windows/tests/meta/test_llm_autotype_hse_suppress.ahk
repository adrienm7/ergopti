; tests/meta/test_llm_autotype_hse_suppress.ahk

; ==============================================================================
; MODULE: LLM Auto-type HSE Suppress Meta Test
; DESCRIPTION:
; Static source guard for the llm-autotype-no-hse-suppress finding.
;
; LLM_Bridge_OnAccept (Tab-accept) and LLM_Engine_OnResults (inline auto-type)
; both call TextSend to inject the prediction text. Without suppression, the
; injected characters pass through the hotstring InputHook and are observed by
; both HSE and the prefix watcher, potentially triggering a false hotstring
; match on the appended text (e.g. if the prediction ends with a known trigger).
;
; The fix wraps each TextSend with PrefixWatcherSuppress(true) before and a
; deferred PrefixWatcherSuppress(false) after (mirroring the HSE_DispatchMatch
; pattern). HSE_HardReset and _ResetPrefixBuffer are called synchronously after
; TextSend to clear the stale pre-prediction buffer state.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

; Extracts a window of source around Anchor and strips comments. The window
; reaches well past the anchor (the inline auto-type block carries verbose
; rationale comments between the anchor assignment and the HSE_HardReset call).
_LAHS_WindowStripped(Src, Anchor) {
	Idx := InStr(Src, Anchor)
	if !Idx
		return ""
	Start := Max(1, Idx - 500)
	Win := SubStr(Src, Start, 2500)
	Out := ""
	loop parse, Win, "`n", "`r" {
		Line := A_LoopField
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; ===================================================
; ===================================================
; ======= 2/ LLM_Bridge_OnAccept assertions =========
; ===================================================
; ===================================================

_LAHS_AcceptSuppressesBefore() {
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must exist in modules/keymap/llm_bridge.ahk")
	Assert(InStr(Body, "PrefixWatcherSuppress") > 0,
		"LLM_Bridge_OnAccept must call PrefixWatcherSuppress to mute the hotstring InputHook before injecting the prediction")
}
Test("llm_bridge: LLM_Bridge_OnAccept calls PrefixWatcherSuppress to suppress hotstring observation during inject (llm-autotype-no-hse-suppress)", _LAHS_AcceptSuppressesBefore)

_LAHS_AcceptResetsHSE() {
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must exist in modules/keymap/llm_bridge.ahk")
	Assert(InStr(Body, "HSE_HardReset") > 0,
		"LLM_Bridge_OnAccept must call HSE_HardReset() after TextSend to clear the stale pre-prediction buffer")
}
Test("llm_bridge: LLM_Bridge_OnAccept calls HSE_HardReset after TextSend to clear stale buffer (llm-autotype-no-hse-suppress)", _LAHS_AcceptResetsHSE)




; ===================================================
; ===================================================
; ======= 3/ Inline auto-type assertions ============
; ===================================================
; ===================================================

_LAHS_InlineAutoTypeSuppresses() {
	Src := _DriverDirConcat("modules/llm")
	; Use the unique "inline_last_typed" assignment as anchor — it is the line
	; immediately before the TextSend in the inline auto-type block.
	Win := _LAHS_WindowStripped(Src, "inline_last_typed")
	Assert(Win != "", "inline_last_typed must exist in modules/llm/prediction_engine.ahk")
	Assert(InStr(Win, "PrefixWatcherSuppress") > 0,
		"LLM_Engine_OnResults inline auto-type must call PrefixWatcherSuppress to mute the hotstring InputHook before TextSend")
}
Test("prediction_engine: inline auto-type calls PrefixWatcherSuppress before TextSend (llm-autotype-no-hse-suppress)", _LAHS_InlineAutoTypeSuppresses)

_LAHS_InlineAutoTypeResetsHSE() {
	Src := _DriverDirConcat("modules/llm")
	Win := _LAHS_WindowStripped(Src, "inline_last_typed")
	Assert(Win != "", "inline_last_typed must exist in modules/llm/prediction_engine.ahk")
	Assert(InStr(Win, "HSE_HardReset") > 0,
		"LLM_Engine_OnResults inline auto-type must call HSE_HardReset() after TextSend to clear the stale pre-prediction buffer")
}
Test("prediction_engine: inline auto-type calls HSE_HardReset after TextSend (llm-autotype-no-hse-suppress)", _LAHS_InlineAutoTypeResetsHSE)
