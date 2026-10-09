; tests/meta/test_layout_poll_blacklist_guard.ahk

; ==============================================================================
; MODULE: Layout Poll Blacklist Guard Meta Test
; DESCRIPTION:
; Static source guard for the layout-poll-blind-reload finding.
;
; CheckKeyboardLayoutChange() must not only check A_IsSuspended (to avoid
; silently unpausing the driver) but also MF_ShouldFilter() (to avoid
; disruptive script reloads while a blacklisted app like a game or private
; browsing window is focused).
;
; The fix adds a try-guarded MF_ShouldFilter() check before calling Reload().
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helper =====================
; ===================================================
; ===================================================

_LPBG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Guard assertion ========================
; ===================================================
; ===================================================

_LPBG_LayoutPollHasBlacklistGuard() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("CheckKeyboardLayoutChange")
	Assert(Seg != "", "CheckKeyboardLayoutChange must exist in ErgoptiPlus.ahk")
	Assert(InStr(Seg, "MF_ShouldFilter") > 0,
		"CheckKeyboardLayoutChange must check MF_ShouldFilter() — Reload() is disruptive; it must be skipped while a blacklisted app is focused (layout-poll-blind-reload)")
}
Test("ErgoptiPlus: CheckKeyboardLayoutChange has MF_ShouldFilter guard (layout-poll-blind-reload)", _LPBG_LayoutPollHasBlacklistGuard)
