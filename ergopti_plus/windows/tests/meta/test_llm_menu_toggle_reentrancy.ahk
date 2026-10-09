; tests/meta/test_llm_menu_toggle_reentrancy.ahk

; ==============================================================================
; MODULE: LLM Tray Toggle Re-Entrancy Guard
; DESCRIPTION:
; Static source guard for the LLM_Menu_OnToggle re-entrancy fix in
; ui/menu/menu_llm/actions.ahk.
;
; ROOT CAUSE ENCODED:
; LLM_Menu_OnToggle is bound to a tray menu item callback. AHK menu callbacks
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
; ======= 1/ LLM_Menu_OnToggle has a re-entrancy guard =========
; ==============================================================
; ==============================================================

_TLTTR_ReentrancyGuard() {
	Src := _TLTTR_StripLineComments(_TLTTR_ReadSource("ui/menu/menu_llm/actions.ahk"))
	Assert(Src != "", "ui/menu/menu_llm/actions.ahk must be readable")

	Body := _DriverFuncBody("LLM_Menu_OnToggle")
	Assert(Body != "", "LLM_Menu_OnToggle must be defined in ui/menu/menu_llm/actions.ahk")

	; The re-entrancy static must be declared
	Assert(InStr(Body, "static _Toggling := false") > 0,
		"LLM_Menu_OnToggle must declare 'static _Toggling := false' for re-entrancy protection")

	; Must early-return when _Toggling is true
	Assert(InStr(Body, "if _Toggling") > 0,
		"LLM_Menu_OnToggle must check 'if _Toggling' and return early to prevent concurrent invocations")

	; Must set _Toggling := true to block re-entry
	Assert(InStr(Body, "_Toggling := true") > 0,
		"LLM_Menu_OnToggle must set _Toggling := true before executing the toggle logic")
}
Test("menu_llm/actions: LLM_Menu_OnToggle has static _Toggling re-entrancy guard", _TLTTR_ReentrancyGuard)
