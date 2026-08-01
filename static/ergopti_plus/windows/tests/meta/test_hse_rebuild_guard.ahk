; tests/meta/test_hse_rebuild_guard.ahk

; ==============================================================================
; MODULE: HSE Rebuild Guard Meta Test
; DESCRIPTION:
; Static source guard for the hse-registry-torn-read-vs-onmessage finding.
;
; Live registry rebuilds (RebuildHotstringsLive) must be protected by a
; generation flag (HSE_RebuildInProgress) so that the OnChar reader thread
; never accesses a cleared or partially repopulated index.
;
; The fix adds the flag in hotstring_engine_main.ahk and wraps the rebuild
; block in tray_menu.ahk with it. HSE_FindMatchAtEnd must return early if
; the flag is set.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_HRG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Rebuild guard assertion ================
; ===================================================
; ===================================================

_HRG_RebuildIsGuarded() {
	; 1. Verify flag exists in engine.
	EngineSrc := _HRG_ReadSource("infra/hotstrings/hotstring_engine_main.ahk")
	Assert(InStr(EngineSrc, "global HSE_RebuildInProgress := false") > 0,
		"HSE_RebuildInProgress global flag must be defined in hotstring_engine_main.ahk")
	
	; 2. Verify HSE_FindMatchAtEnd respects the flag.
	MatchBody := _DriverFuncBody("HSE_FindMatchAtEnd")
	Assert(InStr(MatchBody, "if HSE_RebuildInProgress") > 0,
		"HSE_FindMatchAtEnd must return early if HSE_RebuildInProgress is true (hse-registry-torn-read-vs-onmessage)")
	
	; 3. Verify RebuildHotstringsLive sets/clears the flag.
	MenuSrc := _HRG_ReadSource("ui/tray_menu.ahk")
	RebuildBody := _DriverFuncBody("RebuildHotstringsLive")
	Assert(RebuildBody != "", "RebuildHotstringsLive must exist in tray_menu.ahk")
	
	Assert(InStr(RebuildBody, "HSE_RebuildInProgress := true") > 0,
		"RebuildHotstringsLive must set HSE_RebuildInProgress to true before clearing the registry")
	Assert(InStr(RebuildBody, "HSE_RebuildInProgress := false") > 0,
		"RebuildHotstringsLive must set HSE_RebuildInProgress to false after repopulating the registry")
	
	; Ensure the release is in a finally block for safety.
	Assert(InStr(RebuildBody, "finally") > 0,
		"RebuildHotstringsLive must release the rebuild flag in a finally block")
}
Test("hotstring_engine: live rebuild is guarded by HSE_RebuildInProgress (hse-registry-torn-read-vs-onmessage)", _HRG_RebuildIsGuarded)
