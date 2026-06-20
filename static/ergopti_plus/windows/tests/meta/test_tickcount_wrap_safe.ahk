; tests/meta/test_tickcount_wrap_safe.ahk

; ==============================================================================
; MODULE: A_TickCount Wrap-Safe Delta Formula Guard
; DESCRIPTION:
; Static source guard for the A_TickCount wrap-safe formula fix in
; modules/llm/prediction_engine.ahk and modules/llm/llm_bridge.ahk.
;
; ROOT CAUSE ENCODED:
; A_TickCount is a 32-bit unsigned counter that wraps from 0xFFFFFFFF back to 0
; approximately every 49.7 days. A naive delta (now - last) becomes a large
; negative number just after wrap, breaking elapsed-time comparisons. The fix
; uses the wrap-safe formula:
;   elapsed := (now - last + 0x100000000) & 0xFFFFFFFF
; which keeps the result in [0, 0xFFFFFFFF] regardless of counter direction and
; produces the correct unsigned delta after a wrap event.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTCWS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TTCWS_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ==========================================================================
; ==========================================================================
; ======= 1/ prediction_engine.ahk uses the wrap-safe formula ==============
; ==========================================================================
; ==========================================================================

_TTCWS_PredictionEngineWrapSafe() {
	Src := _TTCWS_StripLineComments(_TTCWS_ReadSource("modules/llm/prediction_engine.ahk"))
	Assert(Src != "", "modules/llm/prediction_engine.ahk must be readable")

	; Both halves of the formula must be present
	Assert(InStr(Src, "0x100000000") > 0,
		"prediction_engine.ahk must use the wrap-safe constant 0x100000000 in TickCount delta computation")
	Assert(InStr(Src, "0xFFFFFFFF") > 0,
		"prediction_engine.ahk must mask with 0xFFFFFFFF in wrap-safe TickCount delta computation")
}
Test("prediction_engine: TickCount delta uses wrap-safe (now - last + 0x100000000) & 0xFFFFFFFF formula", _TTCWS_PredictionEngineWrapSafe)


; ==========================================================================
; ==========================================================================
; ======= 2/ llm_bridge.ahk uses the wrap-safe formula =====================
; ==========================================================================
; ==========================================================================

_TTCWS_LlmBridgeWrapSafe() {
	Src := _TTCWS_StripLineComments(_TTCWS_ReadSource("modules/llm/llm_bridge.ahk"))
	Assert(Src != "", "modules/llm/llm_bridge.ahk must be readable")

	Assert(InStr(Src, "0x100000000") > 0,
		"llm_bridge.ahk must use the wrap-safe constant 0x100000000 in TickCount delta computation")
	Assert(InStr(Src, "0xFFFFFFFF") > 0,
		"llm_bridge.ahk must mask with 0xFFFFFFFF in wrap-safe TickCount delta computation")
}
Test("llm_bridge: TickCount delta uses wrap-safe (now - last + 0x100000000) & 0xFFFFFFFF formula", _TTCWS_LlmBridgeWrapSafe)




; ==========================================================================
; ==========================================================================
; ======= 3/ lib/logger.ahk uses the wrap-safe ERROR dedup formula (F38) ===
; ==========================================================================
; ==========================================================================

_TTCWS_LoggerWrapSafe() {
	Src := _TTCWS_StripLineComments(_TTCWS_ReadSource("lib/logger.ahk"))
	Assert(Src != "", "lib/logger.ahk must be readable")

	; Both halves of the wrap-safe formula must be present in the ERROR dedup path
	Assert(InStr(Src, "0x100000000") > 0,
		"lib/logger.ahk must use the wrap-safe constant 0x100000000 in ERROR dedup TickCount delta (F38)")
	Assert(InStr(Src, "0xFFFFFFFF") > 0,
		"lib/logger.ahk must mask with 0xFFFFFFFF in ERROR dedup TickCount delta (F38)")
}
Test("logger: ERROR dedup TickCount delta uses wrap-safe (now - last + 0x100000000) & 0xFFFFFFFF formula (F38)", _TTCWS_LoggerWrapSafe)




; ==========================================================================
; ==========================================================================
; ======= 4/ wpm_widget.ahk uses the wrap-safe formula (F35) ===============
; ==========================================================================
; ==========================================================================

_TTCWS_WpmWidgetWrapSafe() {
	Src := _TTCWS_StripLineComments(_TTCWS_ReadSource("ui/wpm_widget.ahk"))
	Assert(Src != "", "ui/wpm_widget.ahk must be readable")

	; The wrap-safe delta helper must be present — this constant cannot appear in
	; color values (ARGB uses 0xFFFFFFFF, not 0x100000000), so its presence
	; unambiguously confirms the wrap-safe formula was applied (F35 fix).
	Assert(InStr(Src, "0x100000000") > 0,
		"wpm_widget.ahk must use the wrap-safe constant 0x100000000 in TickCount delta computation (F35)")
}
Test("wpm_widget: TickCount delta uses wrap-safe (now - last + 0x100000000) & 0xFFFFFFFF formula (F35)", _TTCWS_WpmWidgetWrapSafe)




; ========================================================================
; ========================================================================
; ======= 5/ api_ollama.ahk -- warmup elapsed comparison (tickcount-wrap)
; ========================================================================
; ========================================================================

_TTCWS_OllamaWarmupWrapSafe() {
	Src := _TTCWS_StripLineComments(_TTCWS_ReadSource("modules/llm/api_ollama.ahk"))
	Assert(Src != "", "modules/llm/api_ollama.ahk must be readable")

	; Negative: bare subtraction on warmup tick must not appear in a comparison
	Assert(!InStr(Src, "(A_TickCount - _LLM_Ollama_WarmupStartedTick) >= 8000"),
		"api_ollama.ahk must not compare warmup elapsed time without & 0xFFFFFFFF mask (tickcount-wrap)")

	; Positive: masked form must be present
	Assert(InStr(Src, "(_LLM_Ollama_WarmupStartedTick) & 0xFFFFFFFF) >= 8000") > 0,
		"api_ollama.ahk must mask warmup elapsed comparison with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("api_ollama: warmup elapsed comparison uses & 0xFFFFFFFF mask (tickcount-wrap)", _TTCWS_OllamaWarmupWrapSafe)
