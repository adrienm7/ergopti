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
