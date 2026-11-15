; tests/meta/modules/hotstrings/prefix/test_prefix_watcher_deferred.ahk

; ==============================================================================
; MODULE: Prefix-Watcher Deferred-Index Test
; DESCRIPTION:
; Guards that the prefix-watcher trigger index (~3251 entries, ~157-234 ms) is
; built OFF the boot critical path, not synchronously inside the InputHook init.
;
; WHY THIS MATTERS (the regression this encodes):
;   HotstringPrefixWatcherInit used to rescan every category TOML synchronously at
;   boot. It now starts the InputHook with an EMPTY index, and ONE build fills it
;   from the in-memory cache after the hotstring registration, before ready. The
;   cache, not the registry, is its source, so the emoji/symbol rows that register
;   in slices after ready are already in it and their slices do not rebuild it.
;   If a future edit moves the build back into init, or makes the slices rebuild
;   it, the cost returns to the boot or the first seconds after it.
;
; SCOPE: source introspection of the watcher + hotstrings modules (not loaded by
;   the headless runner). Timer ordering is enforced by test_boot_deferred_tasks.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckPrefixWatcherDeferred() {
	; The InputHook init must NOT build the index inline anymore — its success log
	; line proves the build was deferred off the boot path.
	WBody := _DriverDirConcat("infra/hotstrings")
	Assert(InStr(WBody, "index build deferred off the boot path"),
		"HotstringPrefixWatcherInit must defer the trigger-index build off the boot critical path")

	; The index is built ONCE at boot, after the synchronous registration and before
	; ready (test_hotstrings_ready_contract pins the position). It reads the bundled
	; cache and the feature switches, never the registry, so the emoji/symbol rows
	; that register in slices after ready are already in it: the slices must not
	; rebuild it again. Body-scoped so an unrelated rebuild call elsewhere in modules/
	; cannot satisfy or trip the check.
	DeferBody := _DriverFuncBody("RegisterEmojisSymbolsDeferred")
	Assert(DeferBody != "", "hotstrings.ahk must define RegisterEmojisSymbolsDeferred()")
	Assert(InStr(DeferBody, "_EmojisSymbolsSections()"),
		"RegisterEmojisSymbolsDeferred must walk the emoji/symbol section list the inline load walks")
	Assert(!InStr(DeferBody, "HotstringPrefixWatcherRebuildIndex"),
		"the deferred emoji/symbol rows are already in the cache-built index; a second build is wasted work")
	CacheIndex := _DriverFuncBody("_RegisterCategoryTriggersFromCache")
	Assert(InStr(CacheIndex, "_HS_CACHE_ROWS") and !InStr(CacheIndex, "HSE_RegistryByGroup"),
		"the cache-built index must not depend on which rows the registry holds yet")
}

Test("meta prefix-watcher: trigger index built off the boot critical path",
	_MetaCheckPrefixWatcherDeferred)
