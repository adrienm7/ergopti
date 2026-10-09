; tests/meta/test_personal_ext_scan_unbounded_recursion.ahk

; ==============================================================================
; MODULE: Personal Ext Scan Recursion Guard Meta Test
; DESCRIPTION:
; Static source guard for finding personal-ext-scan-unbounded-recursion.
;
; _HS_PreScanPersonal() walks the user-writable personal-hotstrings directory
; recursively at every (re)build of the tray menu via the nested _HS_ScanExt
; helper. A directory junction/symlink pointing at an ancestor turns that walk
; into infinite recursion; because AHK has no tail-call optimisation this ends
; in a fatal stack-overflow-class error that silently takes down the (deferred,
; Critical) menu build.
;
; The fix gives _HS_ScanExt a depth cap (_HS_SCAN_MAX_DEPTH) and a visited
; canonical-path set, and wraps the top-level call in try/catch so a runaway
; scan degrades to "no extension hotstrings" instead of crashing. This test
; asserts those three guards are present in the source.
;
; Meta-static because ui/tray_menu.ahk registers top-level menu hooks and is
; not part of the headless run_all include graph; it cannot be #Included by the
; runner without side effects.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================




; ==================================================
; ==================================================
; ======= 2/ Recursion guard assertions ============
; ==================================================
; ==================================================

_PESUR_HasDepthCapConstant() {
	Src := _DriverSourceConcat()
	Assert(InStr(Src, "_HS_SCAN_MAX_DEPTH") > 0,
		"the driver source must define _HS_SCAN_MAX_DEPTH -- the recursive personal ext scan needs a depth cap so a directory cycle cannot stack-overflow the menu build")
}
Test("tray_menu: personal ext scan has a depth-cap constant (personal-ext-scan-unbounded-recursion)", _PESUR_HasDepthCapConstant)

_PESUR_ScanHasCycleGuards() {
	Seg := _DriverFuncBody("_HS_PreScanPersonal")
	Assert(Seg != "", "_HS_PreScanPersonal() declaration must exist in the driver source")
	Assert(InStr(Seg, "_HS_SCAN_MAX_DEPTH") > 0,
		"_HS_ScanExt must consult _HS_SCAN_MAX_DEPTH and stop descending past the cap")
	Assert(InStr(Seg, "Visited") > 0,
		"_HS_ScanExt must keep a Visited set of canonical paths to break a junction/symlink directory cycle")
}
Test("tray_menu: _HS_ScanExt has depth + visited-set cycle guards (personal-ext-scan-unbounded-recursion)", _PESUR_ScanHasCycleGuards)

_PESUR_TopLevelScanWrappedInTryCatch() {
	Seg := _DriverFuncBody("_HS_PreScanPersonal")
	Assert(Seg != "", "_HS_PreScanPersonal() declaration must exist in the driver source")
	; The top-level walk must be inside a try { ... } catch so a runaway/failed
	; scan degrades to no extension hotstrings instead of crashing the build.
	TryIdx := InStr(Seg, "try {")
	CatchIdx := InStr(Seg, "catch as Err")
	Assert(TryIdx > 0 and CatchIdx > TryIdx,
		"The top-level _HS_ScanExt call must be wrapped in try/catch so a runaway scan degrades gracefully instead of crashing the menu build")
}
Test("tray_menu: top-level _HS_ScanExt call is wrapped in try/catch (personal-ext-scan-unbounded-recursion)", _PESUR_TopLevelScanWrappedInTryCatch)
