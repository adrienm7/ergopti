; tests/meta/hotstrings/engine/prefix/test_index_rebuild_atomic_swap.ahk

; ==============================================================================
; MODULE: PrefixWatcher Index-Rebuild Atomicity Meta Test
; DESCRIPTION:
; Static source guard for finding `prefix-index-rebuild-no-suspend-guard`.
;
; HotstringPrefixWatcherRebuildIndex rebuilds the preview index off a live
; section toggle. A clear-then-repopulate (_PrefixIndex := Map() followed by a
; multi-category rescan) let an OnChar preview lookup that interleaved read an
; empty or partial index mid-rebuild. The fix builds the fresh index and set
; into local maps (NewIndex / NewSet) and assigns them to the live globals in
; one statement each at the end.
;
; This stays a source scan: the transient state lasts only while the rebuild
; runs, and one test thread cannot interleave a lookup into it. The pause half
; of the finding is called under a real Suspend in
; tests/unit/hotstrings/engine/prefix/test_deferred_pause.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ Atomicity assertions =======
; =======================================
; =======================================

_PIRSG_RebuildIsBuildThenSwap() {
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
