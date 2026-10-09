; tests/meta/test_menu_master_category_cache.ahk

; ==============================================================================
; MODULE: Menu Master-Category Manifest Cache Meta Test
; DESCRIPTION:
; Regression guard for the per-item manifest re-parse found by the 2026-07-21
; performance audit. _MG_LoadHotstringSubCategories is called by
; _MasterCategoryFor, which MenuAddItemFromManifest calls once per menu item --
; about a hundred times per menu build. It used to open and decode the 12.5 KB
; menu_manifest.json on every one of those calls. A standalone bench of the
; driver's own parser measured ~44 ms for a single decode, so the menu build
; paid roughly 4 s of pure re-decoding at every boot AND at every live rebuild;
; the boot profiler corroborates it (the "flat hotstring submenus" phase, 54
; items, averaged 1994 ms over 58 boots).
;
; The fix reuses _MR_GetManifestRoot() -- the menu renderer's already-parsed,
; already-cached root for the very same file -- turning O(items) decodes into
; O(1). No new cache is introduced.
;
; ROOT CAUSE ENCODED:
; Three independent things must stay true or the bug silently returns:
;   1. the loader must not open or decode the manifest itself;
;   2. the .Has() guard chain must survive -- "master_gates" is ABSENT from the
;      real manifest, and an unguarded Map["missing_key"] THROWS in AHK v2, so
;      dropping a guard turns every menu build into an exception;
;   3. the sibling _MG_LoadSubCategories (infra/master_gates.ahk) must NOT get the
;      same treatment -- its non-memoization is a deliberate fail-fast contract
;      pinned by tests/unit/test_master_gates.ahk.
;
; SCOPE: source introspection via _DriverFuncBody, plus a behavioural check
; against the real shared menu_manifest.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================
; =================================================
; ======= 1/ The loader no longer re-parses =======
; =================================================
; =================================================

; NOTE for future editors: _DriverFuncBody strips FULL-LINE comments only, so an
; END-OF-LINE comment mentioning the scanned tokens would fail this test against
; correct code. The driver-side body is deliberately written without them.
_MMCC_CheckNoPerItemReparse() {
	Body := _DriverFuncBody("_MG_LoadHotstringSubCategories")
	Assert(Body != "", "_MG_LoadHotstringSubCategories must exist in the driver source")

	Assert(!InStr(Body, "FileRead("),
		"_MG_LoadHotstringSubCategories must not open the manifest itself -- it runs once per menu item (~100x per build), so a per-call read is paid ~100x for one file")
	Assert(!InStr(Body, "JsonParse("),
		"_MG_LoadHotstringSubCategories must not decode the manifest itself -- one decode of the 12.5 KB manifest benches at ~44 ms, i.e. seconds per menu build")
	Assert(InStr(Body, "_MR_GetManifestRoot") > 0,
		"_MG_LoadHotstringSubCategories must read the shared, already-cached manifest root via _MR_GetManifestRoot()")
}
Test("menu: _MG_LoadHotstringSubCategories reuses the cached manifest root instead of re-parsing per item (menu-master-category-reparse)",
	_MMCC_CheckNoPerItemReparse)





; ==================================================
; ==================================================
; ======= 2/ The .Has() guard chain survives =======
; ==================================================
; ==================================================

_MMCC_CheckGuardChainPreserved() {
	Body := _DriverFuncBody("_MG_LoadHotstringSubCategories")
	Assert(Body != "", "_MG_LoadHotstringSubCategories must exist in the driver source")

	Assert(InStr(Body, '.Has("master_gates")') > 0,
		'the .Has("master_gates") guard must survive the cache refactor -- the key is absent from the real manifest and an unguarded Root["master_gates"] THROWS in AHK v2')
	Assert(InStr(Body, '.Has("hotstring_sub_categories")') > 0,
		'the .Has("hotstring_sub_categories") guard must survive -- same throw-on-absent-key contract one level down')

	for _, Cat in ["Autocorrection", "DistancesReduction", "SFBsReduction",
		"Rolls", "MagicKey", "DynamicHotstrings", "Personal"] {
		Assert(InStr(Body, '"' . Cat . '"') > 0,
			"the hardcoded default sub-category list must still contain " . Cat
			. " -- it is the list actually in force, since the manifest declares no master_gates key")
	}
}
Test("menu: _MG_LoadHotstringSubCategories keeps its .Has() guard chain and its seven defaults (menu-master-category-reparse)",
	_MMCC_CheckGuardChainPreserved)





; ======================================================
; ======================================================
; ======= 3/ The defaults branch is the live one =======
; ======================================================
; ======================================================

_MMCC_ManifestPath() {
	SplitPath(A_ScriptDir, , &WinDir)
	SplitPath(WinDir, , &EpDir)
	return EpDir . "\_shared\modules\menu\menu_manifest.json"
}

_MMCC_CheckDefaultBranchIsTheLiveOne() {
	Raw := ""
	try Raw := FileRead(_MMCC_ManifestPath(), "UTF-8")
	Assert(Raw != "", "menu_manifest.json must be readable at " . _MMCC_ManifestPath())

	Root := ""
	try Root := JsonParse(Raw)
	Assert(Root is Map, "menu_manifest.json root must parse to a Map")

	AssertFalse(Root.Has("master_gates"),
		'menu_manifest.json has grown a "master_gates" key: _MG_LoadHotstringSubCategories now takes its manifest branch instead of the hardcoded defaults, so the cache refactor is no longer behaviour-neutral -- re-verify the sub-category list by hand before touching this test')

	AssertThrows(() => Root["master_gates"],
		'reading an absent key from a Map must throw in AHK v2 -- this is exactly why the .Has("master_gates") guard cannot be dropped')
}
Test("menu: the real manifest has no master_gates key, so the hardcoded defaults are the live branch (menu-master-category-reparse)",
	_MMCC_CheckDefaultBranchIsTheLiveOne)





; =============================================================
; =============================================================
; ======= 4/ The shared accessor never caches a failure =======
; =============================================================
; =============================================================

; GUARANTEE, unchanged: the shared menu-manifest accessor must never cache a
; FAILED load, or a transient I/O error freezes the whole session into the
; fallback defaults with no retry.
;
; Only the ASSERTION moved. It used to name _MR_MANIFEST_CACHE inside
; _MR_GetManifestRoot, which pinned a SECOND independent decode of the very same
; menu_manifest.json in place -- a mechanism, and a ~44 ms one on the boot path.
; _MR_GetManifestRoot now delegates to the single shared decoder, so the property
; is asserted where the disk read and the cache write actually live, and the
; delegation itself is asserted so the second decode cannot quietly come back.
_MMCC_CheckAccessorDoesNotCacheFailure() {
	Entry := _DriverFuncBody("_MR_GetManifestRoot")
	Assert(Entry != "", "_MR_GetManifestRoot must exist in the driver source")
	Assert(!InStr(Entry, "FileRead(") and !InStr(Entry, "JsonParse("),
		"_MR_GetManifestRoot must not read or decode menu_manifest.json itself -- one decode of the 12.5 KB manifest benches at ~44 ms and the shared accessor has already paid it")
	Assert(InStr(Entry, "_MM_GetManifestRoot") > 0,
		"_MR_GetManifestRoot must resolve the manifest through the single shared accessor _MM_GetManifestRoot()")

	Body := _DriverFuncBody("_MM_GetManifestRoot")
	Assert(Body != "", "_MM_GetManifestRoot must exist in the driver source")

	AssignPos := InStr(Body, "_MM_MANIFEST_ROOT_CACHE := Root")
	Assert(AssignPos > 0,
		"the shared accessor must publish the parsed root into its cache")

	FailPos := InStr(Body, "return false")
	Assert(FailPos > 0 and FailPos < AssignPos,
		"the shared accessor must return false on failure BEFORE writing the cache -- caching a failed load would freeze the whole session into the fallback defaults with no retry")
}
Test("menu: _MR_GetManifestRoot caches only successful loads, so a transient failure stays retryable (menu-master-category-reparse)",
	_MMCC_CheckAccessorDoesNotCacheFailure)





; =========================================================
; =========================================================
; ======= 5/ The fail-fast sibling stays unmemoized =======
; =========================================================
; =========================================================

_MMCC_CheckMasterGatesLoaderStillFailFast() {
	Body := _DriverFuncBody("_MG_LoadSubCategories")
	Assert(Body != "", "_MG_LoadSubCategories must exist in the driver source")

	Assert(InStr(Body, "_MR_GetManifestRoot") == 0,
		"_MG_LoadSubCategories must NOT be routed through the menu-renderer cache -- its non-memoization is deliberate (an invalid canonical manifest must throw on EVERY call) and is pinned by tests/unit/test_master_gates.ahk")
	Assert(InStr(Body, "throw Error(") > 0,
		"_MG_LoadSubCategories must keep throwing on an invalid manifest instead of falling back to a default table")
}
Test("menu: _MG_LoadSubCategories keeps its deliberate fail-fast non-memoization (menu-master-category-reparse)",
	_MMCC_CheckMasterGatesLoaderStillFailFast)
