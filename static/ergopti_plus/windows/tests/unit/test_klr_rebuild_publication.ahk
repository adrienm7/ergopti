; tests/unit/test_klr_rebuild_publication.ahk

; ==============================================================================
; MODULE: Reader Rebuild Publication Tests
; DESCRIPTION: Recovery from a replaced ledger must renew the reusable disk image.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRRP_ReplacedLedgerRenewsImage(Mode := "worker") {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a", "b"]))
		_KLRDC_BuildAsWorker()
		Before := KLRCache.ledger_snapshots[_KLRDC_LedgerPath()].Clone()
		BeforeDb := KLRCache.db
		BeforeOffset := KLRCache.last_sizes[_KLRDC_LedgerPath()]
		BeforeSavedAt := KLRCache.saved_at
		DiskBefore := KLR_LedgerSnapshot(KLR_CachePath(_KLRDC_Root()))
		AssertTrue(KLRCache.saved_at != "", "the old image must have been published recently")
		Expected := Mode = "shrink" ? 1 : 3
		NewSql := _KLRDC_Header() . _KLRDC_TypingBatch(2, "2026-01-01 11:00:00.000",
			"2026-01-01", "fixture.exe", Mode = "shrink" ? ["z"] : ["x", "y", "z"])
		if Mode = "shrink" {
			Writer := FileOpen(_KLRDC_LedgerPath(), "rw", "UTF-8-RAW")
			try {
				Writer.Write(NewSql)
				Writer.Length := Writer.Pos
			} finally Writer.Close()
			Current := KLR_LedgerSnapshot(_KLRDC_LedgerPath())
			AssertTrue(KLR_LedgerFileIsSame(Before, Current))
			AssertTrue(Current["size"] < BeforeOffset, "the same ledger must shrink below its consumed offset")
		} else {
			_KLRDC_WriteLedger(NewSql . (Mode = "failure" ? "INVALID FIXTURE SQL;" : ""))
			AssertFalse(KLR_LedgerFileIsSame(Before, KLR_LedgerSnapshot(_KLRDC_LedgerPath())),
				"the fixture must replace the ledger identity")
		}
		if Mode = "resident"
			KLRCache.disposable := false
		Db := KLR_BuildDatabase(_KLRDC_Root())
		if Mode = "failure" {
			AssertEqual(BeforeDb, Db, "failed recovery must preserve the last-good handle")
			AssertEqual(BeforeOffset, KLRCache.last_sizes[_KLRDC_LedgerPath()])
			AssertTrue(KLR_LedgerFileIsSame(Before, KLRCache.ledger_snapshots[_KLRDC_LedgerPath()]))
			AssertEqual(BeforeSavedAt, KLRCache.saved_at)
			AssertEqual(2, SQLite_Query(Db, "SELECT chars FROM agg_app_day;")[1]["chars"])
			AssertTrue(KLR_LedgerSnapshotIsSame(DiskBefore, KLR_LedgerSnapshot(KLR_CachePath(_KLRDC_Root()))))
			_KLRDC_WriteLedger(NewSql)
			Db := KLR_BuildDatabase(_KLRDC_Root())
		}
		AssertEqual(Expected, SQLite_Query(Db, "SELECT chars FROM agg_app_day;")[1]["chars"],
			"recovery must first publish the new complete in-memory projection")
		Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
		AssertTrue(Stored != 0)
		try {
			AssertEqual(Mode = "resident" ? 2 : Expected, SQLite_Query(Stored, "SELECT chars FROM agg_app_day;")[1]["chars"],
				"only a worker may replace the obsolete image after successful recovery")
		} finally SQLite_Close(Stored)
		if Mode = "resident" {
			AssertTrue(KLR_LedgerSnapshotIsSame(DiskBefore, KLR_LedgerSnapshot(KLR_CachePath(_KLRDC_Root()))),
				"resident recovery must never persist its private projection")
			return
		}
		NextDb := _KLRDC_BuildAsWorker()
		AssertTrue(KLRCache.readonly, "the next worker must attach the rebuilt image instead of rebuilding again")
		AssertEqual(Expected, SQLite_Query(NextDb, "SELECT chars FROM agg_app_day;")[1]["chars"])
	} finally _KLRDC_Cleanup()
}
Test("KLR rebuild: replaced ledger renews the reusable image immediately (klr-rebuild-publication)",
	_KLRDC_CheckTeardown.Bind(_KLRRP_ReplacedLedgerRenewsImage))
Test("KLR rebuild: a truncated ledger renews the reusable image (klr-rebuild-publication)",
	_KLRDC_CheckTeardown.Bind(_KLRRP_ReplacedLedgerRenewsImage.Bind("shrink")))
Test("KLR rebuild: failed recovery preserves the image and retries (klr-rebuild-publication)",
	_KLRDC_CheckTeardown.Bind(_KLRRP_ReplacedLedgerRenewsImage.Bind("failure")))
Test("KLR rebuild: resident recovery cannot publish a disk image (klr-rebuild-publication)",
	_KLRDC_CheckTeardown.Bind(_KLRRP_ReplacedLedgerRenewsImage.Bind("resident")))

_KLRRP_DisappearingUnpublishedLedger(RemoveRoot) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Root := _KLRDC_Root()
		Db := KLR_BuildDatabase(Root)
		AssertTrue(Db != 0, "an empty resident store must have a valid projection")
		AssertEqual(0, KLRCache.last_sizes.Count)
		_KLRDC_WriteLedger(_KLRDC_Header()
			. "CREATE TABLE pending_probe(n INTEGER); INSERT INTO pending_probe VALUES(")
		AssertEqual(Db, KLR_BuildDatabase(Root), "incomplete new bytes must retain the empty projection")
		AssertEqual(1, KLRCache.pending_snapshots.Count, "the actual incomplete tail must establish pending state")
		AssertEqual(0, KLRCache.last_sizes.Count, "no incomplete byte boundary may be published")
		FileDelete(_KLRDC_LedgerPath())
		if RemoveRoot {
			; Only remove the fixture's now-empty directories, without recursion.
			DirDelete(Root . "by_device\dev-one")
			DirDelete(Root . "by_device")
		}
		AssertEqual(Db, KLR_BuildDatabase(Root), "removing unpublished bytes must preserve the valid handle")
		AssertEqual(0, KLRCache.pending_snapshots.Count,
			"a missing unpublished ledger must not leave a permanently pending snapshot")
		AssertEqual(0, KLRCache.last_sizes.Count)
		DirCreate(Root . "by_device\dev-one")
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		Recovered := KLR_BuildDatabase(Root)
		AssertTrue(Recovered != 0)
		AssertEqual(1, SQLite_Query(Recovered, "SELECT chars FROM agg_app_day;")[1]["chars"],
			"a recreated complete ledger must still be consumed")
	} finally _KLRDC_Cleanup()
}
for RemoveRoot in [false, true]
	Test("KLR rebuild: forget unpublished ledger after " . (RemoveRoot ? "root" : "file")
		. " removal (klr-unpublished-ledger-removal)",
		_KLRDC_CheckTeardown.Bind(_KLRRP_DisappearingUnpublishedLedger.Bind(RemoveRoot)))
