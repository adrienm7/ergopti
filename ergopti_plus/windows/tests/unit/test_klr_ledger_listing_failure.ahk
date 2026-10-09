; tests/unit/test_klr_ledger_listing_failure.ahk

; ==============================================================================
; MODULE: Ledger Directory Listing Failure Tests
; DESCRIPTION: Native access denial must never masquerade as an empty metrics store.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRLL_WithDeniedListing(Scenario) {
	; The exclusive fixture owns this directory. Change only its DACL, without
	; inheritance flags, and restore it before the fixture can remove anything.
	Path := _KLRDC_Root() . "by_device"
	Needed := 0
	DllCall("Advapi32\GetFileSecurityW", "Str", Path, "UInt", 4,
		"Ptr", 0, "UInt", 0, "UInt*", &Needed)
	AssertTrue(Needed > 0)
	Saved := Buffer(Needed, 0)
	AssertTrue(DllCall("Advapi32\GetFileSecurityW", "Str", Path, "UInt", 4,
		"Ptr", Saved, "UInt", Saved.Size, "UInt*", &Needed))
	Denied := 0
	AssertTrue(DllCall("Advapi32\ConvertStringSecurityDescriptorToSecurityDescriptorW",
		"Str", "D:(D;;0x1;;;WD)(A;;FA;;;WD)", "UInt", 1,
		"Ptr*", &Denied, "Ptr", 0))
	try {
		AssertTrue(DllCall("Advapi32\SetFileSecurityW", "Str", Path, "UInt", 4, "Ptr", Denied))
		Data := Buffer(592, 0)
		Handle := DllCall("Kernel32\FindFirstFileW", "Str", Path . "\*", "Ptr", Data, "Ptr")
		ErrorCode := A_LastError
		if Handle != -1
			DllCall("Kernel32\FindClose", "Ptr", Handle)
		AssertEqual(-1, Handle, "the real directory listing must be denied")
		AssertEqual(5, ErrorCode, "the fixture must produce ERROR_ACCESS_DENIED")
		AssertTrue(DirExist(Path), "the denied directory must still exist")
		Scenario.Call()
	} finally {
		try AssertTrue(DllCall("Advapi32\SetFileSecurityW", "Str", Path, "UInt", 4, "Ptr", Saved),
			"restore the fixture DACL before cleanup")
		finally DllCall("Kernel32\LocalFree", "Ptr", Denied, "Ptr")
	}
}

_KLRLL_CheckRefusal(Cold, PreviousDb, Offset) {
	Db := KLR_BuildDatabase(_KLRDC_Root())
	AssertEqual(Cold ? 0 : PreviousDb, Db,
		"an unreadable ledger directory must not publish an empty candidate")
	if Cold {
		AssertEqual(0, KLRCache.db)
		return
	}
	AssertEqual(Offset, KLRCache.last_sizes[_KLRDC_LedgerPath()],
		"a refused listing must preserve consumed offsets")
	AssertEqual(1, SQLite_Query(Db, "SELECT chars FROM agg_app_day;")[1]["chars"],
		"a refused listing must preserve last-good aggregates")
}

_KLRLL_ReaderRefusesDeniedListing(Cold) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0)
		Offset := KLRCache.last_sizes[_KLRDC_LedgerPath()]
		if Cold
			KLR_ResetCache()
		_KLRLL_WithDeniedListing(_KLRLL_CheckRefusal.Bind(Cold, Db, Offset))
		Recovered := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Recovered != 0, "restored directory access must permit the next read")
		AssertEqual(1, SQLite_Query(Recovered, "SELECT chars FROM agg_app_day;")[1]["chars"])
	} finally _KLRDC_Cleanup()
}
for Cold in [false, true]
	Test("KLR listing: " . (Cold ? "cold" : "warm")
		. " reader refuses native access denial (klr-ledger-listing-failure)",
		_KLRDC_CheckTeardown.Bind(_KLRLL_ReaderRefusesDeniedListing.Bind(Cold)))

_KLRLL_CacheRefusal() {
	AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), ""),
		"a cache cannot claim complete source coverage through a denied listing")
	AssertEqual(0, KLRCache.db)
}

_KLRLL_DeniedListingRetainsDiskImage() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Before := KLR_LedgerSnapshot(KLR_CachePath(_KLRDC_Root()))
		_KLRLL_WithDeniedListing(() => AssertEqual(0,
			KLR_CacheSave(KLRCache.db, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots),
			"an uncertain peer catalog cannot authorize replacing its image"))
		KLR_ResetCache()
		_KLRLL_WithDeniedListing(_KLRLL_CacheRefusal)
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(KLR_CachePath(_KLRDC_Root()))),
			"a transient access failure must not delete or replace the reusable image")
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""), "restored access must admit the retained image")
		AssertEqual(1, SQLite_Query(KLRCache.db, "SELECT chars FROM agg_app_day;")[1]["chars"])
	} finally _KLRDC_Cleanup()
}
Test("KLR listing: cache refusal preserves the disk image (klr-ledger-listing-failure)",
	_KLRDC_CheckTeardown.Bind(_KLRLL_DeniedListingRetainsDiskImage))

_KLRLL_LockedLedgerRetainsDiskImage() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Guard := 0
	try {
		Source := _KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"])
		_KLRDC_WriteLedger(Source)
		_KLRDC_BuildAsWorker()
		CachePath := KLR_CachePath(_KLRDC_Root())
		Before := KLR_LedgerSnapshot(CachePath)
		KLR_ResetCache()
		Guard := FSOpenExclusiveGuard(_KLRDC_LedgerPath())
		AssertTrue(Guard != 0, "the owned journal must be locked without truncation")
		try {
			AssertTrue(FSExists(_KLRDC_LedgerPath()), "the locked source must still exist")
			AssertFalse(KLR_LedgerSnapshot(_KLRDC_LedgerPath()).Get("ok", false),
				"the lock must cause an actual source snapshot read failure")
			AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), ""))
			AssertEqual(0, KLRCache.db, "uncertain source identity must not be admitted")
			AssertTrue(FSExists(CachePath), "temporary source contention must not delete the valid cache")
			AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(CachePath)))
		} finally {
			AssertTrue(FSCloseExclusiveGuard(Guard))
			Guard := 0
		}
		AssertEqual(Source, FileRead(_KLRDC_LedgerPath(), "UTF-8"))
		Recovered := _KLRDC_BuildAsWorker()
		AssertTrue(KLRCache.readonly, "the next worker must reuse the retained image after unlock")
		AssertEqual(1, SQLite_Query(Recovered, "SELECT chars FROM agg_app_day;")[1]["chars"])
	} finally {
		if Guard
			FSCloseExclusiveGuard(Guard)
		_KLRDC_Cleanup()
	}
}
Test("KLR source: locked journal preserves reusable image (klr-locked-ledger-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRLL_LockedLedgerRetainsDiskImage))
