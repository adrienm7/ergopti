; tests/meta/test_spotlight_gdiplus_free_library.ahk

; ==============================================================================
; MODULE: Spotlight GDI+ FreeLibrary Meta Test
; DESCRIPTION:
; Regression guard ensuring each Spotlight session receipt balances its exact
; gdiplus module handle after every dependent window and token is released.
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

	Acquire := _DriverFuncBody("_SpotlightSessionAcquireGdi")
	Release := _DriverFuncBody("_SpotlightSessionRelease")
	Assert(InStr(Acquire, 'Receipt["module"] := Native.LoadModule()'),
		"Spotlight must store the exact module in its local session receipt")
	Assert(InStr(Release, 'Native.FreeModule(Receipt["module"])'),
		"Spotlight must free the exact module only after dependent cleanup")
}


Test("meta spotlight: FreeLibrary called to balance LoadLibrary(gdiplus)",
	_SGFL_CheckFreeLibraryPresent)

Test("meta spotlight: gdiplus module handle stored in the session receipt",
	_SGFL_CheckHandleStored)
