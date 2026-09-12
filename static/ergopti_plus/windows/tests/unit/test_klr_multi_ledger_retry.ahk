; tests/unit/test_klr_multi_ledger_retry.ahk

; ==============================================================================
; MODULE: Reader Multi-Ledger Retry Tests
; DESCRIPTION: Keep device projections atomic across interrupted sibling tails.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRMLR_FailedSibling(Disposable, FailedIndex, ReadRefusal := false) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	SavedBatch := KLW.batch
	KLW_ResetBatch()
	Probe := Map("file", 0, "locked", false, "page_size", 1, "overlap", Buffer(32, 0))
	try {
		Paths := [_KLRDC_LedgerPath(), _KLRDC_Root() . "by_device\dev-two\data.sql"]
		DirCreate(_KLRDC_Root() . "by_device\dev-two")
		Base := _KLRDC_Header() . _KLRDC_TypingBatch(9,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a", "b"])
		for Index, Path in Paths
			FileAppend(Index = 1 ? Base : StrReplace(Base, "dev-one", "dev-two"), Path, "UTF-8-RAW")
		_KLRDC_BuildAsWorker()
		KLR_ResetCache()
		KLRCache.disposable := Disposable
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0)
		AssertEqual(Disposable, KLRCache.readonly, "only the worker may retain the durable read-only handle")
		Before := _KLRDC_DerivedFingerprint(Db)
		Offsets := KLR_CopyOffsets(KLRCache.last_sizes)
		Snapshots := KLR_CopyLedgerSnapshots(KLRCache.ledger_snapshots)
		Tail := _KLRDC_TypingBatch(3,
			"2026-01-01 10:00:01.000", "2026-01-01", "fixture.exe", ["c", "d"])
		for Index, Path in Paths {
			Sql := Index = 1 ? Tail : StrReplace(Tail, "dev-one", "dev-two")
			if !ReadRefusal && Index = FailedIndex
				Sql := SubStr(Sql, 1, InStr(Sql, "COMMIT;") - 1)
			FileAppend(Sql, Path, "UTF-8-RAW")
		}
		if ReadRefusal {
			LockedPath := Paths[FailedIndex]
			LockSnapshot := KLR_LedgerSnapshot(LockedPath)
			Probe["file"] := FileOpen(LockedPath, "r")
			NumPut("Int64", Offsets[LockedPath], Probe["overlap"], 16)
			Probe["locked"] := DllCall("Kernel32\LockFileEx", "Ptr", Probe["file"].Handle,
				"UInt", 3, "UInt", 0, "UInt", 1, "UInt", 0, "Ptr", Probe["overlap"], "Int")
			AssertTrue(Probe["locked"], "the fixture must lock the first unpublished byte")
			AssertFalse(KLR_ReadLedgerTail(LockedPath, Offsets[LockedPath])["ok"],
				"the real tail reader must encounter the native refusal")
		}
		; Repeat without source changes to cover pending-tail admission as well.
		loop 2 {
			KLRCache.disposable := Disposable
			AssertEqual(Disposable && !ReadRefusal ? 0 : Db, KLR_BuildDatabase(_KLRDC_Root()),
				"a failed sibling must never return a partially advanced projection")
			if !Disposable || ReadRefusal {
				AssertEqual(Before, _KLRDC_DerivedFingerprint(Db))
				AssertEqual(2, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
				for Path, Offset in Offsets {
					AssertEqual(Offset, KLRCache.last_sizes[Path])
					AssertTrue(KLR_LedgerSnapshotIsSame(Snapshots[Path], KLRCache.ledger_snapshots[Path]))
				}
			}
			Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
			AssertTrue(Stored != 0)
			try {
				AssertEqual(Before, _KLRDC_DerivedFingerprint(Stored), "disk rollups must retain both devices")
				AssertEqual(2, SQLite_Query(Stored, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
				Rows := SQLite_Query(Stored, "SELECT end_offset FROM klr_cache_ledger;")
				AssertEqual(2, Rows.Length)
				for Row in Rows
					AssertEqual(Offsets[Paths[1]], Row["end_offset"], "neither durable offset may advance")
			} finally SQLite_Close(Stored)
		}
		if ReadRefusal {
			_KLRCC_ReleaseLock(Probe)
			AssertTrue(KLR_LedgerSnapshotIsSame(LockSnapshot, KLR_LedgerSnapshot(LockedPath)),
				"resource recovery must leave source identity, timestamps and size unchanged")
		} else
			FileAppend("COMMIT;`n", Paths[FailedIndex], "UTF-8-RAW")
		KLRCache.disposable := Disposable
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0, "recovery must unblock every sibling")
		AssertEqual(4, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		Rows := SQLite_Query(Db, "SELECT device_id, chars FROM agg_app_day ORDER BY device_id;")
		AssertEqual(2, Rows.Length)
		for Index, Row in Rows {
			AssertEqual(Index = 1 ? "dev-one" : "dev-two", Row["device_id"])
			AssertEqual(4, Row["chars"], "retry must replay the valid sibling exactly once too")
			AssertEqual(FileGetSize(Paths[Index]), KLRCache.last_sizes[Paths[Index]])
		}
		Recovered := _KLRDC_DerivedFingerprint(Db)
		AssertEqual(Recovered, _KLRDC_DerivedFingerprint(KLR_BuildDatabase(_KLRDC_Root())),
			"an unchanged retry must not add either device twice")
		KLR_ResetCache()
		FileDelete(KLR_CachePath(_KLRDC_Root()))
		Cold := _KLRDC_BuildAsWorker()
		; The resident consumes live walker deltas, which this disk-only fixture
		; does not generate. Workers reconstruct every field from the ledgers.
		if Disposable
			AssertEqual(Recovered, _KLRDC_DerivedFingerprint(Cold),
				"same-day worker recovery must match an independent cold reconstruction")
		ColdRows := SQLite_Query(Cold, "SELECT device_id, chars FROM agg_app_day ORDER BY device_id;")
		AssertEqual(Rows.Length, ColdRows.Length)
		for Index, Row in Rows {
			AssertEqual(Row["device_id"], ColdRows[Index]["device_id"])
			AssertEqual(Row["chars"], ColdRows[Index]["chars"], "SQL-owned resident counts must match cold replay")
		}
	} finally {
		_KLRCC_ReleaseLock(Probe)
		_KLRDC_Cleanup()
		KLW.batch := SavedBatch
	}
}

for Disposable in [false, true]
	for TornIndex in [1, 2]
		Test("KLR retry: torn sibling=" . TornIndex . " disposable=" . Disposable . " (klr-multi-ledger-retry)",
			_KLRDC_CheckTeardown.Bind(_KLRMLR_FailedSibling.Bind(Disposable, TornIndex)))

for Disposable in [false, true]
	for FailedIndex in [1, 2]
		Test("KLR retry: locked sibling=" . FailedIndex . " disposable=" . Disposable . " (klr-multi-ledger-read-retry)",
			_KLRDC_CheckTeardown.Bind(_KLRMLR_FailedSibling.Bind(Disposable, FailedIndex, true)))
