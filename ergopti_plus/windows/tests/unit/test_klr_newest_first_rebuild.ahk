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
_KLRNF_Build(Segmented, Observer := 0, StopAfterRounds := 0) {
	Saved := [KLRRebuild.min_ledger_bytes, KLRRebuild.chunk_bytes,
		KLRRebuild.round_interval_ms, KLRRebuild.observer,
		KLRRebuild.checkpoint_interval_ms, KLRRebuild.stop_after_rounds]
	try {
		KLRRebuild.min_ledger_bytes := Segmented ? 0 : 0x7FFFFFFF
		; One fixture batch per read, a rollup round and a checkpoint after each.
		KLRRebuild.chunk_bytes := 700
		KLRRebuild.round_interval_ms := 0
		KLRRebuild.checkpoint_interval_ms := 0
		KLRRebuild.stop_after_rounds := StopAfterRounds
		KLRRebuild.observer := Observer
		try FileDelete(KLR_CachePath(_KLRDC_Root()))
		if !StopAfterRounds
			return _KLRDC_BuildAsWorker()
		KLR_ResetCache()
		KLRCache.disposable := true
		return KLR_BuildDatabase(_KLRDC_Root())
	} finally {
		KLRRebuild.min_ledger_bytes := Saved[1]
		KLRRebuild.chunk_bytes := Saved[2]
		KLRRebuild.round_interval_ms := Saved[3]
		KLRRebuild.observer := Saved[4]
		KLRRebuild.checkpoint_interval_ms := Saved[5]
		KLRRebuild.stop_after_rounds := Saved[6]
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
			if !Info.Has("db")
				return
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

; A driver reload kills the worker mid-rebuild. The next worker must continue
; from the last checkpoint instead of starting over, and still end exact.
_KLRNF_KilledWorkerResumes() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger())
		Reference := _KLRDC_DerivedFingerprint(_KLRNF_Build(false))
		Checkpoint := KLR_RebuildCheckpointPath(_KLRDC_Root())
		AssertEqual(0, _KLRNF_Build(true, 0, 3), "the interrupted worker must not publish anything")
		AssertTrue(FSExists(Checkpoint), "an interrupted rebuild must leave its checkpoint (klr-rebuild-resume)")
		AssertFalse(FSExists(KLR_CachePath(_KLRDC_Root())), "an interrupted rebuild must not publish an image")

		First := 0
		Observe(Info) {
			if !IsObject(First) && Info.Has("done_bytes")
				First := Info.Clone()
		}
		Resumed := _KLRNF_Build(true, Observe)
		AssertTrue(IsObject(First))
		AssertTrue(First["done_bytes"] > First["run_bytes"],
			"the next worker must continue from the checkpoint, not from zero (klr-rebuild-resume)")
		AssertEqual(Reference, _KLRDC_DerivedFingerprint(Resumed),
			"a resumed rebuild must end exactly where an uninterrupted one ends (klr-rebuild-resume)")
		AssertFalse(FSExists(Checkpoint), "a published image supersedes its checkpoint")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR rebuild: a killed worker resumes from its checkpoint (klr-rebuild-resume)",
	_KLRDC_CheckTeardown.Bind(_KLRNF_KilledWorkerResumes))

; A checkpoint only describes the exact ledger bytes it consumed.
_KLRNF_ReplacedLedgerDiscardsCheckpoint() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger())
		AssertEqual(0, _KLRNF_Build(true, 0, 3))
		AssertTrue(FSExists(KLR_RebuildCheckpointPath(_KLRDC_Root())))
		; A compaction replaces the file: its identity changes.
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-03-05 09:00:00.000", "2026-03-05", "five.exe", ["q"]))
		First := 0
		Observe(Info) {
			if !IsObject(First) && Info.Has("done_bytes")
				First := Info.Clone()
		}
		Db := _KLRNF_Build(true, Observe)
		AssertEqual(First["done_bytes"], First["run_bytes"], "a stale checkpoint must not be resumed")
		AssertEqual("2026-03-05", _KLRNF_Days(Db),
			"no day from the replaced ledger may survive in the rebuilt image (klr-rebuild-resume)")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR rebuild: a replaced ledger discards the checkpoint (klr-rebuild-resume)",
	_KLRDC_CheckTeardown.Bind(_KLRNF_ReplacedLedgerDiscardsCheckpoint))
; A scriptable clock advances at the second decision, or at the first completed
; round's observer, while all reads, transactions and rollups remain real SQLite.
class _KLRNFClock {
	__New(Base, Delta, AdvanceAt) {
		this.OriginTick := Base
		this.Delta := Delta
		this.AdvanceAt := AdvanceAt
		this.Calls := 0
	}
	Call() {
		this.Calls += 1
		return this.Calls < this.AdvanceAt ? this.OriginTick : (this.OriginTick + this.Delta)
	}
}

_KLRNF_ClockScenario(Kind, Base, Delta) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := [KLRRebuild.min_ledger_bytes, KLRRebuild.chunk_bytes,
		KLRRebuild.round_interval_ms, KLRRebuild.checkpoint_interval_ms,
		KLRRebuild.stop_after_rounds, KLRRebuild.observer, KLRRebuild.now_fn]
	Candidate := 0
	try {
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger())
		ReferenceDb := _KLRNF_Build(false)
		Reference := _KLRDC_DerivedFingerprint(ReferenceDb)
		CachePath := KLR_CachePath(_KLRDC_Root())
		CacheBytes := FileRead(CachePath, "RAW")
		Progress := []
		FailObserver := Kind == "error"
		Observe(Info) {
			Progress.Push(Info.Clone())
			if FailObserver
				throw Error("Owned rebuild observer failure.")
		}
		KLRRebuild.min_ledger_bytes := 0
		KLRRebuild.chunk_bytes := 700
		KLRRebuild.round_interval_ms := KLRRebuildConst.ROUND_INTERVAL_MS
		KLRRebuild.checkpoint_interval_ms := KLRRebuildConst.CHECKPOINT_INTERVAL_MS
		KLRRebuild.stop_after_rounds := Kind == "checkpoint" ? 1 : 0
		KLRRebuild.observer := Observe
		Clock := _KLRNFClock(Base, Delta, Kind == "round" ? 7 : 4)
		KLRRebuild.now_fn := Clock
		Built := KLR_BuildColdSegmented(_KLRDC_Root(), "", [_KLRDC_LedgerPath()])
		Candidate := Built["db"]
		AssertTrue(Clock.Calls >= (Kind == "round" ? 7 : Kind == "error" ? 4 : 6), "the actual owner must consume the controlled decision clock")
		AssertTrue(Progress.Length > 0)
		AssertEqual(1, Progress[1]["round"], "first round is unconditional")
		AssertFalse(Progress[1]["final"], "first round cannot claim final completion")
		Checkpoint := KLR_RebuildCheckpointPath(_KLRDC_Root())
		if Kind == "round" {
			AssertTrue(Built["ok"])
			AssertTrue(Progress.Length >= 3, "the fixture must exercise another step and final round")
			Due := Delta >= KLRRebuildConst.ROUND_INTERVAL_MS
			AssertEqual(Due, Progress[2].Has("db"), "only an eligible second round publishes its private database")
			AssertEqual(Due ? 2 : 1, Progress[2]["round"], "before/equal/after threshold retains the >= policy")
			AssertEqual(Delta, Progress[2]["elapsed_ms"], "actual observer retains the complete native monotonic duration")
			Last := Progress[Progress.Length]
			AssertTrue(Last["final"] && Last["done_bytes"] == Last["total_bytes"])
			AssertEqual(Reference, _KLRDC_DerivedFingerprint(Candidate), "scheduled rounds still end at the reference fingerprint")
			AssertEqual(Delta >= KLRRebuildConst.CHECKPOINT_INTERVAL_MS, FSExists(Checkpoint),
				"only a completed round with a due checkpoint interval can publish its checkpoint")
		} else if Kind == "error" {
			AssertFalse(Built["ok"], "an observer exception cannot certify a completed build")
			AssertEqual(0, Candidate, "the failed owner releases its private database")
			AssertEqual(1, Progress.Length, "a failed round cannot publish final completion")
			AssertFalse(FSExists(Checkpoint), "a failed round cannot authorize a new checkpoint")
			FailObserver := false
			KLRRebuild.now_fn := 0
			Progress := []
			Recovered := KLR_BuildColdSegmented(_KLRDC_Root(), "", [_KLRDC_LedgerPath()])
			Candidate := Recovered["db"]
			AssertTrue(Recovered["ok"], "failure must release the exclusive guard for the next owner")
			AssertTrue(Progress[Progress.Length]["final"])
			AssertEqual(Reference, _KLRDC_DerivedFingerprint(Candidate), "recovery retains the reference SQLite fingerprint")
		} else {
			AssertFalse(Built["ok"], "the owned stop seam cannot turn interruption into success")
			AssertEqual(0, Candidate)
			AssertEqual(1, Progress.Length, "interruption after the first round publishes no final observation")
			Due := Delta >= KLRRebuildConst.CHECKPOINT_INTERVAL_MS
			AssertEqual(Due, FSExists(Checkpoint), "checkpoint requires its exact elapsed threshold after a completed round")
			AssertEqual(Delta, Progress[1]["elapsed_ms"], "completed-round progress reports the actual nonnegative elapsed time")
			if Due {
				Stored := SQLite_Open(Checkpoint, SQLiteConst.OPEN_RO)
				AssertTrue(Stored != 0)
				try {
					AssertTrue(SQLite_Query(Stored, "SELECT COUNT(*) AS n FROM klr_rebuild_ledger;")[1]["n"] == 1,
						"the real checkpoint stores the consumed ledger's resume authority")
				} finally SQLite_Close(Stored)
				KLRRebuild.now_fn := 0
				KLRRebuild.stop_after_rounds := 0
				KLRRebuild.round_interval_ms := 0
				Progress := []
				Resumed := KLR_BuildColdSegmented(_KLRDC_Root(), "", [_KLRDC_LedgerPath()])
				Candidate := Resumed["db"]
				AssertTrue(Resumed["ok"])
				AssertTrue(Progress[1]["done_bytes"] > Progress[1]["run_bytes"], "resume must actually adopt the checkpoint")
				AssertEqual(Reference, _KLRDC_DerivedFingerprint(Candidate), "an interrupted native-clock rebuild resumes to the exact SQLite fingerprint")
			}
		}
		AssertEqual(ReferenceDb, KLRCache.db, "private candidates cannot replace the last-good resident handle")
		CurrentCache := FileRead(CachePath, "RAW")
		AssertEqual(CacheBytes.Size, CurrentCache.Size)
		AssertEqual(CacheBytes.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", CacheBytes, "Ptr", CurrentCache,
			"UPtr", CacheBytes.Size, "UPtr"), "the last-good published image remains byte-exact")
		AssertEqual(Reference, _KLRDC_DerivedFingerprint(ReferenceDb), "failure or completion cannot mutate the prior live database")
	} finally {
		if Candidate
			SQLite_Close(Candidate)
		KLRRebuild.min_ledger_bytes := Saved[1]
		KLRRebuild.chunk_bytes := Saved[2]
		KLRRebuild.round_interval_ms := Saved[3]
		KLRRebuild.checkpoint_interval_ms := Saved[4]
		KLRRebuild.stop_after_rounds := Saved[5]
		KLRRebuild.observer := Saved[6]
		KLRRebuild.now_fn := Saved[7]
		_KLRDC_Cleanup()
	}
}

for _KLRNFClockKind in ["round", "checkpoint"] {
	_KLRNFClockThreshold := _KLRNFClockKind == "round"
		? KLRRebuildConst.ROUND_INTERVAL_MS : KLRRebuildConst.CHECKPOINT_INTERVAL_MS
	for _KLRNFClockBase in [100000, 0xFFFFFFF0] {
		for _KLRNFClockDelta in [_KLRNFClockThreshold - 1, _KLRNFClockThreshold, _KLRNFClockThreshold + 1] {
			Test("KLR rebuild: " . _KLRNFClockKind . " interval " . _KLRNFClockDelta . " from " . _KLRNFClockBase . " (klr-segmented-clock)",
				_KLRDC_CheckTeardown.Bind(_KLRNF_ClockScenario.Bind(_KLRNFClockKind, _KLRNFClockBase, _KLRNFClockDelta)))
		}
	}
}

for _KLRNFClockErrorBase in [100000, 0xFFFFFFF0]
	Test("KLR rebuild: observer failure releases ownership from " . _KLRNFClockErrorBase . " (klr-segmented-clock)",
		_KLRDC_CheckTeardown.Bind(_KLRNF_ClockScenario.Bind("error", _KLRNFClockErrorBase, KLRRebuildConst.CHECKPOINT_INTERVAL_MS)))

; Complete native monotonic spans remain due and visible to the real observer.
for _KLRNF64Kind in ["round", "checkpoint"] {
	_KLRNF64Threshold := _KLRNF64Kind == "round"
		? KLRRebuildConst.ROUND_INTERVAL_MS : KLRRebuildConst.CHECKPOINT_INTERVAL_MS
	for _KLRNF64Offset in [-1, 0, 1]
		Test("KLR rebuild native64: " . _KLRNF64Kind . " long gap offset " . _KLRNF64Offset . " (klr-segmented-native64)",
			_KLRDC_CheckTeardown.Bind(_KLRNF_ClockScenario.Bind(_KLRNF64Kind,
				0x100000000 + 100000, 0x100000000 + _KLRNF64Threshold + _KLRNF64Offset)))
}
