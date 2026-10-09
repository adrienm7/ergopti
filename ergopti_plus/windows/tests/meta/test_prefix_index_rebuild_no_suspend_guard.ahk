; tests/meta/test_prefix_index_rebuild_no_suspend_guard.ahk

; ==============================================================================
; MODULE: PrefixWatcher Index-Rebuild Suspend-Guard / Atomicity Meta Test
; DESCRIPTION:
; Static source guard for finding `prefix-index-rebuild-no-suspend-guard`.
;
; HotstringPrefixWatcherRebuildIndex is invoked off a live section toggle and
; rebuilds the preview index. It had two gaps:
;   (1) No A_IsSuspended guard  -  unlike its sibling InputHook callbacks
;       (_OnPrefixChar / _OnPrefixKeyDown which both early-return on suspend),
;       so the rebuild kept churning the index while the driver was paused.
;   (2) Non-atomic clear-then-repopulate (_PrefixIndex := Map() followed by a
;       multi-category rescan), so an OnChar preview lookup that interleaved
;       could read an empty / partial index mid-rebuild.
;
; The fix adds `if A_IsSuspended { return }` at the top and builds the fresh
; index/set into LOCAL maps (NewIndex / NewSet), assigning them to the live
; globals in one statement each at the end  -  never exposing the transient
; empty Map() an in-place clear would.
;
; Meta-static because HotstringPrefixWatcherRebuildIndex reads TOML files,
; touches the tooltip, and depends on the InputHook being live; calling it
; headless is unsafe.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_PIRSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard and atomicity assertions ========
; ==================================================
; ==================================================

_PIRSG_RebuildHasSuspendGuard() {
	Src := _PIRSG_ReadSource("infra/hotstrings/hotstring_prefix_watcher.ahk")
	Seg := _DriverFuncBody("HotstringPrefixWatcherRebuildIndex")
	Assert(Seg != "", "HotstringPrefixWatcherRebuildIndex must exist in hotstring_prefix_watcher.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"HotstringPrefixWatcherRebuildIndex must check A_IsSuspended  -  a rebuild armed before Pause would otherwise churn the index while the watcher is meant to be silent")
}
Test("PrefixWatcher: RebuildIndex has an A_IsSuspended guard (prefix-index-rebuild-no-suspend-guard)", _PIRSG_RebuildHasSuspendGuard)

_PIRSG_RebuildIsBuildThenSwap() {
	Src := _PIRSG_ReadSource("infra/hotstrings/hotstring_prefix_watcher.ahk")
	Seg := _DriverFuncBody("HotstringPrefixWatcherRebuildIndex")
	Assert(Seg != "", "HotstringPrefixWatcherRebuildIndex must exist in hotstring_prefix_watcher.ahk")
	; Build-then-swap: fresh locals are populated, then assigned to the globals.
	Assert(InStr(Seg, "NewIndex := Map()") > 0 and InStr(Seg, "NewSet := Map()") > 0,
		"RebuildIndex must build the fresh index/set into local maps (NewIndex / NewSet)")
	Assert(InStr(Seg, "_PrefixIndex := NewIndex") > 0 and InStr(Seg, "_TriggerSet := NewSet") > 0,
		"RebuildIndex must swap the freshly-built locals into the globals in a single statement each")
	; The non-atomic in-place clear must be gone  -  exposing it again would let an
	; OnChar lookup read an empty index mid-rebuild.
	Assert(InStr(Seg, "_PrefixIndex := Map()") == 0,
		"RebuildIndex must not clear _PrefixIndex in place (_PrefixIndex := Map())  -  that exposes an empty index to a concurrent OnChar lookup")
}
Test("PrefixWatcher: RebuildIndex builds-then-swaps the index atomically (prefix-index-rebuild-no-suspend-guard)", _PIRSG_RebuildIsBuildThenSwap)
