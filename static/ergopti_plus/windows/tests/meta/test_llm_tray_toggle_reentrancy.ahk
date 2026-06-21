; tests/meta/test_llm_tray_toggle_reentrancy.ahk

; ==============================================================================
; MODULE: LLM Tray Toggle Re-Entrancy Guard
; DESCRIPTION:
; Static source guard for the LLM_Tray_OnToggle re-entrancy fix in
; ui/tray_llm/actions.ahk.
;
; ROOT CAUSE ENCODED:
; LLM_Tray_OnToggle is bound to a tray menu item callback. AHK menu callbacks
; fire on the main thread but can be invoked again before the first invocation
; returns if the user clicks the item twice rapidly. Without a re-entrancy guard,
; the enabled flag could be toggled back immediately, the config written twice,
; and the model-ready bootstrap launched in parallel, causing races.
;
; The fix introduces a static _Toggling := false flag. On entry, if _Toggling is
; already true, the function returns immediately. Otherwise it sets _Toggling :=
; true, executes the toggle logic, and clears _Toggling in a try/finally so it
; is always reset even if an exception escapes.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLTTR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TLTTR_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ==============================================================
; ==============================================================
; ======= 1/ LLM_Tray_OnToggle has a re-entrancy guard =========
; ==============================================================
; ==============================================================

_TLTTR_ReentrancyGuard() {
	Src := _TLTTR_StripLineComments(_TLTTR_ReadSource("ui/tray_llm/actions.ahk"))
	Assert(Src != "", "ui/tray_llm/actions.ahk must be readable")

	Body := _DriverFuncBody("LLM_Tray_OnToggle")
	Assert(Body != "", "LLM_Tray_OnToggle must be defined in ui/tray_llm/actions.ahk")

	; The re-entrancy static must be declared
	Assert(InStr(Body, "static _Toggling := false") > 0,
		"LLM_Tray_OnToggle must declare 'static _Toggling := false' for re-entrancy protection")

	; Must early-return when _Toggling is true
	Assert(InStr(Body, "if _Toggling") > 0,
		"LLM_Tray_OnToggle must check 'if _Toggling' and return early to prevent concurrent invocations")

	; Must set _Toggling := true to block re-entry
	Assert(InStr(Body, "_Toggling := true") > 0,
		"LLM_Tray_OnToggle must set _Toggling := true before executing the toggle logic")
}
Test("tray_llm/actions: LLM_Tray_OnToggle has static _Toggling re-entrancy guard", _TLTTR_ReentrancyGuard)
