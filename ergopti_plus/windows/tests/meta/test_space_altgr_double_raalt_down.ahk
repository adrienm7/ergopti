; tests/meta/test_space_altgr_double_raalt_down.ahk

; ==============================================================================
; MODULE: Space AltGr Balanced-Modifier Meta Test
; DESCRIPTION:
; Static source guard for the space-altgr-double-raalt-down finding.
;
; The legacy _SpaceHoldAltGr() used to send "{RAlt Down}" twice (once at the
; top, once again concatenated with the captured char) but only one "{RAlt Up}".
; That left an unbalanced Down/Up count: on layouts where a repeated Down is not
; idempotent the modifier stayed logically held after the single Up, leaking
; AltGr onto following keystrokes. The generic modifier handler supersedes it.
;
; The generic handler now keeps exactly one suspend-owned Down/Up pair per call
; for every modifier, including AltGr's RAlt mapping. This test scans that
; single implementation so the redundant second Down can never return.
;
; This is a meta-static test (scans source text): platform/remap/space.ahk
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
	Body := _DriverFuncBody("TapHoldOwnImmediateModifier")
	Space := _DriverFuncBody("SpaceTapHold")
	Assert(Body != "" and Space != "", "Space and its common modifier owner must exist")

	Downs := _SADRD_Count(Body, "KeyDownFn.Call(ModKey)")
	Ups := _SADRD_Count(Body, "KeyUpFn.Call(ModKey)")

	AssertEqual(1, Downs,
		"the shared owner must acquire the resolved modifier exactly once")
	AssertEqual(1, Ups,
		"the shared owner must release the resolved modifier exactly once")
	AssertEqual(Downs, Ups,
		"Space AltGr ownership must keep a balanced Down/Up pair")
	Assert(InStr(Space, "_SpaceHoldModKey()") > 0,
		"Space must pass its configured resolver result to the shared owner")
}
Test("tap_holds: generic Space modifier path keeps AltGr's Down/Up pair balanced (space-altgr-double-raalt-down)", _SADRD_AltGrModifierBalanced)
