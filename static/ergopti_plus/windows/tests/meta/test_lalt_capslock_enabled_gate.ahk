; tests/meta/test_lalt_capslock_enabled_gate.ahk

; ==============================================================================
; MODULE: LAlt+CapsLock Enabled Gate
; DESCRIPTION:
; Regression guard for AHK-32: the LAlt+CapsLock combo lacked the
; _AnyShortcutEnabled gate its AltGr siblings have. When every
; lalt_caps_lock action was disabled, the #HotIf still armed the chord and
; LAltCapsLockShortcut() silently swallowed the CapsLock keypress with no
; native fallback (the 10-branch if/else cascade matched nothing and returned).
;
; Fix (AHK-32): add `and _AnyShortcutEnabled("lalt_caps_lock")` to the #HotIf
; in modules/shortcuts/base_modifier.ahk, mirroring altgr.ahk:167,169.
;
; This test reads base_modifier.ahk, strips line comments, locates the #HotIf
; that precedes SC038 & SC03A::, and asserts it contains the enabled gate so
; a fully-disabled group falls back to native CapsLock.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================================
; =============================================================
; ======= 1/ LAlt+CapsLock gates on _AnyShortcutEnabled =======
; =============================================================
; =============================================================

_TLCEG_CheckEnabledGate() {
	SplitPath(A_ScriptDir, , &Root)
	Src := FileRead(StrReplace(Root, "\", "/") . "/modules/shortcuts/base_modifier.ahk", "UTF-8")
	Assert(Src != "", "modules/shortcuts/base_modifier.ahk must be readable")

	; Strip line comments so the AHK-32 annotation above #HotIf does not interfere
	Stripped := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Stripped .= Line . "`n"
	}

	Lines := StrSplit(Stripped, "`n")
	comboIdx := 0
	for i, Line in Lines {
		if InStr(Line, "SC038 & SC03A::") {
			comboIdx := i
			break
		}
	}
	Assert(comboIdx > 0, "SC038 & SC03A:: hotkey must exist in modules/shortcuts/base_modifier.ahk")

	; Walk back from the hotkey line to find the nearest #HotIf directive
	hotifLine := ""
	i := comboIdx - 1
	while (i >= 1) {
		if InStr(Lines[i], "#HotIf") {
			hotifLine := Lines[i]
			break
		}
		i--
	}
	Assert(hotifLine != "", "A #HotIf must precede SC038 & SC03A:: in modules/shortcuts/base_modifier.ahk")
	Assert(InStr(hotifLine, "_AnyShortcutEnabled(" . Chr(0x22) . "lalt_caps_lock" . Chr(0x22) . ")") > 0,
		"AHK-32: #HotIf before SC038 & SC03A:: must gate on _AnyShortcutEnabled(" . Chr(0x22) . "lalt_caps_lock" . Chr(0x22) . ") so a fully-disabled group falls back to native CapsLock rather than silently swallowing the chord")
}


Test("meta ahk-32: #HotIf before SC038 & SC03A:: gates on _AnyShortcutEnabled so a fully-disabled lalt_caps_lock group falls back to native CapsLock",
	_TLCEG_CheckEnabledGate)
