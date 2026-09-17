; tests/unit/test_klr_ledger_read_refusal.ahk

; ==============================================================================
; MODULE: Ledger Read Refusal Tests
; DESCRIPTION: A native byte-lock refusal must not publish a truncated cold image.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRLR_ColdReadRefusal(Cold) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Probe := Map("file", 0, "locked", false, "page_size", 1, "overlap", Buffer(32, 0))
	Candidate := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		Path := _KLRDC_LedgerPath()
		Before := KLR_LedgerSnapshot(Path)
		Probe["file"] := FileOpen(Path, "r")
		Probe["locked"] := DllCall("Kernel32\LockFileEx", "Ptr", Probe["file"].Handle,
			"UInt", 3, "UInt", 0, "UInt", 1, "UInt", 0, "Ptr", Probe["overlap"], "Int")
		AssertTrue(Probe["locked"], "the fixture must refuse native reads of the first byte")
		try {
			Result := Cold ? KLR_BuildColdCandidate(_KLRDC_Root(), "") : KLR_ReadLedgerTail(Path, 0)
			Candidate := Result.Get("db", 0)
			AssertFalse(Result["ok"], "a refused ledger read must not become a successful empty result")
		} finally _KLRCC_ReleaseLock(Probe)
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
		Result := KLR_BuildColdCandidate(_KLRDC_Root(), "")
		Candidate := Result.Get("db", 0)
		AssertTrue(Result["ok"], "the same journal must recover after the native lock is released")
		AssertEqual(1, SQLite_Query(Candidate, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"])
	} finally {
		SQLite_Close(Candidate)
		_KLRCC_ReleaseLock(Probe)
		_KLRDC_Cleanup()
	}
}
for Cold in [true, false]
	Test("KLR reader: native byte-lock refusal cannot become EOF cold=" . Cold . " (klr-ledger-read-refusal)",
		_KLRDC_CheckTeardown.Bind(_KLRLR_ColdReadRefusal.Bind(Cold)))

_KLRLR_NativeNulHole(Leading) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Candidate := 0
	Writer := 0
	try {
		First := _KLRDC_Header() . _KLRDC_TypingBatch(9,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"])
		Second := _KLRDC_TypingBatch(3,
			"2026-01-01 10:00:01.000", "2026-01-01", "fixture.exe", ["b"])
		_KLRDC_WriteLedger(Leading ? "" : First)
		Path := _KLRDC_LedgerPath()
		Writer := FileOpen(Path, "a", "UTF-8-RAW")
		AssertEqual(4, Writer.RawWrite(Buffer(4, 0)))
		Writer.Close()
		Writer := 0
		FileAppend((Leading ? First : "") . Second, Path, "UTF-8-RAW")
		Before := KLR_LedgerSnapshot(Path)
		Tail := KLR_ReadLedgerTail(Path, 0)
		AssertTrue(Tail["ok"])
		AssertEqual(FileGetSize(Path), Tail["end_offset"])
		Dates := KLR_CacheAffectedDates(Map(Path, Tail))
		AssertEqual(1, Dates.Length, "the incremental date scanner must also see past the hole")
		AssertEqual("2026-01-01", Dates[1])
		Reader := FileOpen(Path, "r", "UTF-8")
		try {
			Chunk := KLR_ReadStableLedgerChunk(Reader, Path, 4)
			AssertTrue(Chunk["ok"], "a bounded NUL chunk must not be confused with read refusal")
			AssertEqual(4, StrLen(Chunk["text"]))
		} finally Reader.Close()
		Result := KLR_BuildColdCandidate(_KLRDC_Root(), "")
		Candidate := Result.Get("db", 0)
		AssertTrue(Result["ok"], "native NUL holes must preserve the parser's recovery contract")
		AssertEqual(2, SQLite_Query(Candidate, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		AssertEqual(2, SQLite_Query(Candidate, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"])
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
	} finally {
		if IsObject(Writer)
			Writer.Close()
		SQLite_Close(Candidate)
		_KLRDC_Cleanup()
	}
}
for Leading in [true, false]
	Test("KLR reader: native NUL hole leading=" . Leading . " retains all events (klr-ledger-native-nul)",
		_KLRDC_CheckTeardown.Bind(_KLRLR_NativeNulHole.Bind(Leading)))

_KLRLR_IncrementalNulHole() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Writer := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(9,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Db := _KLRDC_BuildAsWorker()
		AssertTrue(KLRCache.readonly, "the unchanged worker must attach the durable image")
		AssertEqual(1, DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly",
			"Ptr", Db, "AStr", "main", "Int"))
		Path := _KLRDC_LedgerPath()
		OldOffset := KLRCache.last_sizes[Path]
		Writer := FileOpen(Path, "a", "UTF-8-RAW")
		AssertEqual(4, Writer.RawWrite(Buffer(4, 0)))
		Writer.Close()
		Writer := 0
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(3,
			"2026-01-02 10:00:00.000", "2026-01-02", "fixture.exe", ["b", "c"]))
		Before := KLR_LedgerSnapshot(Path)
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0)
		AssertFalse(KLRCache.readonly, "the readonly image must yield an incremental candidate")
		AssertEqual(2, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		Rows := SQLite_Query(Db, "SELECT date,chars FROM agg_app_day ORDER BY date;")
		AssertEqual(2, Rows.Length, "a lower-ID tail behind NUL must create its affected day")
		AssertEqual("2026-01-01", Rows[1]["date"])
		AssertEqual(1, Rows[1]["chars"], "the untouched day must remain intact")
		AssertEqual("2026-01-02", Rows[2]["date"])
		AssertEqual(2, Rows[2]["chars"])
		AssertEqual(2, SQLite_Query(Db, "SELECT longest_chars FROM agg_app_day_session"
			. " WHERE date='2026-01-02';")[1]["longest_chars"],
			"the affected day must also rebuild walker-owned metrics")
		AssertTrue(KLRCache.last_sizes[Path] > OldOffset)
		AssertEqual(FileGetSize(Path), KLRCache.last_sizes[Path])
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
	} finally {
		if IsObject(Writer)
			Writer.Close()
		_KLRDC_Cleanup()
	}
}
Test("KLR reader: incremental NUL tail preserves raw and derived rows (klr-ledger-incremental-nul)",
	_KLRDC_CheckTeardown.Bind(_KLRLR_IncrementalNulHole))
