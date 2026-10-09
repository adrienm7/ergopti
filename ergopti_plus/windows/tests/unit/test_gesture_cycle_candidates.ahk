; tests/unit/test_gesture_cycle_candidates.ahk

; ==============================================================================
; MODULE: Gesture Cycle Candidate Tests
; DESCRIPTION:
; Pins the exact candidate budget when the focused window is inside or outside
; the filtered cycle list.
; ==============================================================================

_GCC_AssertIndexes(Expected, Actual, Message) {
	AssertEqual(Expected.Length, Actual.Length, Message . " length")
	for Index, Value in Expected
		AssertEqual(Value, Actual[Index], Message . " index " . Index)
}

_GCC_ExcludedActiveWindowVisitsEveryCandidate() {
	_GCC_AssertIndexes([1],
		GestureCycleCandidateIndexes(0, 1, true),
		"one eligible window must remain reachable from an excluded foreground")
	_GCC_AssertIndexes([1, 2, 3],
		GestureCycleCandidateIndexes(0, 3, true),
		"forward cycling must try every eligible window when focus is excluded")
	_GCC_AssertIndexes([3, 2, 1],
		GestureCycleCandidateIndexes(0, 3, false),
		"backward cycling must try every eligible window when focus is excluded")
}
Test("gesture cycle: an excluded foreground visits every eligible window "
	. "(gesture-cycle-excluded-active)",
	_GCC_ExcludedActiveWindowVisitsEveryCandidate)

_GCC_EligibleActiveWindowIsNeverRetried() {
	_GCC_AssertIndexes([3, 1],
		GestureCycleCandidateIndexes(2, 3, true),
		"forward cycling must skip the active member")
	_GCC_AssertIndexes([1, 3],
		GestureCycleCandidateIndexes(2, 3, false),
		"backward cycling must skip the active member")
	_GCC_AssertIndexes([], GestureCycleCandidateIndexes(1, 1, true),
		"a sole active member leaves no target")
	_GCC_AssertIndexes([], GestureCycleCandidateIndexes(0, 0, true),
		"an empty cycle list leaves no target")
}
Test("gesture cycle: an eligible foreground is excluded from candidate order "
	. "(gesture-cycle-excluded-active)",
	_GCC_EligibleActiveWindowIsNeverRetried)
