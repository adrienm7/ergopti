; tests/unit/test_klr_newest_first_rebuild.ahk

; ==============================================================================
; MODULE: Newest-first Reader Rebuild Tests
; DESCRIPTION: A large cold rebuild shows recent days first and ends exact.
; ==============================================================================

#Requires AutoHotkey v2.0

; Three days, each typed in its own application so the one-pass reference and
; the newest-first rounds cannot differ over a cross-day n-gram chain.
_KLRNF_ThreeDayLedger() {
	return _KLRDC_Header()
		. _KLRDC_TypingBatch(1, "2026-03-01 09:00:00.000", "2026-03-01", "one.exe", ["a", "b", "c"])
		. _KLRDC_TypingBatch(2, "2026-03-01 09:00:05.000", "2026-03-01", "one.exe", ["d", "e"])
		. _KLRDC_TypingBatch(3, "2026-03-02 10:00:00.000", "2026-03-02", "two.exe", ["f", "g", "h"])
		. _KLRDC_TypingBatch(4, "2026-03-02 10:00:05.000", "2026-03-02", "two.exe", ["i"])
		. _KLRDC_TypingBatch(5, "2026-03-03 11:00:00.000", "2026-03-03", "three.exe", ["j", "k"])
		. _KLRDC_TypingBatch(6, "2026-03-03 11:00:05.000", "2026-03-03", "three.exe", ["l", "m", "n"])
}

; Run one worker build with the given rebuild seams, restoring them after.
_KLRNF_Build(Segmented, Observer := 0) {
	Saved := [KLRRebuild.min_ledger_bytes, KLRRebuild.chunk_bytes,
		KLRRebuild.round_interval_ms, KLRRebuild.observer]
	try {
		KLRRebuild.min_ledger_bytes := Segmented ? 0 : 0x7FFFFFFF
		; One fixture batch per read, and a rollup round after every read.
		KLRRebuild.chunk_bytes := 700
		KLRRebuild.round_interval_ms := 0
		KLRRebuild.observer := Observer
		try FileDelete(KLR_CachePath(_KLRDC_Root()))
		return _KLRDC_BuildAsWorker()
	} finally {
		KLRRebuild.min_ledger_bytes := Saved[1]
		KLRRebuild.chunk_bytes := Saved[2]
		KLRRebuild.round_interval_ms := Saved[3]
		KLRRebuild.observer := Saved[4]
	}
}

_KLRNF_Days(Db) {
	Days := ""
	for Row in SQLite_Query(Db, "SELECT DISTINCT date FROM agg_app_day ORDER BY date;")
		Days .= (Days = "" ? "" : ",") . Row["date"]
	return Days
}

_KLRNF_NewestDayComesFirst() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger())
		Reference := _KLRDC_DerivedFingerprint(_KLRNF_Build(false))

		Rounds := []
		Observe(Info) {
			Rounds.Push(Map("days", _KLRNF_Days(Info["db"]), "oldest", Info["oldest_complete"],
				"done", Info["done_bytes"], "total", Info["total_bytes"], "final", Info["final"]))
		}
		Rebuilt := _KLRDC_DerivedFingerprint(_KLRNF_Build(true, Observe))

		FirstVisible := 0
		for Round in Rounds
			if Round["days"] != "" {
				FirstVisible := Round
				break
			}
		AssertTrue(IsObject(FirstVisible), "a newest-first rebuild must publish rolled-up days before it ends")
		AssertFalse(FirstVisible["final"], "the first visible statistics must precede the end of the rebuild")
		AssertEqual("2026-03-03", FirstVisible["days"],
			"the first visible statistics must be the newest complete day only (klr-newest-first-rebuild)")
		AssertEqual("2026-03-03", FirstVisible["oldest"], "the observer must name how far back the data is rebuilt")
		AssertTrue(FirstVisible["done"] < FirstVisible["total"], "progress must report unfinished work")
		Last := Rounds[Rounds.Length]
		AssertTrue(Last["final"] && Last["done"] = Last["total"], "the final round must report completion")
		AssertEqual("2026-03-01", Last["oldest"])
		AssertTrue(Reference != "", "the reference fingerprint must read rows")
		AssertEqual(Reference, Rebuilt,
			"the newest-first rebuild must end exactly where the one-pass rebuild ends (klr-newest-first-rebuild)")
		AssertTrue(FSExists(KLR_CachePath(_KLRDC_Root())), "the finished rebuild must publish its image")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR rebuild: newest day is rolled up first and the end is exact (klr-newest-first-rebuild)",
	_KLRDC_CheckTeardown.Bind(_KLRNF_NewestDayComesFirst))

; Reading backward must not change which copy of a reused event key survives:
; the one-pass build keeps the first copy in file order.
_KLRNF_FirstCopyWins() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger()
			. _KLRDC_TypingBatch(3, "2026-03-04 12:00:00.000", "2026-03-04", "four.exe", ["x", "y", "z", "w"]))
		Reference := _KLRDC_DerivedFingerprint(_KLRNF_Build(false))
		Db := _KLRNF_Build(true)
		AssertEqual(Reference, _KLRDC_DerivedFingerprint(Db),
			"a reused key must keep its first copy when read backward (klr-newest-first-collision)")
		AssertEqual("2026-03-01,2026-03-02,2026-03-03", _KLRNF_Days(Db),
			"the displaced newer copy must leave no rollup behind")
		AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM temp.sqlite_schema WHERE type='trigger';")[1]["n"],
			"the temporary first-wins triggers must not survive into the published image")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR rebuild: a reused event key keeps its first copy (klr-newest-first-collision)",
	_KLRDC_CheckTeardown.Bind(_KLRNF_FirstCopyWins))

; A writer caught mid-append must not fail the rebuild: the torn batch is left
; to the next incremental refresh from the recorded offset.
_KLRNF_TornTailIsLeftForLater() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Torn := _KLRDC_TypingBatch(7, "2026-03-03 11:00:09.000", "2026-03-03", "three.exe", ["o", "p"])
		Torn := SubStr(Torn, 1, InStr(Torn, "COMMIT;") - 1)
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger() . Torn)
		Db := _KLRNF_Build(true)
		AssertEqual(5, SQLite_Query(Db, "SELECT chars FROM agg_app_day WHERE date='2026-03-03';")[1]["chars"],
			"only complete batches may be rolled up")
		AssertEqual(StrPut(_KLRNF_ThreeDayLedger(), "UTF-8") - 1, KLRCache.last_sizes[_KLRDC_LedgerPath()],
			"the consumed offset must stop after the last complete batch")
		_KLRDC_AppendLedger("COMMIT;`n")
		Warm := _KLRDC_BuildAsWorker()
		AssertEqual(7, SQLite_Query(Warm, "SELECT chars FROM agg_app_day WHERE date='2026-03-03';")[1]["chars"],
			"the next refresh must apply the batch once its transaction closes")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR rebuild: a torn tail is left to the next refresh (klr-newest-first-torn-tail)",
	_KLRDC_CheckTeardown.Bind(_KLRNF_TornTailIsLeftForLater))
