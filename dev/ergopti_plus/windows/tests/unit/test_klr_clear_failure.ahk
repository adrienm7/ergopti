; static/ergopti_plus/windows/tests/unit/test_klr_clear_failure.ahk

; ==============================================================================
; MODULE: Reader Aggregate Clear Failure Tests
; DESCRIPTION: Reject incomplete clearing before additive walker replay.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCF_RejectClear(Warm) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Ledger := _KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"])
		Trigger := "CREATE TRIGGER reject_ngram_clear BEFORE DELETE ON ngram_chars "
			. "BEGIN SELECT RAISE(ABORT,'fixture delete rejected'); END;`n"
		Published := 0
		if Warm {
			_KLRDC_WriteLedger(Ledger)
			_KLRDC_BuildAsWorker()
			Published := _KLRDC_StoredOffset()
			AssertTrue(Published > 0)
			_KLRDC_AppendLedger(Trigger
				. _KLRDC_TypingBatch(2, "2026-01-01 10:00:03.000", "2026-01-01",
					"code.exe", ["b"]))
		} else {
			; A DELETE trigger only fires when a row exists in its table.
			_KLRDC_WriteLedger(Ledger
				. "INSERT INTO ngram_chars(device_id,date,app,token,c) "
				. "VALUES('dev-one','2026-01-01','code.exe','a',1);`n" . Trigger)
		}
		KLR_ResetCache()
		KLRCache.disposable := true
		Db := KLR_BuildDatabase(_KLRDC_Root())
		Count := Db ? SQLite_Query(Db,
			"SELECT c FROM ngram_chars WHERE token='a';")[1]["c"] : 0
		AssertEqual(0, Db,
			"a rejected clear must abort publication, not replay into old counters; a=" . Count)
		AssertEqual(0, KLRCache.db, "failed worker build must release its candidate")
		AssertEqual(0, KLRCache.last_sizes.Count, "failed worker build must release candidate offsets")
		if Warm {
			AssertEqual(Published, _KLRDC_StoredOffset(), "failed refresh must retain durable offsets")
			Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
			AssertTrue(Stored != 0)
			try {
				AssertEqual(1, SQLite_Query(Stored, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
				AssertEqual(1, SQLite_Query(Stored, "SELECT c FROM ngram_chars WHERE token='a';")[1]["c"])
			} finally {
				SQLite_Close(Stored)
			}
		} else {
			AssertFalse(FSExists(KLR_CachePath(_KLRDC_Root())))
		}
	} finally {
		_KLRDC_Cleanup()
	}
}
for Warm in [false, true]
	Test("KLR rejects aggregate clear failure warm=" . Warm . " (klr-clear-failure)",
		_KLRDC_CheckTeardown.Bind(_KLRCF_RejectClear.Bind(Warm)))
