; tests/meta/test_deferred_menu_critical_file_io.ahk

; ==============================================================================
; MODULE: Deferred-Menu Critical File-I/O Guard Meta Test
; DESCRIPTION:
; Static source guard for the "deferred-menu-critical-file-io" finding.
;
; The root replacement now stages the complete menu and enters Critical only in
; TrayMenuStage_Publish. This test prevents a regression that moves personal
; hotstring I/O back into BuildTrayMenuDeferred's keyboard-hook starvation window.
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

_DMCFIO_PrescanRunsOutsideCritical() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("BuildTrayMenuDeferred")
	Assert(Seg != "", "BuildTrayMenuDeferred() must exist in ErgoptiPlus.ahk")
	Assert(InStr(Seg, "_HS_PreScanPersonal()") > 0,
		"BuildTrayMenuDeferred must warm the personal-hotstrings cache before staging the menu")
	Assert(InStr(Seg, 'Critical("On")') = 0,
		"BuildTrayMenuDeferred must not hold Critical across personal-hotstrings I/O; only TrayMenuStage_Publish may enter the short publication critical section")
}
Test("ErgoptiPlus: BuildTrayMenuDeferred keeps personal prescan outside Critical (deferred-menu-critical-file-io)", _DMCFIO_PrescanRunsOutsideCritical)
