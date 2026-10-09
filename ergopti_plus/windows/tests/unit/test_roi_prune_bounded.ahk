; tests/unit/test_roi_prune_bounded.ahk

; ==============================================================================
; MODULE: ROI Bounded-Prune Behaviour Tests
; DESCRIPTION:
; The 501st distinct candidate word used to insertion-sort the complete map
; inside Critical, freezing the keyboard for 203-359 ms. These tests drive the
; production selector and publication transaction: survivors retain the exact
; frequency/insertion-order policy, interpreted work uses bounded passes, and a
; stale snapshot can never overwrite a word recorded while selection was running.
; (AHK-11.)
; ==============================================================================

#Requires AutoHotkey v2.0

_ROIP_AdversarialCounts() {
	Counts := Map()
	loop 501 {
		; Descending distinct frequencies are the insertion sort's quadratic case.
		Counts[Format("word{1:03}", A_Index)] := 503 - A_Index
	}
	return Counts
}

_ROIP_SelectorIsBoundedAndExact() {
	Counts := _ROIP_AdversarialCounts()
	Operations := 0
	Survivors := KL_Roi_SelectWordCountSurvivors(Counts, 250, &Operations)

	AssertEqual(250, Survivors.Count,
		"the selector must shrink a saturated candidate map to the configured target")
	loop 250 {
		AssertTrue(Survivors.Has(Format("word{1:03}", A_Index)),
			"the highest-frequency candidates must survive the prune")
	}
	AssertFalse(Survivors.Has("word251"),
		"the first candidate below the survivor boundary must be evicted")
	Assert(Operations <= 1300,
		"501 entries must stay within three bounded interpreted passes, never quadratic insertion sort; operations=" . Operations)

	; Equal counts preserve Map insertion order in the old stable sort: eviction
	; removes the earliest ties, so later observations survive at the boundary.
	Ties := Map("early", 3, "middle", 3, "late", 3, "noise", 1)
	TieOps := 0
	TieSurvivors := KL_Roi_SelectWordCountSurvivors(Ties, 2, &TieOps)
	AssertFalse(TieSurvivors.Has("early"),
		"the earliest equal-frequency candidate must be evicted at the boundary")
	AssertTrue(TieSurvivors.Has("middle") && TieSurvivors.Has("late"),
		"later equal-frequency candidates must retain the historical tie policy")
	AssertFalse(TieSurvivors.Has("noise"),
		"single-occurrence noise must still be discarded before frequency selection")
}
Test("keylogger ROI: survivor selection is exact and bounded (roi-prune-bounded)",
	_ROIP_SelectorIsBoundedAndExact)

_ROIP_StaleSnapshotCannotPublish() {
	State := {word_counts: Map("live", 7), word_counts_generation: 10}
	Stale := Map("stale", 99)

	AssertFalse(KL_Roi_TryPublishPrunedCounts(State, 9, Stale),
		"a snapshot whose generation lost a race must not replace live word counts")
	AssertTrue(State.word_counts.Has("live") && !State.word_counts.Has("stale"),
		"rejecting a stale prune must leave the live map unchanged")
	AssertEqual(10, State.word_counts_generation,
		"rejecting a stale prune must not advance the live generation")

	AssertTrue(KL_Roi_TryPublishPrunedCounts(State, 10, Stale),
		"the current generation must publish its precomputed survivor map")
	AssertTrue(State.word_counts.Has("stale") && !State.word_counts.Has("live"),
		"a current prune must atomically swap the complete survivor map")
	AssertEqual(11, State.word_counts_generation,
		"a successful publication must advance the generation")
}
Test("keylogger ROI: stale prune publication is rejected (roi-prune-bounded)",
	_ROIP_StaleSnapshotCannotPublish)

_ROIP_TransactionPublishesBoundedSurvivors() {
	State := {word_counts: _ROIP_AdversarialCounts(), word_counts_generation: 20}
	Generation := 0
	Snapshot := KL_Roi_SnapshotWordCounts(State, &Generation)
	Operations := 0
	Survivors := KL_Roi_SelectWordCountSurvivors(Snapshot, 250, &Operations)

	AssertTrue(KL_Roi_TryPublishPrunedCounts(State, Generation, Survivors),
		"the prune transaction must publish when its snapshot is current")
	AssertEqual(250, State.word_counts.Count,
		"the transaction must publish exactly the requested number of survivors")
	AssertEqual(21, State.word_counts_generation,
		"the prune transaction must advance its publication generation once")
}
Test("keylogger ROI: prune transaction swaps bounded survivors (roi-prune-bounded)",
	_ROIP_TransactionPublishesBoundedSurvivors)
