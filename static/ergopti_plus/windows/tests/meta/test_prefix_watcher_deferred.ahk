; tests/meta/test_prefix_watcher_deferred.ahk

; ==============================================================================
; MODULE: Prefix-Watcher Deferred-Index Test
; DESCRIPTION:
; Guards that the prefix-watcher trigger index (~3251 entries, ~157-234 ms) is
; built OFF the boot critical path, not synchronously inside the InputHook init.
;
; WHY THIS MATTERS (the regression this encodes):
;   HotstringPrefixWatcherInit used to rescan every category TOML synchronously at
;   boot. It now starts the InputHook with an EMPTY index; off-path passes rebuild
;   it via HotstringPrefixWatcherRebuildIndex after "ready" -- a short-delay
;   SetTimer(HotstringPrefixWatcherRebuildIndex) warms it first, then
;   RegisterEmojisSymbolsDeferred rebuilds it again once those sections register.
;   If a future edit moves the build back into init, time-to-ready regresses
;   ~200 ms with no error; if the deferred rebuild is removed, the live preview
;   silently never appears. Both are caught here.
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

	; Move-resilient: scan the modules dir for the deferred emoji/symbol pass.
	; RegisterEmojisSymbolsDeferred and HotstringPrefixWatcherRebuildIndex both
	; live only in modules/hotstrings.ahk, so the positional check below is
	; unambiguous within the modules scope.
	HsBody := _DriverDirConcat("modules")

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

	; The deferred emoji/symbol pass must ALSO call HotstringPrefixWatcherRebuildIndex
	; so the preview picks up those sections once they register off the critical path.
	DeferPos := InStr(HsBody, "RegisterEmojisSymbolsDeferred()")
	Assert(DeferPos > 0, "hotstrings.ahk must define RegisterEmojisSymbolsDeferred()")
	RebuildPos := InStr(HsBody, "HotstringPrefixWatcherRebuildIndex", , DeferPos)
	Assert(RebuildPos > 0,
		"RegisterEmojisSymbolsDeferred must call HotstringPrefixWatcherRebuildIndex so the "
		. "deferred emoji/symbol triggers appear in the live preview")
}

Test("meta prefix-watcher: trigger index built off the boot critical path",
	_MetaCheckPrefixWatcherDeferred)
