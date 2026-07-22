; tests/meta/test_script_shortcut_labels_locale.ahk

; ==============================================================================
; MODULE: Script Shortcut Labels Locale Guard
; DESCRIPTION:
; Static source guard for the F29 fix: SCRIPT_SHORTCUT_LABELS must store raw
; i18n key strings, not eagerly-translated t() values.
;
; ROOT CAUSE ENCODED:
; SCRIPT_SHORTCUT_LABELS was populated at top-level with t() calls before
; I18nInit() runs. Because I18nInit() has not yet executed when the constant
; is initialized, t() falls back to the French locale unconditionally, so the
; shortcut menu labels are always French regardless of the user's chosen locale.
;
; The fix stores plain key strings (e.g. "sg_labels.script_altgr_enter") in
; SCRIPT_SHORTCUT_LABELS and wraps the lookup through t() at the point of use
; inside BuildScriptShortcutsMenu, where I18nInit() has already run.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers ====================
; ====================================================
; ====================================================

_SSSL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_SSSL_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; ======================================================================
; ======================================================================
; ======= 2/ SCRIPT_SHORTCUT_LABELS stores raw i18n keys ==============
; ======================================================================
; ======================================================================

_SSSL_AssertLabelsAreKeys() {
	Src := _SSSL_StripLineComments(_DriverSourceConcat())
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	; Locate the SCRIPT_SHORTCUT_LABELS Map assignment block
	Idx := InStr(Src, "SCRIPT_SHORTCUT_LABELS := Map(")
	Assert(Idx > 0, "SCRIPT_SHORTCUT_LABELS := Map(...) must exist in ErgoptiPlus.ahk")

	; Extract the Map literal (up to the closing paren)
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, ")")
	Assert(End > 0, "SCRIPT_SHORTCUT_LABELS Map literal must have a closing paren")
	Block := SubStr(Rest, 1, End)

	; Values must be bare string keys, not t() calls — no t( inside the block
	Assert(!RegExMatch(Block, "\bt\s*\("),
		"SCRIPT_SHORTCUT_LABELS values must be raw i18n key strings, not t() calls (F29: labels frozen to fr locale)")
}
Test("F29: SCRIPT_SHORTCUT_LABELS stores raw i18n keys, not t() calls", _SSSL_AssertLabelsAreKeys)




; ======================================================================
; ======================================================================
; ======= 3/ BuildScriptShortcutsMenu resolves via t() ================
; ======================================================================
; ======================================================================

_SSSL_AssertMenuResolvesViaT() {
	Src := _SSSL_StripLineComments(_DriverSourceConcat())
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	; Locate BuildScriptShortcutsMenu body (column-0 definition, not a call site)
	Body := _DriverFuncBody("BuildScriptShortcutsMenu")
	Assert(Body != "", "BuildScriptShortcutsMenu must exist in the driver source")

	; The label lookup must go through t(SCRIPT_SHORTCUT_LABELS[...]) so the
	; translation is resolved at call time, after I18nInit() has run.
	Assert(RegExMatch(Body, "t\s*\(\s*SCRIPT_SHORTCUT_LABELS\[") > 0,
		"BuildScriptShortcutsMenu must use t(SCRIPT_SHORTCUT_LABELS[Slot]) to resolve labels at call time (F29)")
}
Test("F29: BuildScriptShortcutsMenu resolves label via t(SCRIPT_SHORTCUT_LABELS[Slot])", _SSSL_AssertMenuResolvesViaT)