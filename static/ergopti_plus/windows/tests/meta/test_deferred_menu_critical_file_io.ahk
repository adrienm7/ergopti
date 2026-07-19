; tests/meta/test_deferred_menu_critical_file_io.ahk

; ==============================================================================
; MODULE: Deferred-Menu Critical File-I/O Guard Meta Test
; DESCRIPTION:
; Static source guard for the "deferred-menu-critical-file-io" finding.
;
; BuildTrayMenuDeferred takes Critical("On") around InitSubMenus()/initMenu().
; Critical starves the message pump and the LL keyboard hook for its whole
; duration. InitSubMenus calls _HS_PreScanPersonal, which recurses the personal-
; hotstrings dir and parses every ext TOML — unbounded file I/O that can stall for
; seconds on a cloud-synced config dir (OneDrive Files On-Demand) or a spun-down
; drive, turning a one-time menu build into a multi-second keyboard freeze.
;
; The fix warms the prescan cache by calling _HS_PreScanPersonal() BEFORE
; Critical("On"); the function is cache-guarded (idempotent once
; _HS_PreScanPersonalCacheLoaded is set), so the under-Critical InitSubMenus call
; hits only the warm cache. This test asserts the prescan call appears in the
; function body and PRECEDES the Critical("On") that opens the starvation window —
; a regression that moves the I/O back under Critical fails CI. Meta-static because
; ErgoptiPlus.ahk registers every hotkey at load and cannot be #Included headless.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_DMCFIO_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_DMCFIO_PrescanWarmedBeforeCritical() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("BuildTrayMenuDeferred")
	Assert(Seg != "", "BuildTrayMenuDeferred() must exist in ErgoptiPlus.ahk")
	; Match the EXECUTABLE sequence: the prescan completes before the assignment
	; that opens Critical. Matching code rather than surrounding comments keeps
	; the file-I/O boundary meaningful even when Critical's prior state is saved.
	; Q is the ASCII double-quote (the linter bans the backtick-quote escape).
	Q := Chr(34)
	Pattern := "_HS_PreScanPersonal\(\)\s+_MenuBuildCritical\s*:=\s*Critical\(" . Q . "On" . Q . "\)"
	Assert(RegExMatch(Seg, Pattern) > 0,
		"_HS_PreScanPersonal() must complete before BuildTrayMenuDeferred enters Critical — warming the prescan cache off-Critical keeps unbounded personal-hotstrings file I/O out of the keyboard-hook starvation window")
}
Test("ErgoptiPlus: BuildTrayMenuDeferred warms prescan before Critical (deferred-menu-critical-file-io)", _DMCFIO_PrescanWarmedBeforeCritical)
