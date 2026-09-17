; tests/unit/test_klr_cache_copy_failure.ahk

; ==============================================================================
; MODULE: Cache Copy Failure Tests
; DESCRIPTION: A failed native memory restore must preserve an already validated image.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCC_ReleaseLock(Probe) {
	if !IsObject(Probe["file"])
		return
	try {
		if Probe["locked"]
			AssertTrue(DllCall("Kernel32\UnlockFileEx", "Ptr", Probe["file"].Handle,
				"UInt", 0, "UInt", Probe["page_size"], "UInt", 0, "Ptr", Probe["overlap"], "Int"))
	} finally {
		Probe["locked"] := false
		Probe["file"].Close()
		Probe["file"] := 0
	}
}

_KLRCC_CopyFailureRetainsImage(RequestedPageSize := 0) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Probe := Map("file", 0, "locked", false)
	Repacked := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		Db := _KLRDC_BuildAsWorker()
		if RequestedPageSize {
			; Repack an owned fixture before adding overflow pages; production
			; publication must preserve this geometry without a new writer policy.
			Repacked := SQLite_Open(_KLRDC_Root() . "repacked.sqlite")
			AssertTrue(Repacked != 0)
			AssertTrue(SQLite_BackupInto(Repacked, Db))
			AssertTrue(SQLite_Exec(Repacked, "PRAGMA page_size=" . RequestedPageSize . ";VACUUM;"))
			Db := Repacked
			AssertEqual(RequestedPageSize, SQLite_Query(Db, "PRAGMA page_size;")[1]["page_size"])
		}
		AssertTrue(SQLite_Exec(Db, "CREATE TABLE cache_copy_probe(payload BLOB);"
			. "INSERT INTO cache_copy_probe VALUES(zeroblob(1048576));"))
		PageSize := SQLite_Query(Db, "PRAGMA page_size;")[1]["page_size"]
		Pages := SQLite_Query(Db, "PRAGMA page_count;")[1]["page_count"]
		AssertTrue(Pages > 2)
		AssertEqual(1, KLR_CacheSave(Db, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots))
		ExpectedSizes := KLRCache.last_sizes.Clone()
		ExpectedSnapshots := KLRCache.ledger_snapshots.Clone()
		ExpectedDerived := _KLRDC_DerivedFingerprint(Db)
		ExpectedRows := SQLite_Query(Db, "SELECT count(*) AS n FROM events_typing;")[1]["n"]
		AssertTrue(ExpectedRows > 0)
		Path := KLR_CachePath(_KLRDC_Root())
		Before := KLR_LedgerSnapshot(Path)
		KLR_ResetCache()
		SQLite_Close(Repacked)
		Repacked := 0
		Probe["file"] := FileOpen(Path, "rw")
		Probe["page_size"] := PageSize
		Probe["overlap"] := Buffer(32, 0)
		; Backup preserves page numbers. Lock the source's last overflow page,
		; before the destination's cache metadata was appended by the publisher.
		NumPut("UInt", (Pages - 1) * PageSize, Probe["overlap"], 16)
		Probe["locked"] := DllCall("Kernel32\LockFileEx", "Ptr", Probe["file"].Handle,
			"UInt", 3, "UInt", 0, "UInt", PageSize, "UInt", 0, "Ptr", Probe["overlap"], "Int")
		AssertTrue(Probe["locked"])
		try {
			KLRCache.disposable := true
			AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""),
				"positive control: the image metadata must validate while the payload page is locked")
			KLR_ResetCache()
			; Model contention ending between copy refusal and rejection cleanup.
			; The existing seam releases the probe if rejection would delete it.
			AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), "", _KLRCC_ReleaseLock.Bind(Probe)),
				"the resident restore must actually encounter the unreadable page")
			AssertEqual(0, KLRCache.db)
		} finally _KLRCC_ReleaseLock(Probe)
		AssertTrue(FSExists(Path), "a failed memory copy must not delete the validated image")
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
		for Disposable in [false, true] {
			KLRCache.disposable := Disposable
			AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""))
			AssertEqual(Disposable, KLRCache.readonly)
			AssertEqual(Disposable, DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly",
				"Ptr", KLRCache.db, "AStr", "main", "Int"))
			AssertEqual(ExpectedDerived, _KLRDC_DerivedFingerprint(KLRCache.db))
			AssertEqual(ExpectedRows, SQLite_Query(KLRCache.db, "SELECT count(*) AS n FROM events_typing;")[1]["n"])
			AssertEqual(PageSize, SQLite_Query(KLRCache.db, "PRAGMA page_size;")[1]["page_size"])
			AssertEqual("ok", SQLite_Query(KLRCache.db, "PRAGMA integrity_check;")[1]["integrity_check"])
			AssertEqual(1048576, SQLite_Query(KLRCache.db, "SELECT length(payload) AS n FROM cache_copy_probe;")[1]["n"])
			AssertEqual(1, SQLite_Query(KLRCache.db, "SELECT count(*) AS n FROM cache_copy_probe;")[1]["n"],
				"resident growth must never change the durable image restored by the next worker")
			AssertEqual(ExpectedSizes.Count, KLRCache.last_sizes.Count)
			AssertEqual(ExpectedSnapshots.Count, KLRCache.ledger_snapshots.Count)
			for LedgerPath, Offset in ExpectedSizes {
				AssertEqual(Offset, KLRCache.last_sizes[LedgerPath])
				AssertTrue(KLR_LedgerSnapshotIsSame(ExpectedSnapshots[LedgerPath], KLRCache.ledger_snapshots[LedgerPath]))
			}
			if !Disposable {
				AssertTrue(SQLite_Exec(KLRCache.db, "INSERT INTO cache_copy_probe VALUES(zeroblob(70000));"))
				AssertEqual(2, SQLite_Query(KLRCache.db, "SELECT count(*) AS n FROM cache_copy_probe;")[1]["n"])
			}
			KLR_ResetCache()
		}
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
	} finally {
		try _KLRCC_ReleaseLock(Probe)
		finally {
			SQLite_Close(Repacked)
			_KLRDC_Cleanup()
		}
	}
}
Test("KLR cache: failed native memory copy retains validated image (klr-cache-copy-failure)",
	_KLRDC_CheckTeardown.Bind(_KLRCC_CopyFailureRetainsImage))
for PageSize in [16384, 65536]
	Test("KLR cache: page size=" . PageSize . " survives copy refusal and private restore (klr-cache-copy-failure)",
		_KLRDC_CheckTeardown.Bind(_KLRCC_CopyFailureRetainsImage.Bind(PageSize)))
