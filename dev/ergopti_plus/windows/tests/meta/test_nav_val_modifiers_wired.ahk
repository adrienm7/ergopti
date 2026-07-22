; tests/meta/test_nav_val_modifiers_wired.ahk

; ==============================================================================
; MODULE: Nav Val Modifiers Wired Meta Test
; DESCRIPTION:
; Static source guard for the "nav-val-modifiers-not-wired" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TNV_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TNV_Check() {
	Src := _TNV_ReadSource("ui/menu/menu_llm/tab_accept.ahk")
	Assert(Src != "", "Source file tab_accept.ahk must exist")
	Assert(InStr(Src, "LLM_Menu_BindNavHotkeys") > 0, "tab_accept.ahk must bind nav hotkeys dynamically")
	Assert(InStr(Src, "nav_modifiers") > 0, "tab_accept.ahk must read nav_modifiers")
	Assert(InStr(Src, "val_modifiers") > 0, "tab_accept.ahk must read val_modifiers")
}

Test("LLMTray: nav and val modifiers are wired to Hotkey()", _TNV_Check)
