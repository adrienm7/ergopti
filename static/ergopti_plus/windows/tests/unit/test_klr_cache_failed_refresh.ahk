; tests/unit/test_klr_cache_failed_refresh.ahk

; ==============================================================================
; MODULE: Durable Cache Failed Refresh Isolation Tests
; DESCRIPTION:
; A complete transaction followed by a torn one exposes writes that escaped a
; failed refresh. File existence alone does not prove the last image survived.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCF_PreservesPublishedImage() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
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
			Rows := SQLite_Query(Stored, "SELECT COUNT(*) AS n FROM events_typing;")
			AssertEqual(1, Rows[1]["n"],
				"a failed refresh must not leak an earlier committed tail transaction")
			Rows := SQLite_Query(Stored, "SELECT end_offset FROM klr_cache_ledger;")
			AssertEqual(PublishedOffset, Rows[1]["end_offset"],
				"raw rows and ledger offsets must describe the same published image")
		} finally {
			SQLite_Close(Stored)
		}
	} finally {
		_KLRDC_Reset()
	}
}
Test("KLR durable cache: failed refresh preserves published rows and offsets (klr-cache-failed-refresh)",
	_KLRCF_PreservesPublishedImage)
