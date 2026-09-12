; tests/unit/test_klr_cache_offsets.ahk

; ==============================================================================
; MODULE: Reader Cache Offset Admission Tests
; DESCRIPTION: Reject consumed offsets that cannot belong to the recorded snapshot.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ Receipt admission =======
; ====================================
; ====================================

_KLRCO_InvalidOffset(Value) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		Before := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())
		CachePath := KLR_CachePath(_KLRDC_Root())
		KLR_ResetCache()
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""),
			"the unmodified receipt must admit the freshly built image")
		KLR_ResetCache()
		Stored := SQLite_Open(CachePath)
		AssertTrue(Stored != 0)
		try {
			AssertTrue(SQLite_Exec(Stored,
				"UPDATE klr_cache_ledger SET end_offset=" . Value . ";"))
		} finally SQLite_Close(Stored)
		if Value = "size+1"
			_KLRDC_AppendLedger("`n")
		AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), ""),
			"an impossible consumed offset must refuse the image")
		AssertFalse(FSExists(CachePath), "the rejected image must be retired")
		AssertEqual(Before, _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker()),
			"rebuilding from the intact source must preserve every aggregate")
	} finally _KLRDC_Cleanup()
}
Test("KLR cache: negative consumed offset forces rebuild (klr-cache-offsets)",
	_KLRDC_CheckTeardown.Bind(_KLRCO_InvalidOffset.Bind("-1")))
Test("KLR cache: fractional consumed offset forces rebuild (klr-cache-offsets)",
	_KLRDC_CheckTeardown.Bind(_KLRCO_InvalidOffset.Bind("0.5")))
Test("KLR cache: offset beyond consumed snapshot forces rebuild (klr-cache-offsets)",
	_KLRDC_CheckTeardown.Bind(_KLRCO_InvalidOffset.Bind("size+1")))

_KLRCO_InvalidPublication(Value) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "code.exe", ["a"]))
		Db := _KLRDC_BuildAsWorker()
		Before := _KLRDC_DerivedFingerprint(Db)
		CachePath := KLR_CachePath(_KLRDC_Root())
		AssertTrue(FSDelete(CachePath), "remove only the owned fixture image")
		Sizes := KLR_CopyOffsets(KLRCache.last_sizes)
		Sizes[_KLRDC_LedgerPath()] := Value
		AssertEqual(0, KLR_CacheSave(Db, Sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots),
			"invalid offsets must not produce a successful publication")
		AssertFalse(FSExists(CachePath), "an invalid receipt must not create an image")
		AssertEqual(Before, _KLRDC_DerivedFingerprint(Db),
			"refusing publication must preserve the caller's candidate")
		AssertEqual(1, KLR_CacheSave(Db, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots),
			"the same candidate with its valid receipts must remain publishable")
	} finally _KLRDC_Cleanup()
}
Test("KLR cache: negative offset cannot be published (klr-cache-offset-publication)",
	_KLRDC_CheckTeardown.Bind(_KLRCO_InvalidPublication.Bind(-1)))
Test("KLR cache: fractional offset cannot be published (klr-cache-offset-publication)",
	_KLRDC_CheckTeardown.Bind(_KLRCO_InvalidPublication.Bind(0.5)))
