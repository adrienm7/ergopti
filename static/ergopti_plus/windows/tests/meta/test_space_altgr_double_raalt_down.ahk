; tests/meta/test_space_altgr_double_raalt_down.ahk

; ==============================================================================
; MODULE: Space AltGr Balanced-Modifier Meta Test
; DESCRIPTION:
; Static source guard for the space-altgr-double-raalt-down finding.
;
; _SpaceHoldAltGr() used to send "{RAlt Down}" twice (once at the top, once
; again concatenated with the captured char) but only one "{RAlt Up}". That
; left an unbalanced Down/Up count: on layouts where a repeated Down is not
; idempotent the modifier stayed logically held after the single Up, leaking
; AltGr onto the following keystrokes. It also double-applied the AltGr layer
; to the captured (already-translated) char, producing the wrong glyph.
;
; The fix keeps a balanced pair: exactly one "{RAlt Down}" and exactly one
; "{RAlt Up}" per call, with the captured char sent plainly while RAlt is
; already held. This test scans the function body and asserts that balance
; so the redundant second Down can never silently return.
;
; This is a meta-static test (scans source text): modules/tap_holds/space.ahk
; registers SC039:: hotkeys at top level and is deliberately NOT #Included by
; the headless runner (run_all.ahk excludes modules/ for that reason), so the
; function cannot be called directly without hanging the suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_SADRD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Counts non-overlapping occurrences of Needle in Haystack.
_SADRD_Count(Haystack, Needle) {
	if (Needle == "")
		return 0
	Count := 0
	Pos := 1
	while (Pos := InStr(Haystack, Needle, false, Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}




; ==================================================
; ==================================================
; ======= 2/ Balanced-modifier assertion ===========
; ==================================================
; ==================================================

_SADRD_AltGrModifierBalanced() {
	Src := _SADRD_ReadSource("modules/tap_holds/space.ahk")
	Body := _DriverFuncBody("_SpaceHoldAltGr")
	Assert(Body != "", "_SpaceHoldAltGr(captured) must exist in modules/tap_holds/space.ahk")

	Downs := _SADRD_Count(Body, "{RAlt Down}")
	Ups := _SADRD_Count(Body, "{RAlt Up}")

	AssertEqual(1, Downs,
		"_SpaceHoldAltGr must send '{RAlt Down}' exactly once (the redundant second Down left AltGr stuck and double-translated the captured char) (space-altgr-double-raalt-down)")
	AssertEqual(1, Ups,
		"_SpaceHoldAltGr must release '{RAlt Up}' exactly once to balance the single Down (space-altgr-double-raalt-down)")
	AssertEqual(Downs, Ups,
		"_SpaceHoldAltGr must keep a balanced RAlt Down/Up count so the modifier is never left logically held (space-altgr-double-raalt-down)")
}
Test("tap_holds: _SpaceHoldAltGr keeps a balanced RAlt Down/Up pair (space-altgr-double-raalt-down)", _SADRD_AltGrModifierBalanced)
