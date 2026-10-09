; tests/unit/test_klr_cache_rejection_identity.ahk

; ==============================================================================
; MODULE: Reader Cache Rejection Identity Tests
; DESCRIPTION: A rejected image cannot authorize deletion of a peer's replacement.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRRI_ReplacementSurvives(Mode := "replace") {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Locked := -1
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a", "b"]))
		_KLRDC_BuildAsWorker()
		KLR_ResetCache()
		KLRCache.disposable := true
		Path := KLR_CachePath(_KLRDC_Root())
		Replacement := Path . ".peer-fixture"
		FileCopy(Path, Replacement)
		Rejected := SQLite_Open(Path)
		try AssertTrue(SQLite_Exec(Rejected, "UPDATE klr_cache_meta SET value='obsolete' WHERE key='format_version';"))
		finally SQLite_Close(Rejected)
		Before := KLR_LedgerSnapshot(Path)
		AssertTrue(Before.Get("ok", false), "the fixture must observe the obsolete image")
		if Mode = "locked-open" {
			Locked := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000,
				"UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
			AssertTrue(Locked != -1)
		}
		Published := 0
		PublishPeer() {
			if Locked != -1 {
				DllCall("kernel32\CloseHandle", "Ptr", Locked)
				Locked := -1
			}
			if Mode = "in-place" {
				Repaired := SQLite_Open(Path)
				try AssertTrue(SQLite_Exec(Repaired, "UPDATE klr_cache_meta SET value="
					. SQLite_Q(KLR_CACHE_FORMAT_VERSION) . " WHERE key='format_version';"))
				finally SQLite_Close(Repaired)
				; Make the write-time distinction deterministic on every filesystem.
				FileSetTime("20000101000000", Path, "M")
				AssertTrue(KLR_LedgerFileIsSame(Before, KLR_LedgerSnapshot(Path)))
				AssertFalse(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
			} else {
				AssertTrue(FSAtomicMoveReplace(Replacement, Path),
					"the old SQLite handle must be closed before the peer publishes")
				AssertFalse(KLR_LedgerFileIsSame(Before, KLR_LedgerSnapshot(Path)))
			}
			Published += 1
		}
		AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), "", PublishPeer), "the observed old image must be rejected")
		AssertEqual(1, Published, "the peer must publish at the rejection boundary")
		AssertTrue(FSExists(Path), "a stale rejection must not delete the peer's new image")
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""), "the peer's image must remain attachable")
		AssertEqual(2, SQLite_Query(KLRCache.db, "SELECT chars FROM agg_app_day;")[1]["chars"])
	} finally {
		if Locked != -1
			DllCall("kernel32\CloseHandle", "Ptr", Locked)
		_KLRDC_Cleanup()
	}
}
Test("KLR cache: stale rejection preserves a peer publication (klr-cache-rejection-identity)",
	_KLRDC_CheckTeardown.Bind(_KLRRI_ReplacementSurvives))
Test("KLR cache: stale rejection preserves an in-place repair (klr-cache-rejection-identity)",
	_KLRDC_CheckTeardown.Bind(_KLRRI_ReplacementSurvives.Bind("in-place")))
Test("KLR cache: failed open cannot delete a peer publication (klr-cache-rejection-identity)",
	_KLRDC_CheckTeardown.Bind(_KLRRI_ReplacementSurvives.Bind("locked-open")))
