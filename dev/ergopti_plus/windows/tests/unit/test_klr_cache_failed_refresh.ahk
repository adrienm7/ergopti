; tests/unit/test_klr_cache_failed_refresh.ahk

; ==============================================================================
; MODULE: Durable Cache Failed Refresh Isolation Tests
; DESCRIPTION:
; A complete transaction followed by a torn one exposes writes that escaped a
; failed refresh. File existence alone does not prove the last image survived.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCF_PreservesPublishedImage(PageSize := 0) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		if PageSize {
			KLR_ResetCache()
			Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()))
			AssertTrue(Stored != 0)
			try {
				AssertTrue(SQLite_Exec(Stored, "PRAGMA page_size=" . PageSize . ";VACUUM;"))
				AssertEqual(PageSize, SQLite_Query(Stored, "PRAGMA page_size;")[1]["page_size"])
			} finally SQLite_Close(Stored)
		}
		PublishedOffset := _KLRDC_StoredOffset()
		AssertTrue(PublishedOffset > 0, "the control must publish a real ledger offset")
		Torn := _KLRDC_TypingBatch(3, "2026-01-01 10:00:06.000", "2026-01-01",
			"code.exe", ["c"])
		_KLRDC_AppendLedger(
			_KLRDC_TypingBatch(2, "2026-01-01 10:00:03.000", "2026-01-01",
				"code.exe", ["b"])
			. SubStr(Torn, 1, InStr(Torn, "COMMIT;") - 1))
		KLR_ResetCache()
		KLRCache.disposable := true
		AssertEqual(0, KLR_BuildDatabase(_KLRDC_Root()), "a torn refresh must not publish")
		Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
		AssertTrue(Stored != 0, "the last published image must remain readable")
		try {
			if PageSize
				AssertEqual(PageSize, SQLite_Query(Stored, "PRAGMA page_size;")[1]["page_size"])
			Rows := SQLite_Query(Stored, "SELECT COUNT(*) AS n FROM events_typing;")
			AssertEqual(1, Rows[1]["n"],
				"a failed refresh must not leak an earlier committed tail transaction")
			AssertEqual(1, SQLite_Query(Stored, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"],
				"failed refreshes must preserve the aggregate paired with the old raw rows")
			Rows := SQLite_Query(Stored, "SELECT end_offset FROM klr_cache_ledger;")
			AssertEqual(PublishedOffset, Rows[1]["end_offset"],
				"raw rows and ledger offsets must describe the same published image")
		} finally {
			SQLite_Close(Stored)
		}
		_KLRDC_AppendLedger("COMMIT;`n")
		Recovered := _KLRDC_BuildAsWorker()
		AssertTrue(Recovered != 0, "completion must retry the discarded tail")
		if PageSize
			AssertEqual(PageSize, SQLite_Query(Recovered, "PRAGMA page_size;")[1]["page_size"],
				"recovery must clone the admitted image rather than silently rebuilding default geometry")
		AssertEqual(3, SQLite_Query(Recovered, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"],
			"retry must recover both tail transactions exactly once")
		AssertEqual(3, SQLite_Query(Recovered, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"],
			"recovered rollups must include every raw event exactly once")
		AssertEqual(FileGetSize(_KLRDC_LedgerPath()), KLRCache.last_sizes[_KLRDC_LedgerPath()],
			"the recovered projection must publish the completed ledger boundary")
		AssertEqual(1, KLR_CacheSave(Recovered, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots))
		KLR_ResetCache()
		KLRCache.disposable := true
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""))
		AssertEqual(3, SQLite_Query(KLRCache.db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		AssertEqual(3, SQLite_Query(KLRCache.db, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"])
		AssertEqual(FileGetSize(_KLRDC_LedgerPath()), KLRCache.last_sizes[_KLRDC_LedgerPath()])
		if PageSize
			AssertEqual(PageSize, SQLite_Query(KLRCache.db, "PRAGMA page_size;")[1]["page_size"])
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: failed refresh preserves published rows and offsets (klr-cache-failed-refresh)",
	_KLRDC_CheckTeardown.Bind(_KLRCF_PreservesPublishedImage))
for PageSize in [16384, 65536]
	Test("KLR durable cache: page size=" . PageSize . " preserves failed refresh and retry (klr-cache-failed-refresh)",
		_KLRDC_CheckTeardown.Bind(_KLRCF_PreservesPublishedImage.Bind(PageSize)))
