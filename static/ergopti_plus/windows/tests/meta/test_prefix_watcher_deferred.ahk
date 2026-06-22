; tests/meta/test_prefix_watcher_deferred.ahk

; ==============================================================================
; MODULE: Prefix-Watcher Deferred-Index Test
; DESCRIPTION:
; Guards that the prefix-watcher trigger index (~3251 entries, ~157-234 ms) is
; built OFF the boot critical path, not synchronously inside the InputHook init.
;
; WHY THIS MATTERS (the regression this encodes):
;   HotstringPrefixWatcherInit used to rescan every category TOML synchronously at
;   boot. It now starts the InputHook with an EMPTY index; a single off-path pass
;   builds it: the short-delay SetTimer(HotstringPrefixWatcherRebuildIndex) warm-up,
;   which now builds from the in-memory cache + Features and so produces a COMPLETE
;   3180-trigger index INCLUDING the emoji/symbol sections (they live in the cache +
;   Features independent of HSE registration timing). RegisterEmojisSymbolsDeferred
;   therefore must NOT rebuild the index again — that second rebuild produced the
;   identical index and was pure redundant boot work. If a future edit moves the
;   build back into init, time-to-ready regresses ~200 ms; if the redundant deferred
;   rebuild is re-added, boot does needless work. Both are caught here.
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

	; Move-resilient: scan the hotstrings lib dir for the watcher's deferred-build
	; log line. That message is unique to hotstring_prefix_watcher.ahk, so the
	; present-string check is unambiguous within the scope.
	WBody := _DriverDirConcat("lib/hotstrings")

	; The InputHook init must NOT build the index inline anymore — its success log
	; line proves the build was deferred off the boot path.
	Assert(InStr(WBody, "index build deferred off the boot path"),
		"HotstringPrefixWatcherInit must defer the trigger-index build off the boot critical path")

	; The boot tail must warm the empty-at-boot index off the critical path with a
	; short-delay SetTimer(HotstringPrefixWatcherRebuildIndex). (That it is armed
	; AFTER "ready" is enforced by test_boot_deferred_tasks.) ErgoptiPlus.ahk is the
	; windows-root entry point (no modules/lib/ui segment), so it stays a pinned read.
	BootBody := ""
	try BootBody := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	Assert(BootBody != "", "ErgoptiPlus.ahk must be readable")
	Assert(InStr(BootBody, "SetTimer(HotstringPrefixWatcherRebuildIndex"),
		"ErgoptiPlus.ahk must arm SetTimer(HotstringPrefixWatcherRebuildIndex) to warm the "
		. "empty-at-boot prefix index off the critical path")

	; The deferred emoji/symbol pass must register those sections into the HSE but must
	; NOT rebuild the prefix index: the warm-up already built a complete index from the
	; cache + Features (which include these sections), so a second rebuild is redundant
	; boot work (prefix-index-cache-rebuild). Body-scoped so an unrelated rebuild call
	; elsewhere in modules/ cannot satisfy or trip the check.
	DeferBody := _DriverFuncBody("RegisterEmojisSymbolsDeferred")
	Assert(DeferBody != "", "hotstrings.ahk must define RegisterEmojisSymbolsDeferred()")
	Assert(InStr(DeferBody, "_RegisterEmojisSymbolsSections"),
		"RegisterEmojisSymbolsDeferred must still register the emoji/symbol HSE sections")
	Assert(!InStr(DeferBody, "HotstringPrefixWatcherRebuildIndex"),
		"RegisterEmojisSymbolsDeferred must NOT rebuild the prefix index — the warm-up "
		. "SetTimer already builds a complete index from the cache+Features; a second "
		. "rebuild here is redundant boot work (it produced the identical 3180-trigger index)")
}

Test("meta prefix-watcher: trigger index built off the boot critical path",
	_MetaCheckPrefixWatcherDeferred)
