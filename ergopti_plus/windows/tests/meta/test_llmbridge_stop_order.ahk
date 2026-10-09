; tests/meta/test_llmbridge_stop_order.ahk

; ==============================================================================
; MODULE: LLM_Bridge_Stop + StopGeneration Order Guard
; DESCRIPTION:
; Static source guard for the LLM_Bridge_Stop ordering fix in
; modules/keymap/llm_bridge.ahk.
;
; ROOT CAUSE ENCODED:
; The original LLM_Bridge_Stop called LLM_Engine_SetEnabled(false) before
; (or without) calling LLM_Engine_StopGeneration(). This meant that an in-flight
; HTTP request continued running after the engine was marked disabled, and the
; async callback (which fires on the HTTP thread after Send() returns) could
; still try to update UI state after the bridge had torn itself down.
;
; The fix ensures LLM_Engine_StopGeneration() is called (wrapped in try) BEFORE
; LLM_Engine_SetEnabled(false), so the in-flight request is cancelled before the
; engine flags it as disabled.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLBSO_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TLBSO_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ====================================================================
; ====================================================================
; ======= 1/ StopGeneration called before SetEnabled in Bridge_Stop ===
; ====================================================================
; ====================================================================

_TLBSO_StopBeforeDisable() {
	Src := _TLBSO_StripLineComments(_TLBSO_ReadSource("modules/keymap/llm_bridge.ahk"))
	Assert(Src != "", "modules/keymap/llm_bridge.ahk must be readable")

	Body := _DriverFuncBody("LLM_Bridge_Stop")
	Assert(Body != "", "LLM_Bridge_Stop must be defined in modules/keymap/llm_bridge.ahk")

	; Both calls must be present
	StopPos    := InStr(Body, "LLM_Engine_StopGeneration()")
	DisablePos := InStr(Body, "LLM_Engine_SetEnabled(false)")
	Assert(StopPos > 0,
		"LLM_Bridge_Stop must call LLM_Engine_StopGeneration() to cancel in-flight HTTP before disabling the engine")
	Assert(DisablePos > 0,
		"LLM_Bridge_Stop must call LLM_Engine_SetEnabled(false) to mark the engine as disabled")

	; StopGeneration must precede SetEnabled(false)
	Assert(StopPos < DisablePos,
		"LLM_Bridge_Stop must call LLM_Engine_StopGeneration() BEFORE LLM_Engine_SetEnabled(false) — stopping first prevents stale async callbacks from firing after disable")
}
Test("llm_bridge: LLM_Bridge_Stop calls StopGeneration before SetEnabled(false)", _TLBSO_StopBeforeDisable)
