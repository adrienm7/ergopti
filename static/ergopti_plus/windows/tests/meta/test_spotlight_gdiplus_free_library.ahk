; tests/meta/test_spotlight_gdiplus_free_library.ahk

; ==============================================================================
; MODULE: Spotlight GDI+ FreeLibrary Meta Test
; DESCRIPTION:
; Regression guard ensuring lib/spotlight.ahk balances every LoadLibrary("gdiplus")
; call with a FreeLibrary call so the DLL ref-count stays clean across invocations.
;
; SCOPE: source introspection of lib/spotlight.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_SGFL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	SplitPath(WindowsDir, , &Root)
	Path := Root . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_SGFL_CheckFreeLibraryPresent() {
	Src := _SGFL_ReadSource("lib/spotlight.ahk")
	Assert(Src != "", "lib/spotlight.ahk must be readable")

	Assert(InStr(Src, "LoadLibrary"),
		"lib/spotlight.ahk must call LoadLibrary to acquire gdiplus")
	Assert(InStr(Src, "FreeLibrary"),
		"lib/spotlight.ahk must call FreeLibrary to release gdiplus — LoadLibrary without FreeLibrary leaks the DLL ref-count")
}

_SGFL_CheckHandleStored() {
	Src := _SGFL_ReadSource("lib/spotlight.ahk")
	Assert(Src != "", "lib/spotlight.ahk must be readable")

	; The module handle must be stored so _SpotlightDismiss can reach it
	Assert(InStr(Src, "hGdiplus"),
		'lib/spotlight.ahk must store the LoadLibrary handle in _Spotlight_State["hGdiplus"] for balanced FreeLibrary on dismiss')
}


Test("meta spotlight: FreeLibrary called to balance LoadLibrary(gdiplus)",
	_SGFL_CheckFreeLibraryPresent)

Test("meta spotlight: gdiplus module handle stored for deferred FreeLibrary",
	_SGFL_CheckHandleStored)