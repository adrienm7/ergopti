; tests/meta/test_llm_autotype_hse_suppress.ahk

; ==============================================================================
; MODULE: LLM Auto-type HSE Suppress Meta Test
; DESCRIPTION:
; Static source guard for the llm-autotype-no-hse-suppress finding.
;
; LLM_Bridge_OnAccept (Tab-accept) and LLM_Engine_OnResults (inline auto-type)
; both call TextSend to inject the prediction text. Atomic mode uses SendInput,
; which InputHook ignores, and commits HSE plus preview state after the OS output
; without holding a suppression guard across the clipboard FIFO.
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
	Assert(InStr(Body, "_LLM_Bridge_InjectionOptions(Transaction)") > 0
			and InStr(Body, "PrefixWatcherSuppress") = 0,
		"manual acceptance must use atomic InputHook-invisible output, not queue-wide prefix suppression")
}
Test("llm_bridge: LLM_Bridge_OnAccept calls PrefixWatcherSuppress to suppress hotstring observation during inject (llm-autotype-no-hse-suppress)", _LAHS_AcceptSuppressesBefore)

_LAHS_AcceptResetsHSE() {
	Body := _DriverFuncBody("_LLM_Bridge_CommitInjectedText")
	Assert(Body != "" and InStr(Body, "_PrefixCommitInputContext") > 0
			and InStr(Body, "if !A_IsCritical") > 0,
		"manual acceptance must reset HSE and preview inside the successful atomic output commit")
}
Test("llm_bridge: successful LLM inject completion resets HSE after output lands (llm-autotype-no-hse-suppress)", _LAHS_AcceptResetsHSE)




; ===================================================
; ===================================================
; ======= 3/ Inline auto-type assertions ============
; ===================================================
; ===================================================

_LAHS_InlineAutoTypeSuppresses() {
	Body := _DriverFuncBody("LLM_Engine_OnResults")
	Assert(Body != "", "LLM_Engine_OnResults must exist in modules/llm/prediction_exec.ahk")
	Assert(InStr(Body, "_LLM_Bridge_InjectionOptions(Transaction)") > 0
			and InStr(Body, "PrefixWatcherSuppress") = 0,
		"inline auto-type must use atomic InputHook-invisible output, not queue-wide prefix suppression")
}
Test("prediction_engine: inline auto-type calls PrefixWatcherSuppress before TextSend (llm-autotype-no-hse-suppress)", _LAHS_InlineAutoTypeSuppresses)

_LAHS_InlineAutoTypeResetsHSE() {
	Body := _DriverFuncBody("_LLM_Bridge_CommitInjectedText")
	Complete := _DriverFuncBody("LLM_Engine_OnInlineInjectComplete")
	Assert(InStr(Body, "_PrefixCommitInputContext") > 0
			and InStr(Complete, "HSE_HardReset") = 0,
		"inline HSE state must commit atomically with output and never be rewritten by open-thread completion")
}
Test("prediction_engine: successful inline output completion resets HSE (llm-autotype-no-hse-suppress)", _LAHS_InlineAutoTypeResetsHSE)
