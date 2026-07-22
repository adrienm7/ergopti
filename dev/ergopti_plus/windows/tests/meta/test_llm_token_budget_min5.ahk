; tests/meta/test_llm_token_budget_min5.ahk

; ==============================================================================
; MODULE: LLM Engine CallTokenBudget Max(5) Guard
; DESCRIPTION:
; Static source guard for the _LLM_Engine_CallTokenBudget Max(5) fix in
; modules/llm/prediction_engine.ahk.
;
; ROOT CAUSE ENCODED:
; When the configured max_tokens was 0 or the computed product was very small,
; _LLM_Engine_CallTokenBudget could return 0 or a negative number, causing the
; downstream API call to either error or immediately signal completion with an
; empty response. The fix wraps the return value with Max(5, ...) to ensure the
; budget is always at least 5 tokens, which is the minimum viable value for any
; meaningful prediction.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLTBM_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TLTBM_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ==============================================================
; ==============================================================
; ======= 1/ _LLM_Engine_CallTokenBudget returns Max(5, ...) ===
; ==============================================================
; ==============================================================

_TLTBM_TokenBudgetMin5() {
	Src := _TLTBM_StripLineComments(_TLTBM_ReadSource("modules/llm/prediction_engine.ahk"))
	Assert(Src != "", "modules/llm/prediction_engine.ahk must be readable")

	Body := _DriverFuncBody("_LLM_Engine_CallTokenBudget")
	Assert(Body != "", "_LLM_Engine_CallTokenBudget must be defined in modules/llm/prediction_engine.ahk")

	; The return must wrap with Max(5, ...)
	Assert(InStr(Body, "Max(5,") > 0,
		"_LLM_Engine_CallTokenBudget must return Max(5, ...) to guarantee a minimum token budget of 5")
}
Test("prediction_engine: _LLM_Engine_CallTokenBudget returns Max(5, computed_budget)", _TLTBM_TokenBudgetMin5)
