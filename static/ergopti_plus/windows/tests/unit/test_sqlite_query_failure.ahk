; tests/unit/test_sqlite_query_failure.ahk

; ==============================================================================
; MODULE: SQLite Query Failure Tests
; DESCRIPTION:
; Failed reads must not publish partial rows, advance a typing projection, or
; admit an unreadable durable image as a successful empty metrics store.
; ==============================================================================

#Requires AutoHotkey v2.0

_SQLQF_ExpectFailure(Action) {
	Caught := 0
	try Action.Call()
	catch Error as Err
		Caught := Err
	AssertTrue(Caught is Error, "a failed query must not return a successful row array")
	AssertContains(Caught.Message, "SQLite",
		"the test must catch a SQLite failure, not a fixture error: " . Caught.Extra . " " . Caught.Stack)
	return Caught
}

_SQLQF_PartialRows(Db) {
	for Sql in ["SELECT 7 AS n UNION ALL SELECT abs(-9223372036854775808)",
		"SELECT * FROM missing_private_fixture", "SELECT abs(-9223372036854775808)"] {
		Err := _SQLQF_ExpectFailure(SQLite_Query.Bind(Db, Sql, 1))
		AssertFalse(InStr(Err.Message . Err.Extra, Sql), "diagnostics must not contain SQL payloads")
		_SQLRD_AssertNoStatements(Db)
		AssertEqual(1, SQLite_Query(Db, "SELECT 1 WHERE 1").Length)
	}
	AssertEqual(0, SQLite_Query(Db, "SELECT 1 WHERE 0").Length,
		"a successful empty result remains distinguishable from failure")
	AssertEqual(0, SQLite_Query(Db, "").Length)
}
Test("SQLite query: reject partial rows and preserve empty success (sqlite-query-failure)",
	() => _SQLRD_WithDatabase(_SQLQF_PartialRows))

_SQLQF_TypingProjection(Db) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	AssertTrue(SQLite_Exec(Db, "DROP TABLE events_typing;"))
	AssertFalse(KLR_PrepareTypingProjection(Db),
		"failed paging is not successful EOF and must reject the candidate")
	_SQLRD_AssertNoStatements(Db)
}
Test("SQLite query: typing paging rejects unreadable source (sqlite-query-failure)",
	() => _SQLRD_WithDatabase(_SQLQF_TypingProjection))

_SQLQF_Projection(Db, Table, Project) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	AssertTrue(SQLite_Exec(Db, "DROP TABLE " . Table . ";"))
	_SQLQF_ExpectFailure(() => Project.Call(Db))
	_SQLRD_AssertNoStatements(Db)
}
Test("SQLite query: manifest rejects missing hourly data (sqlite-query-failure)",
	() => _SQLRD_WithDatabase((Db) => _SQLQF_Projection(Db, "agg_app_day_hourly", KLR_ReadManifest)))
Test("SQLite query: ngrams reject missing source data (sqlite-query-failure)",
	() => _SQLRD_WithDatabase((Db) => _SQLQF_Projection(Db, "ngram_chars", KLR_ReadNgrams)))

_SQLQF_CacheLedger(Db) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		Root := _KLRDC_Root()
		Log := Root . "probe.log"
		AssertEqual(1, KLR_CacheSave(Db, Map(), Root, Log))
		Stored := SQLite_Open(KLR_CachePath(Root))
		AssertTrue(Stored != 0)
		try AssertTrue(SQLite_Exec(Stored, "DROP TABLE klr_cache_ledger;"))
		finally SQLite_Close(Stored)
		KLRCache.disposable := true
		AssertEqual(0, KLR_CacheAttach(Root, Log),
			"a missing ledger index is corruption, even with no device ledgers on disk")
		AssertEqual(0, KLRCache.db, "a rejected image must not transfer its handle")
		AssertFalse(FileExist(KLR_CachePath(Root)),
			"the rejected image must be closed before Windows removes it")
	} finally _KLRDC_Cleanup()
}
Test("SQLite query: unreadable ledger index cannot attach (sqlite-query-failure)",
	_KLRDC_CheckTeardown.Bind(() => _SQLRD_WithDatabase(_SQLQF_CacheLedger)))

_SQLQF_Publication() {
	global KLPF_LAST_JSON
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	try {
		KLRCache.disposable := true
		Root := _KLRDC_Root()
		Db := KLR_BuildDatabase(Root)
		AssertTrue(Db != 0, "the control must build a complete empty store")
		AssertTrue(SQLite_Exec(Db, "DROP TABLE agg_app_day_hourly;"))
		Path := Root . "last-good.json"
		FileAppend("last-good-file", Path, "UTF-8-RAW")
		CacheKey := KLPF_PrefetchPath("typing", Root)
		KLPF_LAST_JSON := Map(CacheKey, "last-good-memory")
		_SQLQF_ExpectFailure(() => KLPF_BuildAndWriteToPath(
			"typing", Root, Path, Root . "probe.log", "manifest"))
		AssertEqual("last-good-memory", KLPF_LAST_JSON[CacheKey])
		AssertEqual("last-good-file", FileRead(Path, "UTF-8-RAW"),
			"failed projection must not overwrite a previously published payload")
	} finally {
		if HadJson
			KLPF_LAST_JSON := SavedJson
		else
			KLPF_LAST_JSON := unset
		_KLRDC_Cleanup()
	}
}
Test("SQLite query: failed projection retains published JSON (sqlite-query-failure)",
	_KLRDC_CheckTeardown.Bind(_SQLQF_Publication))

_SQLQF_Walker(Db) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	AssertTrue(SQLite_Exec(Db, "DROP TABLE events_llm;"))
	SavedContext := KLW.ctx
	SavedBatch := KLW.batch
	AssertEqual(-1, KLR_RebuildWalkerAggregates(Db, true),
		"failed device enumeration must not become a successful zero-device replay")
	AssertTrue(KLW.ctx = SavedContext)
	AssertTrue(KLW.batch = SavedBatch)
	_SQLRD_AssertNoStatements(Db)
}
Test("SQLite query: failed device enumeration restores live walker (sqlite-query-failure)",
	() => _SQLRD_WithDatabase(_SQLQF_Walker))

_SQLQF_FailedRefresh() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Offset := _KLRDC_StoredOffset()
		_KLRDC_AppendLedger("`nBEGIN; DROP TABLE events_typing; COMMIT;`n")
		AssertEqual(0, KLR_BuildDatabase(_KLRDC_Root()),
			"a paging failure must retire the unpublished disposable candidate")
		AssertEqual(0, KLRCache.db)
		AssertEqual(Offset, _KLRDC_StoredOffset(),
			"failed paging must not advance the durable offset")
		Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
		AssertTrue(Stored != 0)
		try AssertEqual(1, SQLite_Query(Stored, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"],
			"failed candidate writes must not reach the last-good image")
		finally SQLite_Close(Stored)
	} finally _KLRDC_Cleanup()
}
Test("SQLite query: failed paging retires candidate without advancing offsets (sqlite-query-failure)",
	_KLRDC_CheckTeardown.Bind(_SQLQF_FailedRefresh))
