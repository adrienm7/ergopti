; tests/meta/test_nav_val_modifiers_wired.ahk

; ==============================================================================
; MODULE: Nav Val Modifiers Wired Meta Test
; DESCRIPTION:
; Static source guard for the "nav-val-modifiers-not-wired" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

; Scans the whole ui/menu/menu_llm/ directory instead of one hardcoded file. All
; three assertions are PRESENCE checks, so widening the scope cannot weaken one —
; and _DriverDirConcat throws when the directory moves, instead of dying with an
; unreadable-path error that says nothing about the invariant at stake.
_TNV_ReadSource() {
	return _DriverDirConcat("ui/menu/menu_llm")
}

_TNV_Check() {
	Src := _TNV_ReadSource()
	Assert(InStr(Src, "LLM_Menu_BindNavHotkeys") > 0, "tab_accept.ahk must bind nav hotkeys dynamically")
	Assert(InStr(Src, "nav_modifiers") > 0, "tab_accept.ahk must read nav_modifiers")
	Assert(InStr(Src, "val_modifiers") > 0, "tab_accept.ahk must read val_modifiers")
}

Test("LLMTray: nav and val modifiers are wired to Hotkey()", _TNV_Check)
