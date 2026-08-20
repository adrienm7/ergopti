; tests/meta/test_roi_full_map_prune_scan_on_hot_path.ahk

; ==============================================================================
; MODULE: ROI Bounded-Prune Meta Test
; DESCRIPTION:
; Static companion to the behavioural ROI prune tests.
;
; KL_Roi_ProcessWord runs on the keystroke thread at every word boundary. The
; original unbounded-growth guard scanned the whole word_counts map and dropped
; only count == 1 entries — which does NOT guarantee the map falls back below
; MAX_TRACKED_WORDS. Once the map saturated with count >= 2 entries, every
; subsequent word re-triggered a full O(n) scan + array build on the hot path.
;
; The bounded selector now computes outside Critical with linear Map passes and
; a native sort of distinct frequencies, then a
; generation-fenced short transaction swaps the complete map. The production
; module is also included headlessly for survivor/race tests; this file guards
; the whole structural class so a caller cannot re-wrap the expensive work.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

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
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the ROI prune guard")
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
	Body := _DriverFuncBody("KL_Roi_SelectWordCountSurvivors")
	Assert(Body != "", "KL_Roi_SelectWordCountSurvivors must exist for bounded selection")
	Assert(InStr(Body, "Target") > 0,
		"the selector must receive the survivor target explicitly")
	Assert(InStr(Body, "FrequencyBuckets") > 0 && InStr(Body, "Sort(") > 0,
		"the selector must use native frequency selection, not interpreted full-map sorting")
	Assert(!RegExMatch(Body, "while\s*\([^\r\n]*j\s*>=\s*1"),
		"quadratic insertion sort must not return to the ROI prune")
}

; KL_Roi_ProcessWord must delegate to the helper, not carry an inline full-map
; scan of word_counts on the hot path.
_RoiPrune_ProcessWordDelegates() {
	Body := _DriverFuncBody("KL_Roi_ProcessWord")
	Assert(Body != "", "KL_Roi_ProcessWord must exist in keylogger_trigger_roi.ahk (roi-full-map-prune-scan-on-hot-path)")
	Assert(InStr(Body, "KL_Roi_PruneWordCounts()") > 0, "KL_Roi_ProcessWord must delegate pruning to KL_Roi_PruneWordCounts, not scan the map inline on the hot path (roi-full-map-prune-scan-on-hot-path)")
	Assert(InStr(Body, "for k, v in KLRoi.word_counts") = 0, "KL_Roi_ProcessWord must not enumerate word_counts inline on the hot path (roi-full-map-prune-scan-on-hot-path)")
}

_RoiPrune_HeavyWorkOutsideCritical() {
	Body := _DriverFuncBody("KL_Roi_PruneWordCounts")
	Assert(Body != "", "KL_Roi_PruneWordCounts must exist for the critical-span guard")
	Assert(InStr(Body, "KL_Roi_SnapshotWordCounts") > 0,
		"the prune must take a generation-bound snapshot before selection")
	Assert(InStr(Body, "KL_Roi_SelectWordCountSurvivors") > 0,
		"the prune must delegate survivor computation to the bounded selector")
	Assert(InStr(Body, "KL_Roi_TryPublishPrunedCounts") > 0,
		"the prune must generation-check before atomically publishing survivors")
	Assert(InStr(Body, 'Critical("On")') = 0,
		"the top-level prune must not wrap snapshot, selection, and publication in one Critical span")
	Assert(InStr(Body, 'HotPath_LogIfSlow("KL.RoiPrune"') > 0,
		"the rare prune must retain a production latency tripwire")
}

Test("keylogger_trigger_roi: prune has a shrinking target below the cap (roi-full-map-prune-scan-on-hot-path)", _RoiPrune_HasShrinkingTarget)
Test("keylogger_trigger_roi: bounded selector evicts to PRUNE_TARGET_WORDS (roi-full-map-prune-scan-on-hot-path)", _RoiPrune_HelperEvictsToTarget)
Test("keylogger_trigger_roi: KL_Roi_ProcessWord delegates the bounded prune (roi-full-map-prune-scan-on-hot-path)", _RoiPrune_ProcessWordDelegates)
Test("keylogger_trigger_roi: survivor computation stays outside Critical (roi-prune-heavy-work-outside-critical)", _RoiPrune_HeavyWorkOutsideCritical)
