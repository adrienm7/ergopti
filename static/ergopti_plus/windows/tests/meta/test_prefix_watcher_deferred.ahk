; tests/meta/test_prefix_watcher_deferred.ahk

; ==============================================================================
; MODULE: Prefix-Watcher Deferred-Index Test
; DESCRIPTION:
; Guards that the prefix-watcher trigger index (~3251 entries, ~157-234 ms) is
; built OFF the boot critical path, not synchronously inside the InputHook init.
;
; WHY THIS MATTERS (the regression this encodes):
;   HotstringPrefixWatcherInit used to rescan every category TOML synchronously at
;   boot. It now starts the InputHook with an EMPTY index; a SINGLE off-path pass
;   builds it — at the END of RegisterEmojisSymbolsDeferred, after the emoji/symbol
;   HSE sections register. By then HotstringsResolve is memoised for every section and
;   the boot has settled, so the rebuild is reliably ~220 ms. (An earlier "warm-up"
;   SetTimer also built it, but it fired during peak boot contention before
;   HotstringsResolve was warm, giving erratic 250 ms–6 s timings, so it was removed.)
;   If a future edit moves the build back into init, time-to-ready regresses ~200 ms;
;   if the deferred build is dropped, the live preview never appears. Both are caught.
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
	WBody := _DriverDirConcat("lib/hotstrings")
	Assert(InStr(WBody, "index build deferred off the boot path"),
		"HotstringPrefixWatcherInit must defer the trigger-index build off the boot critical path")

	; The SINGLE index build happens at the END of the deferred emoji/symbol pass:
	; RegisterEmojisSymbolsDeferred registers the HSE sections, THEN rebuilds the prefix
	; index once. By then HotstringsResolve is memoised for every section and the boot
	; has settled, so the rebuild is reliably ~220 ms (the earlier warm-up SetTimer, which
	; ran during peak contention with erratic 250 ms–6 s timings, was removed). Body-scoped
	; so an unrelated rebuild call elsewhere in modules/ cannot satisfy or trip the check.
	DeferBody := _DriverFuncBody("RegisterEmojisSymbolsDeferred")
	Assert(DeferBody != "", "hotstrings.ahk must define RegisterEmojisSymbolsDeferred()")
	Assert(InStr(DeferBody, "_RegisterEmojisSymbolsSections"),
		"RegisterEmojisSymbolsDeferred must register the emoji/symbol HSE sections")
	Assert(InStr(DeferBody, "HotstringPrefixWatcherRebuildIndex"),
		"RegisterEmojisSymbolsDeferred must build the prefix index once (after the HSE "
		. "sections register and the boot settles) — the single, reliably-fast index build")
}

Test("meta prefix-watcher: trigger index built off the boot critical path",
	_MetaCheckPrefixWatcherDeferred)
