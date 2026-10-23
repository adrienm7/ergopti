; tests/unit/adapters/sqlite/test_sqlite_query_failure.ahk

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
		AssertEqual(1, KLR_CacheSave(Db, Map(), Root, Log, Map()))
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

_SQLQF_Publication(LateFailure := false, Mode := "manifest") {
	global KLPF_LAST_JSON, Features
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	SavedFeatures := Features
	try {
		Features := Map("layout", Map("ergopti_base", false))
		KLRCache.disposable := true
		Root := _KLRDC_Root()
		Db := KLR_BuildDatabase(Root)
		AssertTrue(Db != 0, "the control must build a complete empty store")
		if LateFailure {
			AssertTrue(SQLite_Exec(Db, "INSERT INTO agg_app_day_hourly_min5 "
				. "(device_id,date,app,slot,c,e,es,e_buckets_json) VALUES "
				. "('a','2026-01-01','fixture.exe','10:00',9223372036854775807,0,0,'{}'),"
				. "('b','2026-01-01','fixture.exe','10:00',1,0,0,'{}');"))
			AssertEqual(2, SQLite_Query(Db, "SELECT c FROM agg_app_day_hourly_min5;").Length,
				"individual rows must remain readable before their SUM overflows")
		} else {
			AssertTrue(SQLite_Exec(Db, "DROP TABLE agg_app_day_hourly;"))
		}
		Path := Root . "last-good.json"
		FileAppend("last-good-file", Path, "UTF-8-RAW")
		CacheKey := KLPF_PrefetchPath("typing", Root)
		KLPF_LAST_JSON := Map(CacheKey, "last-good-memory")
		; The maintainer chose to show what a refused query leaves readable: the
		; read is incomplete, flagged for the page, and never kept as a snapshot.
		Refused := 0
		AssertEqual("incomplete", KLPF_BuildAndWriteToPath(
			"typing", Root, Path, Root . "probe.log", Mode, , &Refused),
			"a refused aggregate query must yield a partial read, not a failed projection")
		AssertContains(KLR_DescribePartialRead(Refused), LateFailure ? "manifest/hourly_min5 rc=" : "manifest/hourly rc=",
			"the refusal must name its query and native code")
		AssertEqual("last-good-memory", KLPF_LAST_JSON[CacheKey],
			"a partial read must never replace the reusable RAM snapshot")
		Partial := JsonParse(FileRead(Path, "UTF-8-RAW"))
		AssertTrue(Partial.Get("metrics_manifest_incomplete", false) == true,
			"the partial manifest must carry the flag the shared page reads")
		AssertFalse(Partial.Has("__klpf_range_incomplete"), "internal transport fields cannot reach the page")
		_SQLRD_AssertNoStatements(Db)
		if Mode = "full" {
			; The reusable snapshot is every later open's first paint.
			Destination := KLPF_PrefetchPath("typing", Root)
			AssertFalse(FSExists(Destination), "the fixture must own the canonical snapshot")
			try {
				AssertTrue(FSWriteDurable(Destination, "last-good-file"))
				AssertFalse(KLPF_BuildAndWrite("typing", Root, Root . "probe.log", "full"),
					"an incomplete read must be refused as the published snapshot")
				AssertEqual("last-good-file", FileRead(Destination, "UTF-8-RAW"),
					"a partial read must not overwrite the published payload")
			} finally {
				if FSExists(Destination)
					AssertTrue(FSDelete(Destination))
			}
		}
		if LateFailure {
			AssertTrue(SQLite_Exec(Db, "DELETE FROM agg_app_day_hourly_min5 WHERE device_id='b';"
				. "UPDATE agg_app_day_hourly_min5 SET c=7;"))
			AssertEqual(true, KLPF_BuildAndWriteToPath("typing", Root, Path, Root . "probe.log", Mode),
				"a repaired aggregate must publish successfully through the same reader")
			Payload := JsonParse(FileRead(Path, "UTF-8-RAW"))
			AssertEqual(7, Payload["metrics_manifest"]["2026-01-01"]["fixture.exe"]["hourly_min5"]["10:00"]["c"],
				"recovery must publish the repaired count, not an empty success")
			AssertFalse(Payload.Has("metrics_manifest_incomplete"), "a complete read must not stay flagged")
		}
	} finally {
		Features := SavedFeatures
		if HadJson
			KLPF_LAST_JSON := SavedJson
		else
			KLPF_LAST_JSON := unset
		_KLRDC_Cleanup()
	}
}
Test("SQLite query: a refused projection query yields a flagged partial read (sqlite-query-failure)",
	_KLRDC_CheckTeardown.Bind(_SQLQF_Publication))
for Mode in ["manifest", "live", "full"]
	Test("SQLite query: late aggregate failure stays a partial read mode=" . Mode . " (sqlite-query-late-publication)",
		_KLRDC_CheckTeardown.Bind(_SQLQF_Publication.Bind(true, Mode)))

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

_SQLQF_PrivateDiagnostic(Db, Reader, StepFailure) {
	global _LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED
	SavedSink := _LOGGER_TEST_SINK
	SavedErrors := _LOGGER_ERROR_ENABLED
	Messages := []
	Sentinel := "synthetic_private_sql_marker"
	try {
		_LOGGER_ERROR_ENABLED := true
		LoggerSetTestSink((Line) => Messages.Push(Line))
		if StepFailure {
			AssertTrue(SQLite_Exec(Db, "CREATE TABLE privacy_probe (value TEXT);"
				. "CREATE TRIGGER privacy_reject BEFORE INSERT ON privacy_probe "
				. "BEGIN SELECT RAISE(ABORT," . SQLite_Q(Sentinel) . "); END;"))
			Sql := "INSERT INTO privacy_probe VALUES ('fixture');"
		} else {
			Sql := "SELECT 1 " . SQLite_Q(Sentinel) . " " . SQLite_Q(Sentinel) . ";"
		}
		Result := Reader ? SQLite_ExecReturnCarry(Db, Sql) : SQLite_Exec(Db, Sql)
		AssertFalse(Reader ? Result["ok"] : Result,
			"the native fixture must fail at its intended SQL boundary")
		NativeMessage := SQLite_Utf8ToStr(DllCall(SQLiteConst.DLL . "\sqlite3_errmsg", "Ptr", Db, "Ptr"))
		AssertContains(NativeMessage, Sentinel,
			"the native error must really carry the synthetic private payload")
		AssertTrue(Messages.Length > 0, "a rejected SQL operation must remain observable")
		for Line in Messages {
			AssertFalse(InStr(Line, Sentinel), "SQL diagnostics must not expose private native error text")
			AssertContains(Line, "rc=", "diagnostics must retain the native failure code")
		}
		AssertFalse(InStr(SQLite_LastError(Db), Sentinel),
			"the shared error accessor must also be safe for exception callers")
		AssertContains(SQLite_LastError(Db), StepFailure ? "rc=1811" : "rc=1",
			"the accessor must retain SQLITE_CONSTRAINT_TRIGGER or SQLITE_ERROR")
		AssertContains(SQLite_LastError(Db), StepFailure ? "constraint failed" : "SQL logic error",
			"a static SQLite description must keep the diagnostic useful")
		if Reader
			AssertFalse(InStr(Result["error"], Sentinel), "reader error receipts must not carry private text")
		_SQLRD_AssertNoStatements(Db)
		AssertEqual(1, SQLite_Query(Db, "SELECT 1;").Length,
			"failed diagnostics must not poison later reads")
	} finally {
		LoggerSetTestSink(SavedSink)
		_LOGGER_ERROR_ENABLED := SavedErrors
	}
}

for Reader in [false, true]
	for StepFailure in [false, true]
		Test("SQLite diagnostics: redact native payload reader=" . Reader . " step=" . StepFailure . " (sqlite-private-diagnostics)",
			_SQLRD_WithDatabase.Bind(_SQLQF_PrivateDiagnostic.Bind(, Reader, StepFailure)))

; A worker defers its reader image save until its read is known. A partial read
; is written for its window with both incomplete flags and keeps the counts that
; were answered, but neither the RAM snapshot nor the durable reader cache may
; keep it; the next worker reads everything again, then caches it unflagged.
_SQLQF_IncompleteReadIsNotCached() {
	global KLPF_LAST_JSON, Features
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	SavedFeatures := Features
	try {
		Features := Map("layout", Map("ergopti_base", false))
		KLPF_LAST_JSON := Map()
		Root := _KLRDC_Root()
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "code.exe", ["a", "b", "c"]))
		CacheKey := KLPF_PrefetchPath("typing", Root)
		Path := Root . "stage.json"
		for Attempt in ["partial", "complete"] {
			; Each attempt is a fresh worker, as KLPF_WorkerMain declares it.
			KLR_ResetCache()
			KLRCache.disposable := true
			KLRCache.defer_saves := true
			Db := KLR_BuildDatabase(Root)
			AssertTrue(Db != 0, "the fixture ledger must produce a reader database")
			if Attempt = "partial"
				AssertTrue(SQLite_Exec(Db, "DROP TABLE agg_app_day_titles; DROP TABLE ngram_bigrams;"),
					"the fixture must make one manifest and one n-gram query refuse")
			Refused := 0
			Outcome := KLPF_BuildAndWriteToPath("typing", Root, Path, Root . "probe.log", "full", , &Refused)
			Payload := JsonParse(FileRead(Path, "UTF-8-RAW"))
			AssertEqual(3, Payload["metrics_manifest"]["2026-01-01"]["code.exe"]["chars"],
				Attempt . ": the counts SQLite answered must be shown")
			AssertEqual(1, Payload["_prefetch_data"]["historical"]["c"]["a"]["c"],
				Attempt . ": the n-gram tables SQLite answered must be shown")
			if Attempt = "partial" {
				AssertEqual("incomplete", Outcome, "a refused query must make the read incomplete")
				AssertEqual("manifest/titles rc=1, range/historical bg rc=1, range/today bg rc=1",
					KLR_DescribePartialRead(Refused), "each refused query must be named once")
				AssertTrue(Payload.Get("metrics_manifest_incomplete", false) == true,
					"the manifest part must carry its incomplete flag")
				AssertTrue(Payload["_prefetch_data"].Get("incomplete", false) == true,
					"the n-gram part must carry its incomplete flag")
				AssertFalse(KLPF_LAST_JSON.Has(CacheKey), "a partial read must never become the RAM snapshot")
				AssertFalse(FSExists(KLR_CachePath(Root)),
					"a partial read must not persist the reader cache the next worker would start from")
				AssertFalse(KLRCache.deferred_save is Map, "the deferred save must be dropped, not kept")
			} else {
				AssertEqual(true, Outcome, "the retried read must be complete")
				AssertEqual(0, Refused.Length)
				AssertFalse(Payload.Has("metrics_manifest_incomplete"), "a complete manifest must not be flagged")
				AssertFalse(Payload["_prefetch_data"].Has("incomplete"), "complete n-grams must not be flagged")
				AssertTrue(KLPF_LAST_JSON.Has(CacheKey), "a complete read is the reusable RAM snapshot")
				AssertTrue(FSExists(KLR_CachePath(Root)), "a complete read must persist the reader cache")
			}
		}
	} finally {
		Features := SavedFeatures
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		_KLRDC_Cleanup()
	}
}
Test("metrics worker: a partial read is shown flagged and never cached (windows-metrics-incomplete-read)",
	_KLRDC_CheckTeardown.Bind(_SQLQF_IncompleteReadIsNotCached))

; The partial-read scope must never nest and must tolerate only read refusals.
_SQLQF_PartialScope(Db) {
	AssertThrows(() => KLR_EndPartialRead(), "closing an unopened read must fail")
	KLR_BeginPartialRead()
	try {
		AssertThrows(() => KLR_BeginPartialRead(), "a partial read must not nest")
		AssertEqual(0, KLR_ProjectionQuery(Db, "SELECT * FROM missing_private_fixture", "range", "probe").Length)
		AssertThrows(() => KLR_PartialStep("manifest", "defect", () => Integer("not a number"), []),
			"a defect must stay fatal inside a partial read")
	} finally Refused := KLR_EndPartialRead()
	AssertEqual("range/probe rc=1", KLR_DescribePartialRead(Refused))
	AssertTrue(KLR_PartialReadMissed(Refused, "range"))
	AssertFalse(KLR_PartialReadMissed(Refused, "manifest"))
	_SQLQF_ExpectFailure(SQLite_Query.Bind(Db, "SELECT * FROM missing_private_fixture"))
	_SQLQF_ExpectFailure(() => KLR_ProjectionQuery(Db, "SELECT * FROM missing_private_fixture", "range", "probe"))
	_SQLRD_AssertNoStatements(Db)
}
Test("metrics worker: the partial read scope tolerates only refused reads (windows-metrics-incomplete-read)",
	() => _SQLRD_WithDatabase(_SQLQF_PartialScope))
