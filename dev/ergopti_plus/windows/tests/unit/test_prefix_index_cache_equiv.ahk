; tests/unit/test_prefix_index_cache_equiv.ahk

; ==============================================================================
; MODULE: Prefix-Index Cache-vs-TOML Equivalence Test
; DESCRIPTION:
; Regression guard for the multi-second tray-menu stall at boot (prefix-index-
; cache-rebuild). HotstringPrefixWatcherRebuildIndex used to rebuild its preview
; index by re-reading + regex-parsing every category TOML from disk. The SAME
; 3180-trigger index measured 157 ms once the OS file cache was warm but 3031 ms
; on the cold read right after a reload (magickey.toml alone is ~2119 entries),
; and that 3 s monopolised the single AHK thread so the tray menu could not open.
;
; THE FIX (the contract this test pins): bundled categories rebuild from the
; in-memory _HS_CACHE_ROWS (already parsed at boot for the HSE fast path) via
; _RegisterCategoryTriggersFromCache — no FileRead, no per-line regex. The cache
; path feeds the SAME _AddTriggerVariants pipeline as the TOML path, so the index
; it produces must be BYTE-IDENTICAL to the old TOML scan. This test drives both
; paths over the same four entries (non-case-sensitive, case-sensitive, strict,
; magic-key, with and without a per-entry priority override) and asserts the two
; indexes — and the flat trigger set — agree entry for entry. A divergence in
; trigger / output / section / length / priority or the set of prefix keys fails.
;
; Behavioural (not meta-static): hotstring_prefix_watcher.ahk and the cache rows
; are exercised directly. The TOML path uses the harness-supported "personal"
; category (a temp TOML + ScriptInformation["PersonalTomlPath"]); the cache path
; is driven with hand-built _HS_CACHE_ROWS for the same logical entries, so no
; _SharedDir (absent in the harness) is required.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ Cache vs TOML index equivalence =======
; ==================================================
; ==================================================

; Flatten one index entry to a stable string so two entries compare field-for-field.
_PWCE_EntryStr(E) {
	return E.Trigger . "|" . E.Output . "|" . E.Category . "|" . E.Section . "|" . E.Length . "|" . E.Priority
}

; Assert two prefix indexes (Map prefix -> Array of entries) are byte-identical:
; same set of prefix keys, same per-key entry count, same entry at each position.
_PWCE_AssertIndexEquiv(Toml, Cache) {
	AssertEqual(Toml.Count, Cache.Count,
		"the cache index must hold the same number of prefix keys as the TOML index")
	for Prefix, TList in Toml {
		Assert(Cache.Has(Prefix),
			"the cache index is missing prefix '" . Prefix . "' present in the TOML index")
		CList := Cache[Prefix]
		AssertEqual(TList.Length, CList.Length,
			"prefix '" . Prefix . "' must hold the same entry count via both paths")
		for I, TE in TList {
			AssertEqual(_PWCE_EntryStr(TE), _PWCE_EntryStr(CList[I]),
				"entry " . I . " under prefix '" . Prefix . "' must be identical between the cache and TOML paths")
		}
	}
}

_PrefixIndexCacheEquiv_MatchesTomlPath() {
	global ScriptInformation, Features, _HS_CACHE_ROWS, _TomlFileCache
	Star := Chr(0x2605)  ; ★ — the cache marker; both paths substitute it with MagicKey

	; ── Shared scenario: one personal section, enabled, with a known magic key ──
	if !ScriptInformation.Has("MagicKey")
		ScriptInformation["MagicKey"] := "*"
	if !Features.Has("hotstrings")
		Features["hotstrings"] := Map()
	Features["hotstrings"]["personal"] := Map("testsec", Map("enabled", true))

	; ── TOML path source: a temp personal TOML with four representative entries ──
	; is_word / auto_expand / final_result do not affect the index; the index-
	; relevant fields are trigger, output, is_case_sensitive, is_case_sensitive_strict
	; and the optional per-entry priority.
	Path := A_Temp . "\ergopti_test_pw_cache_equiv.toml"
	if FileExist(Path)
		FileDelete(Path)
	Toml := "[[testsec]]`r`n"
		. '"abc" = { output = "ABC", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = true, is_case_sensitive_strict = false, priority = 77 }' . "`r`n"
		. '"defg" = { output = "DEFG", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = true }' . "`r`n"
		. '"hij" = { output = "HIJ", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false, is_case_sensitive_strict = true, priority = 30 }' . "`r`n"
		. '"c' . Star . '" = { output = "x' . Star . '", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = true, priority = 50 }' . "`r`n"
	FileAppend(Toml, Path, "UTF-8")
	if _TomlFileCache.Has(Path)
		_TomlFileCache.Delete(Path)
	ScriptInformation["PersonalTomlPath"] := Path

	; ── Cache path source: the SAME four entries as hand-built cache rows ──
	; Row layout: [flags, trigger(★ preserved), output, finalResult, isRepeat,
	; isCaseSens, priorityOverride]. "C" in flags == is_case_sensitive_strict.
	SavedRows := _HS_CACHE_ROWS
	_HS_CACHE_ROWS := Map()
	_HS_CACHE_ROWS["personal.testsec"] := [
		["",  "abc",        "ABC",      true,  false, false, "77"],
		["",  "defg",       "DEFG",     true,  false, true,  ""],
		["C", "hij",        "HIJ",      false, false, false, "30"],
		["",  "c" . Star,   "x" . Star, true,  false, false, "50"]
	]

	; ── Build both indexes into LOCAL maps (no live-global mutation) ──
	TomlIndex := Map(), TomlSet := Map()
	_RegisterCategoryTriggers("personal", TomlIndex, TomlSet)
	CacheIndex := Map(), CacheSet := Map()
	_RegisterCategoryTriggersFromCache("personal", CacheIndex, CacheSet)

	; Restore globals BEFORE asserting so a failed assertion cannot leak state.
	_HS_CACHE_ROWS := SavedRows
	try FileDelete(Path)

	Assert(TomlIndex.Count > 0, "precondition: the TOML path must index at least one trigger")
	_PWCE_AssertIndexEquiv(TomlIndex, CacheIndex)

	; The flat trigger set (near-miss lookups depend on it) must agree as well.
	AssertEqual(TomlSet.Count, CacheSet.Count,
		"the flat trigger set must hold the same entries via both paths")
	for Trig in TomlSet
		Assert(CacheSet.Has(Trig),
			"the cache trigger set is missing '" . Trig . "' present via the TOML path")
}
Test("prefix watcher: cache-built index is byte-identical to the TOML-built index (prefix-index-cache-rebuild)",
	_PrefixIndexCacheEquiv_MatchesTomlPath)





; ===================================================
; ===================================================
; ======= 2/ Rebuild uses the in-memory cache =======
; ===================================================
; ===================================================

; Source-level guard so the dispatch can never silently revert to the cold-disk
; TOML scan that froze the thread at boot. Pairs with the behavioural equivalence
; test above (which proves the two paths agree); this one proves the rebuild
; actually TAKES the cache path and ensures the cache is loaded first.
_PrefixIndexCacheEquiv_RebuildUsesCache() {
	Body := _DriverFuncBody("HotstringPrefixWatcherRebuildIndex")
	Assert(Body != "", "hotstring_prefix_watcher.ahk must define HotstringPrefixWatcherRebuildIndex()")
	; Bundled categories must build from the in-memory cache path, not re-parse TOML.
	Assert(InStr(Body, "_RegisterCategoryTriggersFromCache(") > 0,
		"the rebuild must build bundled categories via _RegisterCategoryTriggersFromCache (in-memory), not re-parse TOML")
	Assert(InStr(Body, "_PrefixWatcherCategoryIsCached(") > 0,
		"the rebuild must gate the cache path on _PrefixWatcherCategoryIsCached so personal / cache-miss still parse TOML")
	; And it must ensure the cache is loaded BEFORE dispatching, so the boot-tail
	; warm-up rebuild (its own SetTimer) can never race ahead of the cache load and
	; fall back to the cold-disk TOML scan (the 6422 ms boot-tail rebuild in the logs).
	Assert(InStr(Body, "HotstringsCacheEnsure(") > 0,
		"the rebuild must call HotstringsCacheEnsure() before dispatching so a warm-up rebuild cannot fall back to the cold-disk TOML path")
}
Test("prefix watcher: index rebuild takes the in-memory cache path, not a cold-disk TOML rescan (prefix-index-cache-rebuild)",
	_PrefixIndexCacheEquiv_RebuildUsesCache)





; ============================================
; ============================================
; ======= 3/ Cached-category predicate =======
; ============================================
; ============================================

; The dispatcher only takes the fast in-memory path when this predicate returns
; true. A wrong answer here silently reverts the WHOLE rebuild to the cold-disk
; TOML scan even though _RegisterCategoryTriggersFromCache is correct — exactly the
; failure seen live (the boot-tail rebuild stayed at multi-second TOML timings).
_PrefixIndexCacheEquiv_PredicateSelectsBundled() {
	global _HS_CACHE_LOADED, HS_BUNDLED_CATEGORIES
	Assert(IsSet(HS_BUNDLED_CATEGORIES), "HS_BUNDLED_CATEGORIES must be a visible global")
	SavedLoaded := _HS_CACHE_LOADED
	_HS_CACHE_LOADED := true
	try {
		for Cat in HS_BUNDLED_CATEGORIES
			AssertTrue(_PrefixWatcherCategoryIsCached(Cat),
				"bundled category '" . Cat . "' must be reported cached once the cache is loaded")
		AssertTrue(!_PrefixWatcherCategoryIsCached("personal"),
			"personal is never bundled — it must take the TOML path")
		; Casing drift must not silently disable the fast path.
		AssertTrue(_PrefixWatcherCategoryIsCached("MagicKey"),
			"the bundled check must be case-insensitive")
		; With the cache not loaded the predicate must say NO (safe TOML fallback).
		_HS_CACHE_LOADED := false
		AssertTrue(!_PrefixWatcherCategoryIsCached("magickey"),
			"with the cache not loaded the predicate must report NOT cached")
	} finally {
		_HS_CACHE_LOADED := SavedLoaded
	}
}
Test("prefix watcher: cached-category predicate selects bundled categories (prefix-index-cache-rebuild)",
	_PrefixIndexCacheEquiv_PredicateSelectsBundled)
