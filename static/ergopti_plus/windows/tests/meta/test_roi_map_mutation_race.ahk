; tests/meta/test_roi_map_mutation_race.ahk

#Requires AutoHotkey v2.0

_RMMR_AssertHalflifeTickAtomic() {
	; Move-resilient: locate KL_Roi_HalflifeTick across the driver source via the
	; framework helper instead of a pinned keylogger_trigger_roi.ahk path. Both
	; Critical("On") and snapshot[trig] := last_tick are code (not comments), so the
	; positional check below is preserved by the comment-stripping helper.
	Body := _DriverFuncBody("KL_Roi_HalflifeTick")
	Assert(Body != "", "KL_Roi_HalflifeTick must exist in keylogger_trigger_roi.ahk")
	
	CritOnIdx := InStr(Body, 'Critical("On")')
	Assert(CritOnIdx > 0, "KL_Roi_HalflifeTick must use Critical('On') (roi-map-mutation-during-enumeration-race)")
	
	SnapIdx := InStr(Body, "snapshot[trig] := last_tick")
	Assert(SnapIdx > CritOnIdx, "KL_Roi_HalflifeTick must copy to a snapshot under Critical (roi-map-mutation-during-enumeration-race)")
}

_RMMR_AssertProcessWordAtomic() {
	; Only the map mutation, snapshot clone, and generation-checked swap are
	; atomic. Survivor selection must remain interruptible so a rare prune cannot
	; freeze the keyboard for hundreds of milliseconds.
	Increment := _DriverFuncBody("KL_Roi_IncrementWordCount")
	Snapshot := _DriverFuncBody("KL_Roi_SnapshotWordCounts")
	Publish := _DriverFuncBody("KL_Roi_TryPublishPrunedCounts")
	Assert(Increment != "" && Snapshot != "" && Publish != "",
		"ROI word-count mutation, snapshot, and publication helpers must all exist")
	for Txn in [
		{Body: Increment, Fragment: "word_counts_generation += 1", Name: "increment"},
		{Body: Snapshot, Fragment: "word_counts.Clone()", Name: "snapshot"},
		{Body: Publish, Fragment: "State.word_counts := NextCounts", Name: "publish"}
	] {
		CritOnIdx := InStr(Txn.Body, 'Critical("On")')
		WorkIdx := InStr(Txn.Body, Txn.Fragment, , CritOnIdx)
		RestoreIdx := InStr(Txn.Body, "Critical(previous_critical)", , WorkIdx)
		Assert(CritOnIdx > 0 && WorkIdx > CritOnIdx && RestoreIdx > WorkIdx,
			"ROI " . Txn.Name . " transaction must mutate under a caller-state-preserving Critical span")
	}
}

Test("keylogger_trigger_roi: KL_Roi_HalflifeTick enumerates map atomically (roi-map-mutation-during-enumeration-race)", _RMMR_AssertHalflifeTickAtomic)
Test("keylogger_trigger_roi: ROI prune boundaries are atomic (roi-map-mutation-during-enumeration-race)", _RMMR_AssertProcessWordAtomic)
