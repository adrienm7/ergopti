; tests/meta/test_appstate_orphaned_parallel_state.ahk

; ==============================================================================
; MODULE: AppState Orphaned Parallel-State Meta Test
; DESCRIPTION:
; Static source guard for finding appstate-orphaned-parallel-state.
;
; lib/app_state.ahk once declared an "AppState" Map plus typed accessors
; (AppState_GetNumberOfRepetitions, AppState_TouchLastSentKey, AppState_Reset,
; AppState_PruneLastSentKeyTime, etc.) as a consolidation target for the
; driver's mutable cross-module state. The cut-over never happened: every
; consumer kept reading and writing the plain top-level globals
; (NumberOfRepetitions, LastSentCharacterKeyTime, ...) declared in
; ErgoptiPlus.ahk, with the write/prune logic living in nav_layer_helpers.ahk
; and modules/keymap/layout.ahk. The Map was therefore a parallel UNUSED copy of the
; live state - a single-source-of-truth trap: wiring one caller to the Map
; while another stays on the global yields two diverging counters with no
; compile error.
;
; The fix removes the dead Map and its accessors so there is exactly one copy
; of each field. This is a meta-static test (scans source text) because
; app_state.ahk is part of the headless include graph and must stay loadable;
; the assertions below fail if the parallel state container is reintroduced.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helper ====================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_AOPS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Parallel-state absence guards =========
; ==================================================
; ==================================================

; The dead Map must not exist: it is the parallel copy of the live globals.
_AOPS_NoParallelMap() {
	Src := _AOPS_ReadSource("lib/app_state.ahk")
	Assert(InStr(Src, "AppState := Map(") == 0,
		"lib/app_state.ahk must not declare an AppState Map - it is a parallel unused copy of the live globals and a single-source-of-truth trap (appstate-orphaned-parallel-state)")
}
Test("app_state: no parallel AppState Map declaration (appstate-orphaned-parallel-state)", _AOPS_NoParallelMap)

; The typed accessors fronting the dead Map must not exist either.
_AOPS_NoDeadAccessors() {
	Src := _AOPS_ReadSource("lib/app_state.ahk")
	Assert(InStr(Src, "AppState_GetNumberOfRepetitions(") == 0,
		"AppState_GetNumberOfRepetitions must be removed - the live counter lives in NumberOfRepetitions via nav_layer_helpers.ahk (appstate-orphaned-parallel-state)")
	Assert(InStr(Src, "AppState_TouchLastSentKey(") == 0,
		"AppState_TouchLastSentKey must be removed - last_sent_key_time is owned by modules/keymap/layout.ahk (appstate-orphaned-parallel-state)")
	Assert(InStr(Src, "AppState_Reset(") == 0,
		"AppState_Reset must be removed - there is no parallel Map left to reset (appstate-orphaned-parallel-state)")
}
Test("app_state: dead AppState_* accessors are removed (appstate-orphaned-parallel-state)", _AOPS_NoDeadAccessors)

; The pruning thresholds must have a single declaration in the live entry
; script, not a duplicate copy in app_state.ahk.
_AOPS_ThresholdsSingleSource() {
	StateSrc := _AOPS_ReadSource("lib/app_state.ahk")
	Assert(InStr(StateSrc, "global LAST_SENT_KEY_TIME_PRUNE_AT :=") == 0,
		"LAST_SENT_KEY_TIME_PRUNE_AT must be declared once in ErgoptiPlus.ahk, not duplicated in app_state.ahk (appstate-orphaned-parallel-state)")
	Assert(InStr(StateSrc, "global LAST_SENT_KEY_TIME_MAX_AGE_MS :=") == 0,
		"LAST_SENT_KEY_TIME_MAX_AGE_MS must be declared once in ErgoptiPlus.ahk, not duplicated in app_state.ahk (appstate-orphaned-parallel-state)")

	EntrySrc := _DriverSourceConcat()
	Assert(InStr(EntrySrc, "global LAST_SENT_KEY_TIME_PRUNE_AT :=") > 0,
		"ErgoptiPlus.ahk must remain the single source for LAST_SENT_KEY_TIME_PRUNE_AT (appstate-orphaned-parallel-state)")
}
Test("app_state: prune thresholds have a single source in ErgoptiPlus.ahk (appstate-orphaned-parallel-state)", _AOPS_ThresholdsSingleSource)

; RemappedList is the canonical global for remap tracking (declared in ErgoptiPlus.ahk).
; layout.ahk and shortcuts/utils.ahk previously referenced the removed AppState Map via
; AppState["remapped_list"], which caused an UnsetError crash on boot (AppState is unset).
_AOPS_NoRemappedListViaAppState() {
	LayoutSrc   := _AOPS_ReadSource("modules/keymap/layout.ahk")
	ShortcutSrc := _AOPS_ReadSource("modules/shortcuts/utils.ahk")
	; Search for the string key used in the removed AppState Map
	Assert(InStr(LayoutSrc, "remapped_list") == 0,
		"modules/keymap/layout.ahk must not access AppState[remapped_list] - use RemappedList directly (appstate-orphaned-parallel-state)")
	Assert(InStr(ShortcutSrc, "remapped_list") == 0,
		"modules/shortcuts/utils.ahk must not access AppState[remapped_list] - use RemappedList directly (appstate-orphaned-parallel-state)")
}
Test("app_state: remapped_list accessed via RemappedList, not AppState (appstate-orphaned-parallel-state)", _AOPS_NoRemappedListViaAppState)
