; tests/unit/test_klr_cache_save_cadence.ahk

; ==============================================================================
; MODULE: Reader Cache Save Cadence Tests
; DESCRIPTION: Save timing must avoid redundant copies without delaying recovery.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCSC_SaveCadence(Mode) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Locked := 0
	Stored := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Path := KLR_CachePath(_KLRDC_Root())
		OldOffset := _KLRDC_StoredOffset()
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(2,
			"2026-01-01 10:00:03.000", "2026-01-01", "fixture.exe", ["b"]))
		Db := _KLRDC_BuildAsWorker()
		AssertFalse(KLRCache.readonly, "the tail must produce a private writable candidate")
		AssertEqual(2, SQLite_Query(Db, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"])
		AssertEqual(OldOffset, _KLRDC_StoredOffset(), "the recent disk image must still precede the candidate")
		Stamp := Mode = "recent" ? A_Now : Mode = "future" ? DateAdd(A_Now, 3600, "Seconds")
			: Mode = "invalid" ? "invalid" : DateAdd(A_Now, -KLR_CACHE_MIN_SAVE_INTERVAL_S - 60, "Seconds")
		KLRCache.saved_at := Stamp
		Before := KLR_LedgerSnapshot(Path)
		if Mode = "refused" {
			Locked := FileOpen(Path, "r-wd")
			AssertTrue(IsObject(Locked))
		}
		Diagnostic := _KLRDC_Root() . "cadence.log"
		Saved := KLR_CacheSaveIfOwned(_KLRDC_Root(), Diagnostic)
		if Mode = "recent" || Mode = "refused" {
			AssertFalse(Saved)
			AssertEqual(Stamp, KLRCache.saved_at, "a skipped or failed save must not renew the cadence")
			AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
			if Mode = "refused" {
				AssertContains(FileRead(Diagnostic, "UTF-8"), "KLR cache save failed: atomic publish")
				Locked.Close()
				Locked := 0
			}
			AssertEqual(OldOffset, _KLRDC_StoredOffset())
			if Mode = "recent"
				return
			AssertTrue(KLR_CacheSaveIfOwned(_KLRDC_Root(), Diagnostic),
				"an expired save must retry immediately after native replacement refusal clears")
		} else {
			AssertTrue(Saved, "expired, future and invalid timestamps must permit a fresh image")
		}
		AssertTrue(KLRCache.saved_at != Stamp, "only a successful save must renew the timestamp")
		AssertTrue(DateDiff(A_Now, KLRCache.saved_at, "Seconds") >= 0)
		AssertEqual(FileGetSize(_KLRDC_LedgerPath()), _KLRDC_StoredOffset())
		Stored := SQLite_Open(Path, SQLiteConst.OPEN_RO)
		AssertTrue(Stored != 0)
		AssertEqual(2, SQLite_Query(Stored, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"])
		SQLite_Close(Stored)
		Stored := 0
		Published := KLR_LedgerSnapshot(Path)
		AssertFalse(KLR_CacheSaveIfOwned(_KLRDC_Root(), Diagnostic),
			"a successful retry must restore the normal copy throttle")
		AssertTrue(KLR_LedgerSnapshotIsSame(Published, KLR_LedgerSnapshot(Path)))
	} finally {
		SQLite_Close(Stored)
		if IsObject(Locked)
			Locked.Close()
		_KLRDC_Cleanup()
	}
}
for Mode in ["recent", "expired", "future", "invalid", "refused"]
	Test("KLR cache cadence: " . Mode . " timestamp and publication (klr-cache-save-cadence)",
		_KLRDC_CheckTeardown.Bind(_KLRCSC_SaveCadence.Bind(Mode)))
