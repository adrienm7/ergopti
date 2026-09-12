; tests/unit/test_klr_cache_publication_order.ahk

; ==============================================================================
; MODULE: Reader Cache Publication Order Tests
; DESCRIPTION: Older worker candidates must not replace a newer durable image.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCPO_OlderWorkerCannotRegressImage(InvalidPeerKey := "") {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Older := 0
	Stored := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		Initial := _KLRDC_BuildAsWorker()
		Older := SQLite_CloneMemory(Initial)
		AssertTrue(Older != 0)
		OldSizes := KLR_CopyOffsets(KLRCache.last_sizes)
		OldSnapshots := KLR_CopyLedgerSnapshots(KLRCache.ledger_snapshots)
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(2,
			"2026-01-01 10:00:01.000", "2026-01-01", "fixture.exe", ["b"]))
		Newer := _KLRDC_BuildAsWorker()
		Expected := _KLRDC_DerivedFingerprint(Newer)
		NewOffset := KLRCache.last_sizes[_KLRDC_LedgerPath()]
		AssertEqual(2, SQLite_Query(Newer, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"])
		; Bypass the cadence to model a peer whose complete publication finished first.
		AssertEqual(1, KLR_CacheSave(Newer, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots))
		if InvalidPeerKey != "" {
			Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()))
			AssertTrue(Stored != 0)
			if InvalidPeerKey = "payload"
				AssertTrue(SQLite_Exec(Stored, "CREATE TABLE main.KLR_READER_TYPING_PAYLOAD(events_json TEXT);"
					. "INSERT INTO main.klr_reader_typing_payload VALUES('[[],[]]');"))
			else
				AssertTrue(SQLite_Exec(Stored, "UPDATE klr_cache_meta SET value='invalid' WHERE key="
					. SQLite_Q(InvalidPeerKey) . ";"))
			SQLite_Close(Stored)
			Stored := 0
			Expected := _KLRDC_DerivedFingerprint(Older)
			NewOffset := OldSizes[_KLRDC_LedgerPath()]
		}
		OldSaved := KLR_CacheSave(Older, OldSizes, _KLRDC_Root(), "", OldSnapshots)
		Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
		AssertTrue(Stored != 0)
		AssertEqual(NewOffset, SQLite_Query(Stored, "SELECT end_offset FROM klr_cache_ledger;")[1]["end_offset"],
			"a late older worker must not regress the durable consumed offset")
		AssertEqual(Expected, _KLRDC_DerivedFingerprint(Stored), "a late older worker must preserve newer aggregates")
		AssertEqual(InvalidPeerKey != "" ? 1 : 0, OldSaved,
			"only an admissible peer may prevent publication of a complete candidate")
		if InvalidPeerKey = "payload" {
			AssertEqual(0, SQLite_Query(Stored,
				"SELECT COUNT(*) AS n FROM main.sqlite_schema WHERE name='klr_reader_typing_payload' COLLATE NOCASE;")[1]["n"],
				"the inadmissible peer must be replaced by a payload-free image")
			SQLite_Close(Stored)
			Stored := 0
			Recovered := _KLRDC_BuildAsWorker()
			AssertEqual(2, SQLite_Query(Recovered, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"],
				"newer events must replay from the ledger after safe-image replacement")
		}
	} finally {
		SQLite_Close(Stored)
		SQLite_Close(Older)
		_KLRDC_Cleanup()
	}
}
Test("KLR cache: older worker cannot replace newer image (klr-cache-publication-order)",
	_KLRDC_CheckTeardown.Bind(_KLRCPO_OlderWorkerCannotRegressImage))
for Key in ["format_version", "walker_timings", "payload"]
	Test("KLR cache: invalid peer " . Key . " permits rebuild (klr-cache-publication-order)",
		_KLRDC_CheckTeardown.Bind(_KLRCPO_OlderWorkerCannotRegressImage.Bind(Key)))

_KLRCPO_GuardContentionAndRelease() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Guard := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		Db := _KLRDC_BuildAsWorker()
		GuardPath := KLR_CachePath(_KLRDC_Root()) . ".publish.lock"
		AssertEqual(0, FSOpenExclusiveGuard(KLR_CacheDir(_KLRDC_Root())),
			"a directory must not become a publication guard")
		FileAppend("owned sentinel", GuardPath, "UTF-8-RAW")
		Guard := FSOpenExclusiveGuard(GuardPath)
		AssertTrue(Guard != 0)
		Other := FSOpenExclusiveGuard(GuardPath)
		if Other
			FSCloseExclusiveGuard(Other)
		AssertEqual(0, Other, "a second opener must not acquire an owned publication guard")
		AssertEqual(0, KLR_CacheSave(Db, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots),
			"a contending publisher must skip without replacing the image")
		AssertTrue(FSCloseExclusiveGuard(Guard))
		Guard := 0
		AssertEqual("owned sentinel", FileRead(GuardPath, "UTF-8-RAW"), "acquisition must never truncate the guard")
		AssertEqual(1, KLR_CacheSave(Db, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots),
			"equal offsets remain publishable after the competing owner releases")
		AssertTrue(SQLite_Exec(Db, "CREATE TABLE main.klr_reader_typing_payload (private_value TEXT);"))
		AssertEqual(0, KLR_CacheSave(Db, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots),
			"a private payload schema must still reject the guarded save")
		Guard := FSOpenExclusiveGuard(GuardPath)
		AssertTrue(Guard != 0, "failed saves must release publication ownership")
	} finally {
		if Guard
			FSCloseExclusiveGuard(Guard)
		_KLRDC_Cleanup()
	}
}
Test("KLR cache: publication guard excludes peers and survives failure (klr-cache-publication-order)",
	_KLRDC_CheckTeardown.Bind(_KLRCPO_GuardContentionAndRelease))

_KLRCPO_IncomparableDevices() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Base := _KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"])
		_KLRDC_WriteLedger(Base)
		Second := _KLRDC_Root() . "by_device\dev-two\data.sql"
		DirCreate(_KLRDC_Root() . "by_device\dev-two")
		FileAppend(StrReplace(Base, "dev-one", "dev-two"), Second, "UTF-8-RAW")
		_KLRDC_BuildAsWorker()
		CandidateSizes := KLR_CopyOffsets(KLRCache.last_sizes)
		CandidateSnapshots := KLR_CopyLedgerSnapshots(KLRCache.ledger_snapshots)
		Tail := _KLRDC_TypingBatch(2, "2026-01-01 10:00:01.000", "2026-01-01", "fixture.exe", ["b"])
		_KLRDC_AppendLedger(Tail)
		Peer := _KLRDC_BuildAsWorker()
		AssertEqual(1, KLR_CacheSave(Peer, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots))
		FileAppend(StrReplace(Tail, "dev-one", "dev-two"), Second, "UTF-8-RAW")
		CandidateSnapshots[Second] := KLR_LedgerSnapshot(Second)
		CandidateSizes[Second] := CandidateSnapshots[Second]["size"]
		AssertTrue(_KLR_CacheMustRetainPeer(CandidateSizes, CandidateSnapshots, _KLRDC_Root(), ""),
			"advancing one device cannot compensate for regressing another")
		CandidateSizes.Delete(_KLRDC_LedgerPath())
		CandidateSnapshots.Delete(_KLRDC_LedgerPath())
		AssertTrue(_KLR_CacheMustRetainPeer(CandidateSizes, CandidateSnapshots, _KLRDC_Root(), ""),
			"a candidate must not omit a peer's still-valid device")
		CandidateSizes[_KLRDC_LedgerPath()] := KLRCache.last_sizes[_KLRDC_LedgerPath()]
		CandidateSnapshots[_KLRDC_LedgerPath()] := KLRCache.ledger_snapshots[_KLRDC_LedgerPath()]
		AssertFalse(_KLR_CacheMustRetainPeer(CandidateSizes, CandidateSnapshots, _KLRDC_Root(), ""),
			"a candidate covering every peer offset remains publishable")
	} finally _KLRDC_Cleanup()
}
Test("KLR cache: publication order respects every device (klr-cache-publication-order)",
	_KLRDC_CheckTeardown.Bind(_KLRCPO_IncomparableDevices))
