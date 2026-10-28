; tests/unit/modules/keystats/reader/test_klr_executed_rounds.ahk

; ==============================================================================
; MODULE: Executed Reader Round Tests
; DESCRIPTION: Carried source bytes cannot authorize a partial image or checkpoint.
; ==============================================================================

#Requires AutoHotkey v2.0

; The last LF-aligned frame of the existing clock fixture has no batch header.
; Reading it moves the scan cursor but cannot consume any SQL transaction.
_KLRER_CarriedStepReceipt() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := [KLRRebuild.chunk_bytes, KLRRebuild.now_fn, KLRRebuild.observer]
	Db := 0
	try {
		Source := _KLRNF_ThreeDayLedger()
		_KLRDC_WriteLedger(Source)
		Db := KLR_OpenCandidate()
		AssertTrue(Db != 0)
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(KLR_EnsureTypingProjectionTable(Db) && _KLR_RebuildInstallFirstWins(Db))
		Clock := _KLRNFClock(100000, 60000, 100)
		KLRRebuild.now_fn := Clock
		KLRRebuild.observer := 0
		KLRRebuild.chunk_bytes := 700
		State := _KLR_RebuildNewState(Db, [_KLRDC_LedgerPath()])
		Ledger := State["ledgers"][1]
		Calls := Clock.Calls
		AssertFalse(_KLR_RebuildStep(State, Ledger), "carried bytes are not an executed-step receipt")
		Last := Ledger["frames"][Ledger["frames"].Length]
		AssertEqual(-1, Last[3], "the real fixture must enter the headerless final frame")
		AssertTrue(Ledger["cursor"] < Ledger["end"] && Ledger["carry"] != "")
		AssertEqual(Ledger["end"], Ledger["cursor"] + StrPut(Ledger["carry"], "UTF-8") - 1,
			"a checkpoint here would resume at EOF without consuming a transaction")
		AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		AssertEqual(0, State["rounds"], "a source read alone cannot authorize a round")
		AssertTrue(_KLR_RebuildStep(State, Ledger), "the next real transaction must issue an execution receipt")
		AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		AssertEqual(Calls, Clock.Calls, "indexing and replay steps never sample the scheduling clock")
	} finally {
		if Db
			SQLite_Close(Db)
		KLRRebuild.chunk_bytes := Saved[1]
		KLRRebuild.now_fn := Saved[2]
		KLRRebuild.observer := Saved[3]
		_KLRDC_Cleanup()
	}
}
Test("KLR rebuild: carried bytes cannot issue an execution receipt (klr-executed-round-ownership)",
	_KLRDC_CheckTeardown.Bind(_KLRER_CarriedStepReceipt))

; Exercise the real scheduling owner, backup and adoption. The first published
; round must contain the newest transaction, even when its first read did not.
_KLRER_FirstCheckpointConsumesBatch() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := [KLRRebuild.chunk_bytes, KLRRebuild.round_interval_ms,
		KLRRebuild.checkpoint_interval_ms, KLRRebuild.stop_after_rounds, KLRRebuild.observer]
	Candidate := 0
	try {
		Source := _KLRNF_ThreeDayLedger()
		_KLRDC_WriteLedger(Source)
		Reference := _KLRDC_DerivedFingerprint(_KLRNF_Build(false))
		Progress := []
		Observe(Info) {
			Progress.Push(Info.Clone())
			if Info.Has("db") && !Info["final"]
				AssertTrue(SQLite_Query(Info["db"], "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"] > 0,
					"a partial round cannot expose an image before any transaction executed")
		}
		KLRRebuild.chunk_bytes := 700
		KLRRebuild.round_interval_ms := 0
		KLRRebuild.checkpoint_interval_ms := 0
		KLRRebuild.stop_after_rounds := 1
		KLRRebuild.observer := Observe
		Built := KLR_BuildColdSegmented(_KLRDC_Root(), "", [_KLRDC_LedgerPath()])
		AssertFalse(Built["ok"], "the first completed round still honors the owned interruption")
		AssertEqual(1, Progress.Length, "carried frames cannot publish an earlier empty observation")
		Checkpoint := KLR_RebuildCheckpointPath(_KLRDC_Root())
		Stored := SQLite_Open(Checkpoint, SQLiteConst.OPEN_RO)
		AssertTrue(Stored != 0, "the first meaningful round must leave a real checkpoint")
		try {
			Row := SQLite_Query(Stored, "SELECT end_offset, resume_offset FROM klr_rebuild_ledger;")[1]
			Marker := InStr(Source, KLRRebuildConst.BATCH_MARKER, true, -1)
			ExpectedResume := StrPut(SubStr(Source, 1, Marker), "UTF-8") - 1
			AssertEqual(ExpectedResume, Row["resume_offset"], "resume must point before the newest executed batch")
			AssertTrue(Row["resume_offset"] < Row["end_offset"], "the checkpoint must retain real consumed progress")
			AssertEqual(1, SQLite_Query(Stored, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		} finally SQLite_Close(Stored)
		KLRRebuild.stop_after_rounds := 0
		Progress := []
		Resumed := KLR_BuildColdSegmented(_KLRDC_Root(), "", [_KLRDC_LedgerPath()])
		Candidate := Resumed["db"]
		AssertTrue(Resumed["ok"])
		AssertTrue(Progress[1]["done_bytes"] > Progress[1]["run_bytes"], "the real owner must adopt nonzero checkpoint progress")
		AssertEqual(Reference, _KLRDC_DerivedFingerprint(Candidate), "resumed replay must remain equal to the one-pass oracle")
	} finally {
		if Candidate
			SQLite_Close(Candidate)
		KLRRebuild.chunk_bytes := Saved[1]
		KLRRebuild.round_interval_ms := Saved[2]
		KLRRebuild.checkpoint_interval_ms := Saved[3]
		KLRRebuild.stop_after_rounds := Saved[4]
		KLRRebuild.observer := Saved[5]
		_KLRDC_Cleanup()
	}
}
Test("KLR rebuild: first checkpoint owns an executed batch and resumes it (klr-executed-round-ownership)",
	_KLRDC_CheckTeardown.Bind(_KLRER_FirstCheckpointConsumesBatch))

; An empty or wholly torn ledger has no execution receipt. Its unconditional
; final round must still publish a valid empty candidate, never a partial image.
_KLRER_EmptyFinalRound(Shape) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := [KLRRebuild.chunk_bytes, KLRRebuild.round_interval_ms,
		KLRRebuild.checkpoint_interval_ms, KLRRebuild.stop_after_rounds, KLRRebuild.observer]
	Candidate := 0
	try {
		Source := Shape == "empty" ? "" : _KLRDC_Header()
		if Shape == "torn" {
			Batch := _KLRDC_TypingBatch(1, "2026-03-04 10:00:00.000", "2026-03-04", "fixture.exe", ["x"])
			Source .= SubStr(Batch, 1, InStr(Batch, "COMMIT;") - 1)
		}
		_KLRDC_WriteLedger(Source)
		Progress := []
		Observe(Info) {
			Progress.Push(Info.Clone())
		}
		KLRRebuild.chunk_bytes := 700
		KLRRebuild.round_interval_ms := 0
		KLRRebuild.checkpoint_interval_ms := 0
		KLRRebuild.stop_after_rounds := 1
		KLRRebuild.observer := Observe
		Built := KLR_BuildColdSegmented(_KLRDC_Root(), "", [_KLRDC_LedgerPath()])
		Candidate := Built["db"]
		AssertTrue(Built["ok"], "a final empty result must not become an interrupted partial round")
		AssertEqual(1, Progress.Length)
		AssertTrue(Progress[1]["final"] && Progress[1].Has("db"))
		AssertEqual(0, SQLite_Query(Candidate, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		AssertFalse(FSExists(KLR_RebuildCheckpointPath(_KLRDC_Root())), "no unexecuted data can authorize a checkpoint")
	} finally {
		if Candidate
			SQLite_Close(Candidate)
		KLRRebuild.chunk_bytes := Saved[1]
		KLRRebuild.round_interval_ms := Saved[2]
		KLRRebuild.checkpoint_interval_ms := Saved[3]
		KLRRebuild.stop_after_rounds := Saved[4]
		KLRRebuild.observer := Saved[5]
		_KLRDC_Cleanup()
	}
}
for _KLREREmptyShape in ["empty", "header", "torn"]
	Test("KLR rebuild: " . _KLREREmptyShape . " history publishes only its final round (klr-executed-round-ownership)",
		_KLRDC_CheckTeardown.Bind(_KLRER_EmptyFinalRound.Bind(_KLREREmptyShape)))
