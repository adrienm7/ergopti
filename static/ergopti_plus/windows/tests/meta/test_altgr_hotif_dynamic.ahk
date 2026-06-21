; tests/meta/test_altgr_hotif_dynamic.ahk

; ==============================================================================
; MODULE: AltGr HotIf Dynamic Evaluation Guard
; DESCRIPTION:
; Static source guard for the IsAltGrLAltEnabled dynamic-evaluation fix in
; modules/shortcuts/altgr.ahk.
;
; ROOT CAUSE ENCODED:
; The original IsAltGrLAltEnabled returned a stale value captured at boot time
; (a module-level global set during init). If the user toggled the AltGr feature
; from the tray menu after script startup, the HotIf condition still evaluated
; the old boot-time value. This meant tray-menu toggles had no effect until the
; script was reloaded.
;
; The fix delegates to _AnyShortcutEnabled("alt_gr_lalt") at call time, which
; reads the current runtime configuration. This test checks that:
;   1. _AnyShortcutEnabled is defined (the delegation target must exist).
;   2. IsAltGrLAltEnabled delegates to _AnyShortcutEnabled("alt_gr_lalt").
; ==============================================================================

#Requires AutoHotkey v2.0

_TAHD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TAHD_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ========================================================================
; ========================================================================
; ======= 1/ IsAltGrLAltEnabled delegates to _AnyShortcutEnabled ==========
; ========================================================================
; ========================================================================

_TAHD_DelegatesAtRuntime() {
	Src := _TAHD_StripLineComments(_TAHD_ReadSource("modules/shortcuts/altgr.ahk"))
	Assert(Src != "", "modules/shortcuts/altgr.ahk must be readable")

	; _AnyShortcutEnabled must be the delegation target
	Assert(InStr(Src, "_AnyShortcutEnabled(") > 0,
		"modules/shortcuts/altgr.ahk must define or call _AnyShortcutEnabled() for runtime config evaluation")

	Body := _DriverFuncBody("IsAltGrLAltEnabled")
	Assert(Body != "", "IsAltGrLAltEnabled must be defined in modules/shortcuts/altgr.ahk")

	; Must delegate to _AnyShortcutEnabled with the correct group key
	Assert(InStr(Body, "_AnyShortcutEnabled(" . Chr(0x22) . "alt_gr_lalt" . Chr(0x22) . ")") > 0,
		'IsAltGrLAltEnabled must delegate to _AnyShortcutEnabled("alt_gr_lalt") so tray-menu toggles take effect immediately')
}
Test("altgr: IsAltGrLAltEnabled delegates to _AnyShortcutEnabled for runtime config lookup", _TAHD_DelegatesAtRuntime)
