; tests/unit/test_klr_candidate_live_retry.ahk

; ==============================================================================
; MODULE: Reader Candidate Live Retry Tests
; DESCRIPTION: Reject a private SQL refresh without consuming its live walker batch.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCLR_RejectedDrain() {
	SavedBatch := KLW.batch
	SavedDevice := Keylogger._device_id_lit
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	KLW_ResetBatch()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(9,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a", "b"]))
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0)
		AssertFalse(KLRCache.disposable)
		Keylogger._device_id_lit := "'dev-one'"
		KLW.batch["app_day"]["pending"] := Map("date", "2026-01-01", "app", "fixture.exe", "time_ms", 7)
		KLW.batch["system_day"]["pending"] := Map("date", "2026-01-01",
			"space_switches", 1, "audio_muted_ms", 0, "passive_count", 0, "night_wake_count", 0)
		Pending := KLW.batch
		Before := _KLRDC_DerivedFingerprint(Db)
		Path := _KLRDC_LedgerPath()
		Offset := KLRCache.last_sizes[Path]
		Snapshot := KLRCache.ledger_snapshots[Path].Clone()
		; SQL rollups do not insert this synthetic system row. The trigger is
		; copied with the private candidate and rejects the later live drain.
		AssertTrue(SQLite_Exec(Db, "CREATE TRIGGER reject_live_candidate BEFORE INSERT ON agg_system_day "
			. "WHEN NEW.space_switches=1 BEGIN SELECT RAISE(ABORT,'fixture live refusal'); END;"))
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(3,
			"2026-01-01 10:00:01.000", "2026-01-01", "fixture.exe", ["c", "d"]))
		SourceSnapshot := KLR_LedgerSnapshot(Path)
		loop 2 {
			Failure := 0
			try KLR_BuildDatabase(_KLRDC_Root())
			catch Error as Caught
				Failure := Caught
			AssertTrue(Failure is Error, "a rejected live drain must abort candidate publication")
			AssertContains(Failure.Message, "Live walker drain write failed")
			AssertEqual(Db, KLRCache.db, "the old resident handle must remain published")
			AssertTrue(SQLite_IsAutocommit(Db))
			AssertEqual(Before, _KLRDC_DerivedFingerprint(Db), "neither SQL rollups nor earlier live writes may escape")
			AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
			AssertEqual(Offset, KLRCache.last_sizes[Path])
			AssertTrue(KLR_LedgerSnapshotIsSame(Snapshot, KLRCache.ledger_snapshots[Path]))
			AssertTrue(KLW.batch == Pending, "candidate rejection must preserve the exact pending accumulator")
			AssertEqual(7, Pending["app_day"]["pending"]["time_ms"])
			AssertEqual(1, Pending["system_day"]["pending"]["space_switches"])
		}
		AssertTrue(SQLite_Exec(Db, "DROP TRIGGER reject_live_candidate;"))
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0)
		AssertTrue(KLR_LedgerSnapshotIsSame(SourceSnapshot, KLR_LedgerSnapshot(Path)), "retry must use identical source bytes")
		AssertEqual(SourceSnapshot["size"], KLRCache.last_sizes[Path])
		AssertEqual(2, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		Row := SQLite_Query(Db, "SELECT chars,time_ms FROM agg_app_day;")[1]
		AssertEqual(4, Row["chars"], "the lower-ID raw tail must advance the SQL-owned counts")
		AssertEqual(247, Row["time_ms"], "the live contribution must apply once after the historical 240 ms")
		AssertEqual(1, SQLite_Query(Db, "SELECT space_switches FROM agg_system_day;")[1]["space_switches"])
		AssertEqual(0, KLW.batch["app_day"].Count)
		AssertEqual(0, KLW.batch["system_day"].Count)
		Recovered := _KLRDC_DerivedFingerprint(Db)
		AssertEqual(Recovered, _KLRDC_DerivedFingerprint(KLR_BuildDatabase(_KLRDC_Root())),
			"a later unchanged refresh must not repeat the raw tail or live contribution")
	} finally {
		_KLRDC_Cleanup()
		KLW.batch := SavedBatch
		Keylogger._device_id_lit := SavedDevice
	}
}
Test("KLR candidate: rejected live drain preserves raw tail and batch for retry (klr-candidate-live-retry)",
	_KLRDC_CheckTeardown.Bind(_KLRCLR_RejectedDrain))
