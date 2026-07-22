; tests/meta/test_layout_poll_pending_hkl.ahk

; ==============================================================================
; MODULE: Layout Poll Helper pendingHkl Preservation Guard
; DESCRIPTION:
; Static source guard for the _ShouldReloadForHkl pendingHkl preservation fix
; in modules/keymap/layout_poll_helper.ahk.
;
; ROOT CAUSE ENCODED:
; When curHkl == 0 (the layout is momentarily unreadable, e.g. focus is on a
; window with no HKL), the original code cleared pendingHkl := 0. This reset
; the two-poll confirmation counter, meaning a transient unreadable poll between
; two sightings of the same new layout would restart the confirmation window
; indefinitely, preventing any layout reload from ever completing.
;
; The fix makes the curHkl == 0 early-return skip the pendingHkl := 0 reset,
; preserving the debounce candidate across the unreadable poll.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLPPH_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TLPPH_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ========================================================================
; ========================================================================
; ======= 1/ curHkl == 0 path does NOT clear pendingHkl ==================
; ========================================================================
; ========================================================================

_TLPPH_ZeroHklPreservesPending() {
	Src := _TLPPH_StripLineComments(_TLPPH_ReadSource("modules/keymap/layout_poll_helper.ahk"))
	Assert(Src != "", "modules/keymap/layout_poll_helper.ahk must be readable")

	Body := _DriverFuncBody("_ShouldReloadForHkl")
	Assert(Body != "", "_ShouldReloadForHkl must be defined in modules/keymap/layout_poll_helper.ahk")

	; The curHkl == 0 early return must be present
	Assert(InStr(Body, "curHkl == 0") > 0,
		"_ShouldReloadForHkl must have a curHkl == 0 early-return path for transient unreadable polls")

	; Extract the curHkl == 0 block and verify pendingHkl := 0 does NOT appear in it.
	; Strategy: find the zero-check line and look at the next few lines for pendingHkl clearing.
	ZeroPos := InStr(Body, "curHkl == 0")
	Assert(ZeroPos > 0, "curHkl == 0 check must exist (already asserted above)")
	; Get the 3 lines after the zero check (up to ~200 chars) — the early return is inline
	Vicinity := SubStr(Body, ZeroPos, 80)
	Assert(InStr(Vicinity, "pendingHkl := 0") = 0,
		"_ShouldReloadForHkl must NOT reset pendingHkl := 0 in the curHkl == 0 branch — that would restart the two-poll confirmation window on transient unreadable polls")
}
Test("layout_poll_helper: _ShouldReloadForHkl preserves pendingHkl when curHkl == 0", _TLPPH_ZeroHklPreservesPending)
