; tests/meta/test_roi_full_map_prune_scan_on_hot_path.ahk

; ==============================================================================
; MODULE: ROI Bounded-Prune Meta Test
; DESCRIPTION:
; Static source guard for the roi-full-map-prune-scan-on-hot-path finding.
;
; KL_Roi_ProcessWord runs on the keystroke thread at every word boundary. The
; original unbounded-growth guard scanned the whole word_counts map and dropped
; only count == 1 entries — which does NOT guarantee the map falls back below
; MAX_TRACKED_WORDS. Once the map saturated with count >= 2 entries, every
; subsequent word re-triggered a full O(n) scan + array build on the hot path.
;
; The fix extracts the prune into KL_Roi_PruneWordCounts and makes it bounded
; and guaranteed-shrinking: it evicts down to PRUNE_TARGET_WORDS (strictly less
; than MAX_TRACKED_WORDS) so the map always drops below the cap and the next
; word cannot immediately re-trigger another full scan.
;
; This is a meta-static test (scans source text) because keylogger_trigger_roi
; is NOT in the run_all.ahk include graph — it is reached only through the
; keylogger module which registers top-level hooks, so it cannot be #Included
; in the headless runner without blocking clean exit.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_RoiPrune_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Reads the integer value assigned to a `static NAME := <int>` constant in the
; KLRoiConst block. Returns -1 when the constant is absent.
_RoiPrune_ConstValue(Src, Name) {
	if !RegExMatch(Src, "static\s+" . Name . "\s*:=\s*(\d+)", &M)
		return -1
	return M[1] + 0
}




; ===================================================
; ===================================================
; ======= 2/ Bounded-prune assertions ===============
; ===================================================
; ===================================================

; The map must shrink to a target strictly below the cap. If PRUNE_TARGET_WORDS
; is missing, or is >= MAX_TRACKED_WORDS, the prune is not guaranteed-shrinking
; and the hot-path full scan can recur every word once saturated.
_RoiPrune_HasShrinkingTarget() {
	Src := _RoiPrune_ReadSource("modules/keylogger/keylogger_trigger_roi.ahk")
	Cap := _RoiPrune_ConstValue(Src, "MAX_TRACKED_WORDS")
	Target := _RoiPrune_ConstValue(Src, "PRUNE_TARGET_WORDS")
	Assert(Cap > 0, "KLRoiConst.MAX_TRACKED_WORDS must be defined (roi-full-map-prune-scan-on-hot-path)")
	Assert(Target > 0, "KLRoiConst.PRUNE_TARGET_WORDS must be defined so the prune shrinks below the cap (roi-full-map-prune-scan-on-hot-path)")
	Assert(Target < Cap, "PRUNE_TARGET_WORDS must be strictly below MAX_TRACKED_WORDS so the prune always drops the map under the cap (roi-full-map-prune-scan-on-hot-path)")
}

; The prune must be extracted into KL_Roi_PruneWordCounts and that helper must
; reference PRUNE_TARGET_WORDS for its second eviction pass — that is the bound
; that guarantees the map shrinks even when no count == 1 noise exists.
_RoiPrune_HelperEvictsToTarget() {
	Src := _RoiPrune_ReadSource("modules/keylogger/keylogger_trigger_roi.ahk")
	Body := _DriverFuncBody("KL_Roi_PruneWordCounts")
	Assert(Body != "", "KL_Roi_PruneWordCounts must exist in keylogger_trigger_roi.ahk (roi-full-map-prune-scan-on-hot-path)")
	Assert(InStr(Body, "PRUNE_TARGET_WORDS") > 0, "KL_Roi_PruneWordCounts must evict down to PRUNE_TARGET_WORDS (roi-full-map-prune-scan-on-hot-path)")
	Assert(InStr(Body, ".Delete(") > 0, "KL_Roi_PruneWordCounts must Delete entries to actually shrink the map (roi-full-map-prune-scan-on-hot-path)")
}

; KL_Roi_ProcessWord must delegate to the helper, not carry an inline full-map
; scan of word_counts on the hot path.
_RoiPrune_ProcessWordDelegates() {
	Src := _RoiPrune_ReadSource("modules/keylogger/keylogger_trigger_roi.ahk")
	Body := _DriverFuncBody("KL_Roi_ProcessWord")
	Assert(Body != "", "KL_Roi_ProcessWord must exist in keylogger_trigger_roi.ahk (roi-full-map-prune-scan-on-hot-path)")
	Assert(InStr(Body, "KL_Roi_PruneWordCounts()") > 0, "KL_Roi_ProcessWord must delegate pruning to KL_Roi_PruneWordCounts, not scan the map inline on the hot path (roi-full-map-prune-scan-on-hot-path)")
	Assert(InStr(Body, "for k, v in KLRoi.word_counts") = 0, "KL_Roi_ProcessWord must not enumerate word_counts inline on the hot path (roi-full-map-prune-scan-on-hot-path)")
}

Test("keylogger_trigger_roi: prune has a shrinking target below the cap (roi-full-map-prune-scan-on-hot-path)", _RoiPrune_HasShrinkingTarget)
Test("keylogger_trigger_roi: KL_Roi_PruneWordCounts evicts to PRUNE_TARGET_WORDS (roi-full-map-prune-scan-on-hot-path)", _RoiPrune_HelperEvictsToTarget)
Test("keylogger_trigger_roi: KL_Roi_ProcessWord delegates prune off the hot path (roi-full-map-prune-scan-on-hot-path)", _RoiPrune_ProcessWordDelegates)
