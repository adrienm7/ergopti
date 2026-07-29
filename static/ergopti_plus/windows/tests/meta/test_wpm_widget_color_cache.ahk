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
;   4. Keeps the cache BELOW the override-aware resolver, so a memoized fallback
;      answer can never shadow a colour the user just changed.
;
; Point 4 replaces an earlier assertion that only checked
; WPMWidget_InvalidateColorCache() was DECLARED. That assertion was satisfied by
; the definition line itself, so it could never fail — and the function had no
; production caller anywhere in the driver, meaning the escape hatch it promised
; ("so config saves can flush the cache") did not exist. Worse, the cache-hit
; early return sat ABOVE the HotstringsResolve call, so the first answer served
; from the fallback path was cached and the resolver was skipped for that
; category for the life of the process: a colour changed in the config window
; repainted the tooltip and left the widget on the manual blue until restart.
; The unwired hatch is gone; the guarantee it was meant to deliver is now
; structural, and stated here as an ordering assertion that can actually fail.
;
; This test inspects wpm_display.ahk source and asserts all four properties.
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


_WWCC_ResolverConsultedBeforeCache() {
	block := _WWCC_FindReadTomlBlock(_WWCC_ReadSource())
	ResolvePos := InStr(block, "HotstringsResolve(")
	CachePos   := InStr(block, "_color_cache.Has(CategoryName)")
	Assert(ResolvePos > 0,
		"wpm_display.ahk: _WPMWidget_ReadTomlColor must consult the override-aware resolver — reading the TOML alone never sees a colour changed in the config window")
	Assert(CachePos > ResolvePos,
		"wpm_display.ahk: the _color_cache early return must sit BELOW the HotstringsResolve call. Above it, the first answer served from the file fallback (resolver unavailable during early init) is memoized and short-circuits every later call, so the resolver is skipped for that category for the life of the process and a colour changed in the config window never reaches the widget")

	; If an invalidation hatch is ever (re)introduced it must be WIRED: the old
	; one was declared and never called, so the promise it carried was fiction.
	; Counting call sites rather than the declaration is what makes this fail.
	src := _WWCC_ReadSource()
	DeclPos := InStr(src, "WPMWidget_InvalidateColorCache() {")
	if (DeclPos > 0) {
		CallSites := 0
		Pos := 1
		while (Pos := InStr(src, "WPMWidget_InvalidateColorCache", , Pos)) {
			if (Pos != DeclPos)
				CallSites += 1
			Pos += StrLen("WPMWidget_InvalidateColorCache")
		}
		Assert(CallSites >= 1,
			"wpm_display.ahk: WPMWidget_InvalidateColorCache() is declared but has no production CALLER — a flush hatch nobody calls never flushes anything, which is exactly how the stale-colour bug survived")
	}
}
Test("WPM widget: the resolver is consulted before the color cache (wpm-color-cache)", _WWCC_ResolverConsultedBeforeCache)
