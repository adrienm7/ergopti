; tests/meta/test_tickcount_wrap_safe.ahk

; ==============================================================================
; MODULE: A_TickCount Wrap-Safe Delta Formula Guard
; DESCRIPTION:
; Static source guard for the A_TickCount wrap-safe formula fix in
; modules/llm/prediction_engine.ahk and modules/keymap/llm_bridge.ahk.
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
	; Move-resilient: the debounce-rate-limit wrap-safe delta used to live
	; directly in modules/llm/prediction_engine.ahk, but that logic now lives
	; in LLM_Engine_FirePrediction (modules/llm/prediction_exec.ahk) after the
	; engine was split — scan the function body by name across the whole
	; driver so a further file move cannot go unnoticed.
	Src := _TTCWS_StripLineComments(_DriverFuncBody("LLM_Engine_FirePrediction"))
	Assert(Src != "", "LLM_Engine_FirePrediction must exist in the LLM prediction module")

	; Both halves of the formula must be present
	Assert(InStr(Src, "0x100000000") > 0,
		"LLM_Engine_FirePrediction must use the wrap-safe constant 0x100000000 in TickCount delta computation")
	Assert(InStr(Src, "0xFFFFFFFF") > 0,
		"LLM_Engine_FirePrediction must mask with 0xFFFFFFFF in wrap-safe TickCount delta computation")
}
Test("prediction_engine: TickCount delta uses wrap-safe (now - last + 0x100000000) & 0xFFFFFFFF formula", _TTCWS_PredictionEngineWrapSafe)


; ==========================================================================
; ==========================================================================
; ======= 2/ llm_bridge.ahk uses the wrap-safe formula =====================
; ==========================================================================
; ==========================================================================

_TTCWS_LlmBridgeWrapSafe() {
	Src := _TTCWS_StripLineComments(_TTCWS_ReadSource("modules/keymap/llm_bridge.ahk"))
	Assert(Src != "", "modules/keymap/llm_bridge.ahk must be readable")

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
	; Scan the whole wpm module (init.ahk + wpm_widget.ahk after the F3 split).
	Src := _TTCWS_StripLineComments(_DriverDirConcat("ui/wpm"))
	Assert(Src != "", "ui/wpm sources must be readable")

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
	; Move-resilient: LLM_OllamaAllowInference used to live directly in
	; modules/llm/api_ollama.ahk, but that file is now a thin #Include redirect
	; shim to api_ollama/ollama_http.ahk (post-split) — scan the function body
	; by name across the whole driver so a further file move cannot go unnoticed.
	Src := _TTCWS_StripLineComments(_DriverFuncBody("LLM_OllamaAllowInference"))
	Assert(Src != "", "LLM_OllamaAllowInference must exist in the Ollama API module")

	; Negative: bare subtraction on warmup tick must not appear in a comparison
	Assert(!InStr(Src, "(A_TickCount - _LLM_Ollama_WarmupStartedTick) >= 8000"),
		"LLM_OllamaAllowInference must not compare warmup elapsed time without & 0xFFFFFFFF mask (tickcount-wrap)")

	; Positive: masked form must be present
	Assert(InStr(Src, "(_LLM_Ollama_WarmupStartedTick) & 0xFFFFFFFF) >= 8000") > 0,
		"LLM_OllamaAllowInference must mask warmup elapsed comparison with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("api_ollama: warmup elapsed comparison uses & 0xFFFFFFFF mask (tickcount-wrap)", _TTCWS_OllamaWarmupWrapSafe)
