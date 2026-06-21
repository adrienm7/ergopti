; tests/meta/test_wpm_widget_color_cache.ahk

; ==============================================================================
; MODULE: WPM Widget Color Cache Meta-Test
; DESCRIPTION:
; Structural regression for the per-category color memoization added to
; _WPMWidget_ReadTomlColor in ui/wpm_widget.ahk.
;
; Before the fix, every call to _WPMWidget_ReadTomlColor() did a full FileRead
; of the hotstring category TOML file. The WPM tick fires every ~100 ms and
; calls WPMWidget_ResolveBgColor / WPMWidget_CategoryBgColor / CategoryGraphColor
; on every tick, each of which may call _WPMWidget_ReadTomlColor. On a typical
; session this means dozens of file reads per second for a value that changes
; at most when the user edits a hotstring config in the config window.
;
; The fix:
;   1. Adds a static _color_cache Map inside _WPMWidget_ReadTomlColor.
;   2. Returns the cached value immediately on a cache hit.
;   3. Populates the cache on a miss before returning.
;   4. Exposes WPMWidget_InvalidateColorCache() so config-window saves can
;      flush the cache without needing to know the implementation.
;
; This test inspects wpm_widget.ahk source and asserts all four properties.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source-inspection helpers ==============
; ===================================================
; ===================================================

; Move-resilient: the whole driver source via the framework helper. Only used for
; the unique WPMWidget_InvalidateColorCache token check; the per-function checks
; go through _WWCC_FindReadTomlBlock below.
_WWCC_ReadSource() {
	return _DriverSourceConcat()
}


; Move-resilient: extract _WPMWidget_ReadTomlColor()'s body by name (the helper
; anchors on the DEFINITION, so the earlier call sites do not confuse it). The
; src argument is ignored; kept so the call sites stay unchanged.
_WWCC_FindReadTomlBlock(src) {
	return _DriverFuncBody("_WPMWidget_ReadTomlColor")
}




; ===================================================
; ===================================================
; ======= 2/ Assertions =============================
; ===================================================
; ===================================================

_WWCC_CacheMapDeclared() {
	block := _WWCC_FindReadTomlBlock(_WWCC_ReadSource())
	Assert(InStr(block, "_color_cache") > 0,
		"wpm_widget.ahk: _WPMWidget_ReadTomlColor must declare a static _color_cache Map")
}
Test("WPM widget: _color_cache Map declared in _WPMWidget_ReadTomlColor (wpm-color-cache)", _WWCC_CacheMapDeclared)


_WWCC_CacheHitReturnEarly() {
	block := _WWCC_FindReadTomlBlock(_WWCC_ReadSource())
	Assert(InStr(block, "_color_cache.Has(CategoryName)") > 0,
		"wpm_widget.ahk: _WPMWidget_ReadTomlColor must check _color_cache.Has() for early return on cache hit")
}
Test("WPM widget: cache hit short-circuits file read in _WPMWidget_ReadTomlColor (wpm-color-cache)", _WWCC_CacheHitReturnEarly)


_WWCC_CachePopulatedOnMiss() {
	block := _WWCC_FindReadTomlBlock(_WWCC_ReadSource())
	; The cache must be written (either with a real color or empty string) before the final return.
	pos1 := InStr(block, "_color_cache[CategoryName]")
	pos2 := InStr(block, "_color_cache[CategoryName]", 1, 2)
	Assert(pos1 > 0 and pos2 > 0,
		"wpm_widget.ahk: _color_cache[CategoryName] must be assigned in at least two places (hit and miss paths)")
}
Test("WPM widget: _color_cache populated on file read (wpm-color-cache)", _WWCC_CachePopulatedOnMiss)


_WWCC_InvalidateFunctionPresent() {
	src := _WWCC_ReadSource()
	Assert(InStr(src, "WPMWidget_InvalidateColorCache()") > 0,
		"wpm_widget.ahk: WPMWidget_InvalidateColorCache() must be declared so config saves can flush the cache")
}
Test("WPM widget: WPMWidget_InvalidateColorCache() function declared (wpm-color-cache)", _WWCC_InvalidateFunctionPresent)
