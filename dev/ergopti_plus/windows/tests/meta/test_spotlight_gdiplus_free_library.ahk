; tests/meta/test_spotlight_gdiplus_free_library.ahk

; ==============================================================================
; MODULE: Spotlight GDI+ FreeLibrary Meta Test
; DESCRIPTION:
; Regression guard ensuring ui/spotlight/init.ahk balances every LoadLibrary("gdiplus")
; call with a FreeLibrary call so the DLL ref-count stays clean across invocations.
;
; SCOPE: source introspection of ui/spotlight/init.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_SGFL_ReadSource(RelDir) {
	; Move-resilient: concat the whole window folder, not a pinned single-file path.
	return _DriverDirConcat(RelDir)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_SGFL_CheckFreeLibraryPresent() {
	Src := _SGFL_ReadSource("ui/spotlight")
	Assert(Src != "", "ui/spotlight/init.ahk must be readable")

	Assert(InStr(Src, "LoadLibrary"),
		"ui/spotlight/init.ahk must call LoadLibrary to acquire gdiplus")
	Assert(InStr(Src, "FreeLibrary"),
		"ui/spotlight/init.ahk must call FreeLibrary to release gdiplus — LoadLibrary without FreeLibrary leaks the DLL ref-count")
}

_SGFL_CheckHandleStored() {
	Src := _SGFL_ReadSource("ui/spotlight")
	Assert(Src != "", "ui/spotlight/init.ahk must be readable")

	; The module handle must be stored so _SpotlightDismiss can reach it
	Assert(InStr(Src, "hGdiplus"),
		'ui/spotlight/init.ahk must store the LoadLibrary handle in _Spotlight_State["hGdiplus"] for balanced FreeLibrary on dismiss')
}


Test("meta spotlight: FreeLibrary called to balance LoadLibrary(gdiplus)",
	_SGFL_CheckFreeLibraryPresent)

Test("meta spotlight: gdiplus module handle stored for deferred FreeLibrary",
	_SGFL_CheckHandleStored)