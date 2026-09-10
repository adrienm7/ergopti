; tests/unit/test_klr_cache_admission.ahk

; ==============================================================================
; MODULE: Reader Cache Admission Tests
; DESCRIPTION: Reject obsolete images and changed sources while preserving readonly ownership.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 3/ When an image may not be reused =======
; ==================================================
; ==================================================

_KLRDC_LegacyJsonImageIsRefused(Version := "1") {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		Before := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())
		CachePath := KLR_CachePath(_KLRDC_Root())
		KLR_ResetCache()
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"),
			"the freshly produced image must be valid before changing its version")
		KLR_ResetCache()
		Stored := SQLite_Open(CachePath)
		AssertTrue(Stored != 0)
		try {
			AssertTrue(SQLite_Exec(Stored,
				"UPDATE klr_cache_meta SET value=" . SQLite_Q(Version) . " WHERE key='format_version';"))
			AssertEqual(Version, _KLR_CacheMetaValue(Stored, "format_version"))
		} finally {
			SQLite_Close(Stored)
		}
		AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"),
			"images built with truncating JSON flushes must force reconstruction")
		AssertFalse(FSExists(CachePath), "the rejected image must be retired")
		AssertEqual(Before, _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker()),
			"the original ledger must remain available for a clean rebuild")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: legacy JSON image forces rebuild (walker-json-cache-version)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_LegacyJsonImageIsRefused))

Test("KLR durable cache: lossy title image forces rebuild (title-cap-count-conservation)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_LegacyJsonImageIsRefused.Bind("8")))

Test("KLR durable cache: mixed daily activity image forces rebuild (session-replay-day-scope)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_LegacyJsonImageIsRefused.Bind("9")))

_KLRDC_ReadonlyImage(Disposable) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a", "b"]))
		Before := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())
		CachePath := KLR_CachePath(_KLRDC_Root())
		AssertTrue(FSExists(CachePath))
		KLR_ResetCache()
		KLRCache.disposable := Disposable
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"))
		Db := KLRCache.db
		AssertEqual(Disposable ? 1 : 0,
			DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly", "Ptr", Db, "AStr", "main", "Int"),
			"only a disposable worker may retain the read-only image")
		AssertEqual(Before, _KLRDC_DerivedFingerprint(Db))
		if Disposable {
			AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()),
				"an unchanged worker must keep its validated image")
			AssertEqual(Before, _KLRDC_DerivedFingerprint(Db))
			_KLRDC_AppendLedger(_KLRDC_TypingBatch(2,
				"2026-01-01 10:00:02.000", "2026-01-01", "code.exe", ["c"]))
			Db := KLR_BuildDatabase(_KLRDC_Root())
			AssertTrue(Db != 0, "a tail must materialize a writable candidate")
			AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly",
				"Ptr", Db, "AStr", "main", "Int"))
			Rows := SQLite_Query(Db, "SELECT SUM(chars) AS chars FROM agg_app_day;")
			AssertEqual(3, Rows[1]["chars"], "the appended tail must reach the projection exactly once")
			Warm := _KLRDC_DerivedFingerprint(Db)
			KLR_ResetCache()
			AssertTrue(FSDelete(CachePath), "reset must release every cache file handle")
			AssertEqual(Warm, _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker()))
		} else {
			AssertTrue(SQLite_Exec(Db, "CREATE TABLE readonly_live_control (value INTEGER);"),
				"resident attachment must still support its private live writes")
		}
		KLR_ResetCache()
		KLRCache.disposable := Disposable
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"))
		KLR_ResetCache()
		AssertTrue(FSDelete(CachePath), "reset must close a freshly attached image before deletion")
	} finally {
		_KLRDC_Cleanup()
	}
}
for Disposable in [false, true]
	Test("KLR durable cache: readonly reuse disposable=" . Disposable . " (klr-readonly-image)",
		_KLRDC_CheckTeardown.Bind(_KLRDC_ReadonlyImage.Bind(Disposable)))

_KLRDC_ReadonlyPublicationLock() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Reader := 0
	Candidate := 0
	Reopened := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Offsets := KLR_CopyOffsets(KLRCache.last_sizes)
		Snapshots := KLR_CopyLedgerSnapshots(KLRCache.ledger_snapshots)
		CachePath := KLR_CachePath(_KLRDC_Root())
		KLR_ResetCache()
		Reader := SQLite_Open(CachePath, SQLiteConst.OPEN_RO)
		AssertTrue(Reader != 0)
		Before := _KLRDC_DerivedFingerprint(Reader)
		Candidate := SQLite_CloneMemory(Reader)
		AssertTrue(Candidate != 0)
		AssertTrue(SQLite_Exec(Candidate,
			"CREATE TABLE readonly_publication_marker (value INTEGER);"
			. "INSERT INTO readonly_publication_marker VALUES (37);"))
		AssertEqual(0, KLR_CacheSave(Candidate, Offsets, _KLRDC_Root(), A_Temp . "\ergopti_klrdc.log", Snapshots),
			"a native reader must refuse replacement without invalidating the old image")
		AssertEqual(Before, _KLRDC_DerivedFingerprint(Reader))
		Reopened := SQLite_Open(CachePath, SQLiteConst.OPEN_RO)
		AssertTrue(Reopened != 0)
		Rows := SQLite_Query(Reopened,
			"SELECT COUNT(*) AS n FROM sqlite_master WHERE name='readonly_publication_marker';")
		AssertEqual(0, Rows[1]["n"], "failed publication must not modify the canonical image")
		SQLite_Close(Reopened)
		Reopened := 0
		SQLite_Close(Reader)
		Reader := 0
		AssertEqual(1, KLR_CacheSave(Candidate, Offsets, _KLRDC_Root(), A_Temp . "\ergopti_klrdc.log", Snapshots))
		Reopened := SQLite_Open(CachePath, SQLiteConst.OPEN_RO)
		AssertTrue(Reopened != 0)
		Rows := SQLite_Query(Reopened, "SELECT value FROM readonly_publication_marker;")
		AssertEqual(1, Rows.Length)
		AssertEqual(37, Rows[1]["value"])
	} finally {
		try {
			if Reopened
				SQLite_Close(Reopened)
			if Reader
				SQLite_Close(Reader)
			if Candidate
				SQLite_Close(Candidate)
		} finally {
			_KLRDC_Cleanup()
		}
	}
}
Test("KLR durable cache: readonly reader fences atomic publication (klr-readonly-image)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_ReadonlyPublicationLock))

_KLRDC_ReadonlyOwnershipCannotChange() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Db := _KLRDC_BuildAsWorker()
		AssertEqual(1, DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly",
			"Ptr", Db, "AStr", "main", "Int"))
		KLRCache.disposable := false
		Failure := 0
		try KLR_BuildDatabase(_KLRDC_Root())
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, "resident ownership")
		AssertEqual(Db, KLRCache.db, "invalid ownership must not replace the existing handle")
		AssertTrue(_KLRDC_DerivedFingerprint(Db) != "")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: readonly ownership cannot become resident (klr-readonly-image)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_ReadonlyOwnershipCannotChange))

_KLRDC_ReplacedLedgerIsRefused() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		CachePath := KLR_CachePath(_KLRDC_Root())
		AssertTrue(FSExists(CachePath), "the first build must publish an image")

		; A compaction rewrites data.sql as a different file. Every byte offset
		; in the image now names the wrong bytes.
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"])
			. _KLRDC_TypingBatch(2, "2026-01-01 10:00:05.000", "2026-01-01",
				"code.exe", ["b"]))

		KLR_ResetCache()
		Attached := KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log")
		AssertEqual(0, Attached,
			"a replaced ledger must force a cold rebuild: its offsets no longer "
			. "point at the bytes the image was built from")
		AssertFalse(FSExists(CachePath),
			"a refused image must be deleted, not left for the next worker to "
			. "reject again")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: a replaced ledger refuses the image (klr-reader-durable-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_ReplacedLedgerIsRefused))

_KLRDC_NewDeviceIsRefused() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()

		; A second machine's ledger appears. It has no offset in the image and no
		; replayed walker state, and there is no correct partial answer for it.
		SecondDir := _KLRDC_Root() . "by_device\dev-two"
		DirCreate(SecondDir)
		FileAppend(_KLRDC_Header(), SecondDir . "\data.sql", "UTF-8-RAW")

		KLR_ResetCache()
		AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"),
			"a ledger the image never saw must force a cold rebuild")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: an unknown device ledger refuses the image (klr-reader-durable-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_NewDeviceIsRefused))
