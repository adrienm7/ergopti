; tests/unit/test_klr_cache_sql_read_failure.ahk

; ==============================================================================
; MODULE: Cache SQL Read Failure Tests
; DESCRIPTION: Distinguish native contention from invalid metadata and file formats.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCR_ReleaseWriter(State) {
	if !State["db"]
		return
	try AssertTrue(SQLite_Exec(State["db"], "ROLLBACK;"))
	finally {
		SQLite_Close(State["db"])
		State["db"] := 0
	}
}

_KLRCR_BusyImageSurvives() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	State := Map("db", 0)
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Path := KLR_CachePath(_KLRDC_Root())
		Before := KLR_LedgerSnapshot(Path)
		KLR_ResetCache()
		State["db"] := SQLite_Open(Path, SQLiteConst.OPEN_RW)
		AssertTrue(State["db"] != 0)
		AssertTrue(SQLite_Exec(State["db"], "BEGIN EXCLUSIVE;"))
		try {
			Probe := SQLite_Open(Path, SQLiteConst.OPEN_RO)
			AssertTrue(Probe != 0)
			try {
				AssertThrows(() => SQLite_Query(Probe, "SELECT value FROM klr_cache_meta;"))
				AssertEqual(5, DllCall(SQLiteConst.DLL . "\sqlite3_errcode", "Ptr", Probe, "Int"),
					"the actual metadata query must report SQLITE_BUSY")
			} finally SQLite_Close(Probe)
			AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), "", _KLRCR_ReleaseWriter.Bind(State)))
			AssertEqual(0, KLRCache.db)
		} finally _KLRCR_ReleaseWriter(State)
		AssertTrue(FSExists(Path), "transient SQLite contention must not authorize cache deletion")
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
		Recovered := _KLRDC_BuildAsWorker()
		AssertTrue(KLRCache.readonly, "the unlocked image must be reusable without reconstruction")
		AssertEqual(1, SQLite_Query(Recovered, "SELECT chars FROM agg_app_day;")[1]["chars"])
	} finally {
		try _KLRCR_ReleaseWriter(State)
		finally _KLRDC_Cleanup()
	}
}
Test("KLR cache: busy metadata retains the reusable image (klr-cache-sql-read-failure)",
	_KLRDC_CheckTeardown.Bind(_KLRCR_BusyImageSurvives))

_KLRCR_InvalidImageIsDiscarded(NotDatabase) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header())
		_KLRDC_BuildAsWorker()
		Path := KLR_CachePath(_KLRDC_Root())
		KLR_ResetCache()
		if NotDatabase {
			FileDelete(Path)
			FileAppend("synthetic non-database file", Path, "UTF-8-RAW")
		} else {
			Db := SQLite_Open(Path, SQLiteConst.OPEN_RW)
			AssertTrue(Db != 0)
			try AssertTrue(SQLite_Exec(Db, "DROP TABLE klr_cache_meta;"))
			finally SQLite_Close(Db)
		}
		AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), ""))
		AssertFalse(FSExists(Path), "an invalid format or metadata schema must still be discarded")
	} finally _KLRDC_Cleanup()
}
for NotDatabase in [false, true]
	Test("KLR cache: reject " . (NotDatabase ? "non-database file" : "missing metadata table")
		. " (klr-cache-sql-read-failure)",
		_KLRDC_CheckTeardown.Bind(_KLRCR_InvalidImageIsDiscarded.Bind(NotDatabase)))
