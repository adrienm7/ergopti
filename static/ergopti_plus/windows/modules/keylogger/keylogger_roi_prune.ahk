; modules/keylogger/keylogger_roi_prune.ahk

; ==============================================================================
; MODULE: Keylogger ROI Prune Transactions
; DESCRIPTION:
; Pure, headless-safe helpers for candidate-frequency pruning. A short Critical
; transaction owns each live-map mutation/snapshot/publication; bounded native
; frequency selection runs on the snapshot outside Critical and is fenced on
; publish. This keeps the keystroke thread interruptible while preserving the
; historical frequency and insertion-order survivor policy. (AHK-11.)
; ==============================================================================

#Requires AutoHotkey v2.0+

; Atomically increment one candidate and advance the generation observed by a
; concurrent prune. Returns the live map size after the mutation.
KL_Roi_IncrementWordCount(State, Key, &CountAfter) {
	previous_critical := Critical("On")
	try {
		CountAfter := State.word_counts.Has(Key) ? State.word_counts[Key] : 0
		CountAfter += 1
		State.word_counts[Key] := CountAfter
		State.word_counts_generation += 1
		return State.word_counts.Count
	} finally {
		Critical(previous_critical)
	}
}

; Clone the live map under a short transaction and return the generation that
; owns the snapshot. All survivor computation happens after this helper returns.
KL_Roi_SnapshotWordCounts(State, &Generation) {
	previous_critical := Critical("On")
	try {
		Generation := State.word_counts_generation
		return State.word_counts.Clone()
	} finally {
		Critical(previous_critical)
	}
}

; Publish a complete precomputed map only if no word arrived after the snapshot.
; Assignment is O(1); the old map becomes unreachable after the atomic swap.
KL_Roi_TryPublishPrunedCounts(State, ExpectedGeneration, NextCounts) {
	previous_critical := Critical("On")
	try {
		if (State.word_counts_generation != ExpectedGeneration)
			return false
		State.word_counts := NextCounts
		State.word_counts_generation += 1
		return true
	} finally {
		Critical(previous_critical)
	}
}

; Select the best ``Target`` entries by frequency, then rebuild the Map in
; original insertion order. AHK-level work is three bounded passes; only the
; distinct numeric frequency list is sorted, by AHK's native Sort rather than an
; interpreted insertion loop. ``OperationCount`` counts every interpreted entry
; visit so the regression test can reject session-size-squared work without a
; scheduler-dependent stopwatch.
KL_Roi_SelectWordCountSurvivors(Source, Target, &OperationCount) {
	OperationCount := 0
	NextCounts := Map()
	if (Target <= 0)
		return NextCounts

	FrequencyBuckets := Map()
	FrequencyText := ""
	Eligible := 0
	for Key, Frequency in Source {
		OperationCount += 1
		; Preserve the original first pass exactly: count-one noise never enters
		; the frequency selection, even when fewer than Target entries remain.
		if (Frequency = 1)
			continue
		Eligible += 1
		if !FrequencyBuckets.Has(Frequency) {
			FrequencyBuckets[Frequency] := 0
			FrequencyText .= Frequency . "`n"
		}
		FrequencyBuckets[Frequency] += 1
	}

	if (Eligible <= Target) {
		for Key, Frequency in Source {
			OperationCount += 1
			if (Frequency != 1)
				NextCounts[Key] := Frequency
		}
		return NextCounts
	}

	Remaining := Target
	CutoffFrequency := 0
	KeepAtCutoff := 0
	SortedFrequencies := Sort(RTrim(FrequencyText, "`n"), "N R")
	loop parse, SortedFrequencies, "`n", "`r" {
		OperationCount += 1
		Frequency := Number(A_LoopField)
		BucketSize := FrequencyBuckets[Frequency]
		if (BucketSize <= Remaining) {
			Remaining -= BucketSize
			continue
		}
		CutoffFrequency := Frequency
		KeepAtCutoff := Remaining
		break
	}

	CutoffTotal := FrequencyBuckets[CutoffFrequency]
	CutoffSeen := 0
	for Key, Frequency in Source {
		OperationCount += 1
		if (Frequency > CutoffFrequency) {
			NextCounts[Key] := Frequency
			continue
		}
		if (Frequency = CutoffFrequency) {
			CutoffSeen += 1
			; Match the former stable ascending sort: earliest ties are evicted,
			; so only the last KeepAtCutoff entries survive at the boundary.
			if (CutoffSeen > CutoffTotal - KeepAtCutoff)
				NextCounts[Key] := Frequency
		}
	}
	return NextCounts
}
