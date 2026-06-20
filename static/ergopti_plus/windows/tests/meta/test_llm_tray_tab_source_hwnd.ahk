; tests/meta/test_llm_tray_tab_source_hwnd.ahk

; ==============================================================================
; MODULE: LLM_Tray_TryAcceptTabGuarded source_hwnd Check Guard
; DESCRIPTION:
; Static source guard for the LLM_Tray_TryAcceptTabGuarded source_hwnd fix in
; ui/tray_llm/tab_accept.ahk.
;
; ROOT CAUSE ENCODED:
; The original tab-accept path called the accept function unconditionally when a
; Tab keypress was detected, even if the active window was no longer the window
; that triggered the LLM prediction. This caused the prediction to be injected
; into the wrong application when the user had switched focus before pressing Tab.
;
; The fix introduces LLM_Tray_TryAcceptTabGuarded(), which checks that the
; source_hwnd stored in the engine state matches the currently active window
; before calling the accept function. If the window no longer exists or is no
; longer active, the tab accept is silently skipped.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLTSH_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TLTSH_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_TLTSH_FuncBody(Src, Decl) {
	Idx := InStr(Src, Decl)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	return End ? SubStr(Rest, 1, End + 1) : Rest
}


; ==========================================================================
; ==========================================================================
; ======= 1/ LLM_Tray_TryAcceptTabGuarded checks source_hwnd ===============
; ==========================================================================
; ==========================================================================

_TLTSH_SourceHwndCheck() {
	Src := _TLTSH_StripLineComments(_TLTSH_ReadSource("ui/tray_llm/tab_accept.ahk"))
	Assert(Src != "", "ui/tray_llm/tab_accept.ahk must be readable")

	; The guarded function must exist
	Assert(InStr(Src, "LLM_Tray_TryAcceptTabGuarded()") > 0,
		"ui/tray_llm/tab_accept.ahk must define LLM_Tray_TryAcceptTabGuarded() (source_hwnd guard)")

	Body := _DriverFuncBody("LLM_Tray_TryAcceptTabGuarded")
	Assert(Body != "", "LLM_Tray_TryAcceptTabGuarded must have a function body in tab_accept.ahk")

	; Must read source_hwnd from the engine state
	Assert(InStr(Body, "source_hwnd") > 0,
		"LLM_Tray_TryAcceptTabGuarded must check source_hwnd before accepting the tab prediction")

	; Must verify the window still exists
	Assert(InStr(Body, "WinExist") > 0,
		"LLM_Tray_TryAcceptTabGuarded must verify the source_hwnd window still exists before accepting")
}
Test("tray_llm/tab_accept: LLM_Tray_TryAcceptTabGuarded verifies source_hwnd before accepting", _TLTSH_SourceHwndCheck)
