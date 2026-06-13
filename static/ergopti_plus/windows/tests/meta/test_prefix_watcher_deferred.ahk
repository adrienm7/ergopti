; tests/meta/test_prefix_watcher_deferred.ahk

; ==============================================================================
; MODULE: Prefix-Watcher Deferred-Index Test
; DESCRIPTION:
; Guards that the prefix-watcher trigger index (~3251 entries, ~157-234 ms) is
; built OFF the boot critical path, not synchronously inside the InputHook init.
;
; WHY THIS MATTERS (the regression this encodes):
;   HotstringPrefixWatcherInit used to rescan every category TOML synchronously at
;   boot. It now starts the InputHook with an EMPTY index; the deferred passes
;   (RegisterTextExpansionDeferred / RegisterEmojisSymbolsDeferred) rebuild it via
;   HotstringPrefixWatcherRebuildIndex after "ready". If a future edit moves the
;   build back into init, time-to-ready regresses ~200 ms with no error; if the
;   deferred rebuild is removed, the live preview silently never appears. Both are
;   caught here.
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
	SplitPath(A_ScriptDir, , &WindowsDir)
	WatcherFile := WindowsDir . "\lib\hotstrings\hotstring_prefix_watcher.ahk"
	HsFile := WindowsDir . "\modules\hotstrings.ahk"

	WBody := ""
	try WBody := FileRead(WatcherFile)
	Assert(WBody != "", "hotstring_prefix_watcher.ahk must be readable")

	; The InputHook init must NOT build the index inline anymore — its success log
	; line proves the build was deferred off the boot path.
	Assert(InStr(WBody, "index build deferred off the boot path"),
		"HotstringPrefixWatcherInit must defer the trigger-index build off the boot critical path")

	HsBody := ""
	try HsBody := FileRead(HsFile)
	Assert(HsBody != "", "modules\hotstrings.ahk must be readable")

	; The deferred text-expansion pass (always armed at the boot tail, unconditional
	; rebuild) must call HotstringPrefixWatcherRebuildIndex, so the empty-at-boot
	; index is guaranteed to be filled off the critical path.
	DeferPos := InStr(HsBody, "RegisterTextExpansionDeferred()")
	Assert(DeferPos > 0, "hotstrings.ahk must define RegisterTextExpansionDeferred()")
	RebuildPos := InStr(HsBody, "HotstringPrefixWatcherRebuildIndex", , DeferPos)
	Assert(RebuildPos > 0,
		"RegisterTextExpansionDeferred must call HotstringPrefixWatcherRebuildIndex so the "
		. "empty-at-boot prefix index is guaranteed to be built off the critical path")
}

Test("meta prefix-watcher: trigger index built off the boot critical path",
	_MetaCheckPrefixWatcherDeferred)
