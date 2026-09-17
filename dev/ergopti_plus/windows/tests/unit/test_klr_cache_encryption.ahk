; tests/unit/test_klr_cache_encryption.ahk

; ==============================================================================
; MODULE: Reader Cache Encryption Tests
; DESCRIPTION: Derived files must not persist decrypted ordered typing events.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCE_PublishedCache(Scenario := 0) {
	global KL_ENC_Enabled, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
	global KL_ENC_MachineIdOverride, KL_ENC_MachineIdOverrideActive
	Saved := [Keylogger.device_id, Keylogger._device_id_lit, KL_ENC_Enabled,
		KL_ENC_KeyBuffer, KL_ENC_DerivationFailed, KL_ENC_MachineIdOverride, KL_ENC_MachineIdOverrideActive]
	Stored := 0
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Keylogger.device_id := "dev-one"
		Keylogger._device_id_lit := "'dev-one'"
		KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000004")
		KL_Enc_SetEnabled(true)
		Entry := Map("type", "typing", "timestamp", "2026-01-01 10:00:00.000",
			"app", "fixture.exe", "title", "Cache cipher fixture", "layout", "fr",
			"pause_before_ms", 0, "text", "ab", "events",
			[["a", 25, Map("kc", 65, "sk", 30)], ["b", 30, Map("kc", 66, "sk", 48)]])
		Sql := KL_BuildInsertTyping(Entry, 1)
		AssertContains(Sql, "ergopti-enc-v1:", "the fixture must use the real encrypted writer")
		_KLRDC_WriteLedger(_KLRDC_Header() . "BEGIN;" . Sql . "COMMIT;`n")
		Db := _KLRDC_BuildAsWorker()
		AssertEqual(2, SQLite_Query(Db, "SELECT chars FROM agg_app_day;")[1]["chars"],
			"encrypted source events must produce the real clear aggregate")
		AssertEqual(2, SQLite_Query(Db, "PRAGMA temp_store;")[1]["temp_store"],
			"temporary projection storage must stay in memory")
		AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM temp.klr_reader_typing_payload;")[1]["n"],
			"the successful projection must actually contain decrypted events in memory")
		Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
		AssertTrue(Stored != 0, "the worker must publish an actual derived image")
		Rows := SQLite_Query(Stored, "SELECT events_json FROM events_typing;")
		AssertEqual(1, Rows.Length)
		AssertTrue(KL_Enc_IsEncrypted(Rows[1]["events_json"]), "the cached raw row must retain its cipher envelope")
		AssertEqual(2, SQLite_Query(Stored, "SELECT chars FROM agg_app_day;")[1]["chars"])
		Tables := SQLite_Query(Stored,
			"SELECT name FROM sqlite_schema WHERE type='table' AND name='klr_reader_typing_payload';")
		if Tables.Length {
			ClearRows := SQLite_Query(Stored,
				"SELECT COUNT(*) AS n FROM klr_reader_typing_payload WHERE json_valid(events_json);")
			AssertEqual(0, ClearRows[1]["n"],
				"publishing an encrypted ledger cache must not persist its decrypted ordered events")
		}
		SQLite_Close(Stored)
		Stored := 0
		if IsObject(Scenario)
			Scenario.Call(Db, Entry)
	} finally {
		try {
			SQLite_Close(Stored)
			_KLRDC_Cleanup()
		} finally {
			Keylogger.device_id := Saved[1]
			Keylogger._device_id_lit := Saved[2]
			KL_ENC_Enabled := Saved[3]
			KL_ENC_KeyBuffer := Saved[4]
			KL_ENC_DerivationFailed := Saved[5]
			KL_ENC_MachineIdOverride := Saved[6]
			KL_ENC_MachineIdOverrideActive := Saved[7]
		}
	}
}
Test("KLR cache: encrypted ledgers never publish clear ordered events (klr-cache-encryption)",
	_KLRDC_CheckTeardown.Bind(_KLRCE_PublishedCache))

_KLRCE_WarmScope(Db, Entry) {
	KLR_ResetCache()
	Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()))
	AssertTrue(Stored != 0)
	try {
		; Unaffected history already has validated aggregates and numeric counts.
		; A poisoned old envelope detects any unnecessary historical decryption.
		AssertTrue(SQLite_Exec(Stored, "UPDATE events_typing SET events_json='ergopti-enc-v1:invalid';"))
	} finally SQLite_Close(Stored)
	Entry["timestamp"] := "2026-01-02 10:00:00.000"
	_KLRDC_AppendLedger("BEGIN;" . KL_BuildInsertTyping(Entry, 2) . "COMMIT;`n")
	Warm := _KLRDC_BuildAsWorker()
	Rows := SQLite_Query(Warm, "SELECT date,chars FROM agg_app_day ORDER BY date;")
	AssertEqual(2, Rows.Length)
	AssertEqual(2, Rows[1]["chars"])
	AssertEqual(2, Rows[2]["chars"])
	Payloads := SQLite_Query(Warm, "SELECT event_id FROM temp.klr_reader_typing_payload;")
	AssertEqual(1, Payloads.Length, "warm replay must decrypt only the affected date")
	AssertEqual(2, Payloads[1]["event_id"])
	AssertEqual(2, SQLite_Query(Warm, "SELECT COUNT(*) AS n FROM klr_reader_typing_counts;")[1]["n"],
		"numeric history must survive the main-only clone")
}
Test("KLR cache: warm encrypted replay excludes unaffected history (klr-cache-encryption)",
	_KLRDC_CheckTeardown.Bind(_KLRCE_PublishedCache.Bind(_KLRCE_WarmScope)))

_KLRCE_MixedEncryption(Db, Entry) {
	KL_Enc_SetEnabled(false)
	PlainSql := KL_BuildInsertTyping(Entry, 2)
	AssertFalse(InStr(PlainSql, "ergopti-enc-v1:"), "disabled encryption must produce a clear fixture row")
	_KLRDC_AppendLedger("BEGIN;" . PlainSql . "COMMIT;`n")
	Mixed := _KLRDC_BuildAsWorker()
	AssertEqual(4, SQLite_Query(Mixed, "SELECT chars FROM agg_app_day;")[1]["chars"],
		"disabled encryption must still replay the older encrypted row on the affected day")
	AssertEqual(2, SQLite_Query(Mixed, "SELECT COUNT(*) AS n FROM temp.klr_reader_typing_payload;")[1]["n"],
		"both clear and encrypted rows must reach the same replay projection")
	KL_Enc_SetEnabled(true)
	Entry["timestamp"] := "2026-01-02 10:00:00.000"
	EncryptedSql := KL_BuildInsertTyping(Entry, 3)
	AssertContains(EncryptedSql, "ergopti-enc-v1:", "reenabling encryption must protect the new row")
	_KLRDC_AppendLedger("BEGIN;" . EncryptedSql . "COMMIT;`n")
	Warm := _KLRDC_BuildAsWorker()
	CountsSql := "SELECT date,chars FROM agg_app_day ORDER BY date;"
	Counts := SQLite_Query(Warm, CountsSql)
	AssertEqual(2, Counts.Length)
	AssertEqual(4, Counts[1]["chars"], "unaffected mixed history must survive the next encrypted tail")
	AssertEqual(2, Counts[2]["chars"])
	NgramsSql := "SELECT date,app,token,c,td,cd,e,esrc_json FROM ngram_chars ORDER BY date,app,token;"
	WarmNgrams := SQLite_Query(Warm, NgramsSql)
	AssertTrue(WarmNgrams.Length > 0, "the comparison must cover real walker output")
	KLR_ResetCache()
	FileDelete(KLR_CachePath(_KLRDC_Root()))
	Cold := _KLRDC_BuildAsWorker()
	AssertEqual(KL_JsonEncode(Counts), KL_JsonEncode(SQLite_Query(Cold, CountsSql)),
		"full replay must preserve counts across both encryption transitions")
	AssertEqual(KL_JsonEncode(WarmNgrams), KL_JsonEncode(SQLite_Query(Cold, NgramsSql)),
		"mixed-history n-grams must match independent cold replay")
}
Test("KLR cache: encryption toggles preserve mixed-history replay (klr-cache-encryption-toggle)",
	_KLRDC_CheckTeardown.Bind(_KLRCE_PublishedCache.Bind(_KLRCE_MixedEncryption)))

_KLRCE_RejectOldImage(Db, Entry) {
	KLR_ResetCache()
	Path := KLR_CachePath(_KLRDC_Root())
	Stored := SQLite_Open(Path)
	AssertTrue(Stored != 0)
	try AssertTrue(SQLite_Exec(Stored,
		"UPDATE klr_cache_meta SET value='3' WHERE key='format_version';"
		. "CREATE TABLE klr_reader_typing_payload(events_json TEXT);"
		. "INSERT INTO klr_reader_typing_payload VALUES('[[],[]]');"))
	finally SQLite_Close(Stored)
	KLRCache.disposable := true
	AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), ""), "the old clear-bearing format must not attach")
	AssertFalse(FSExists(Path), "the rejected image must close before it is removed")
	Rebuilt := _KLRDC_BuildAsWorker()
	AssertEqual(2, SQLite_Query(Rebuilt, "SELECT chars FROM agg_app_day;")[1]["chars"],
		"rejecting the cache must not lose the authoritative encrypted history")
}
Test("KLR cache: obsolete clear-bearing images are discarded before rebuilding (klr-cache-encryption)",
	_KLRDC_CheckTeardown.Bind(_KLRCE_PublishedCache.Bind(_KLRCE_RejectOldImage)))

_KLRCE_AssertNoStages() {
	Count := 0
	loop files KLR_CachePath(_KLRDC_Root()) . ".stage.*", "F"
		Count += 1
	AssertEqual(0, Count, "failed publication must not leave owned staging files")
}

_KLRCE_FailedPublication(Db, Entry) {
	AssertTrue(KLR_CacheEnsureTables(Db))
	AssertTrue(SQLite_Exec(Db, "CREATE TRIGGER reject_cache_meta BEFORE INSERT ON klr_cache_meta "
		. "BEGIN SELECT RAISE(ABORT,'fixture metadata rejected'); END;"))
	AssertFalse(KLR_CacheSave(Db, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots))
	_KLRCE_AssertNoStages()
	AssertTrue(SQLite_Exec(Db, "DROP TRIGGER reject_cache_meta;"))
	AssertTrue(KLR_CacheSave(Db, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots),
		"removing the copied trigger must make the same publication succeed")
	Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
	AssertTrue(Stored != 0)
	try {
		AssertEqual(0, SQLite_Query(Stored,
			"SELECT COUNT(*) AS n FROM sqlite_schema WHERE name='klr_reader_typing_payload';")[1]["n"])
		AssertEqual(2, SQLite_Query(Stored, "SELECT chars FROM agg_app_day;")[1]["chars"])
	} finally SQLite_Close(Stored)
}
Test("KLR cache: rejected metadata publication cleans its stage and remains retryable (klr-cache-encryption)",
	_KLRDC_CheckTeardown.Bind(_KLRCE_PublishedCache.Bind(_KLRCE_FailedPublication)))

_KLRCE_UnsafeSource(Db, Entry, TableName := "klr_reader_typing_payload") {
	AssertTrue(SQLite_Exec(Db, "CREATE TABLE main." . TableName . "(events_json TEXT);"
		. "INSERT INTO main.klr_reader_typing_payload VALUES('[[],[]]');"))
	AssertFalse(KLR_CacheSave(Db, KLRCache.last_sizes, _KLRDC_Root(), "", KLRCache.ledger_snapshots),
		"a legacy main-schema payload must be refused before any backup")
	_KLRCE_AssertNoStages()
	Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
	AssertTrue(Stored != 0)
	try AssertEqual(0, SQLite_Query(Stored,
		"SELECT COUNT(*) AS n FROM sqlite_schema WHERE name='klr_reader_typing_payload' COLLATE NOCASE;")[1]["n"],
		"refusing an unsafe source must preserve the prior safe image")
	finally SQLite_Close(Stored)
}
Test("KLR cache: main-schema ordered payloads cannot enter publication (klr-cache-encryption)",
	_KLRDC_CheckTeardown.Bind(_KLRCE_PublishedCache.Bind(_KLRCE_UnsafeSource)))

for TableName in ["KLR_READER_TYPING_PAYLOAD", "Klr_Reader_Typing_Payload"]
	Test("KLR cache: unsafe table spelling=" . TableName . " refuses publication (klr-cache-payload-case)",
		_KLRDC_CheckTeardown.Bind(_KLRCE_PublishedCache.Bind(_KLRCE_UnsafeSource.Bind(, , TableName))))

_KLRCE_UnsafeStoredImage(Db, Entry, Worker) {
	Path := KLR_CachePath(_KLRDC_Root())
	Stored := SQLite_Open(Path)
	AssertTrue(Stored != 0)
	try AssertTrue(SQLite_Exec(Stored,
		"CREATE TABLE main.KLR_READER_TYPING_PAYLOAD(events_json TEXT);"
		. "INSERT INTO main.klr_reader_typing_payload VALUES('[[],[]]');"))
	finally SQLite_Close(Stored)
	KLR_ResetCache()
	KLRCache.disposable := Worker
	AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), ""), "an unsafe existing image must not be admitted")
	AssertEqual(0, KLRCache.db, "neither resident copying nor readonly transfer may expose the rejected image")
	AssertFalse(FSExists(Path), "the observed unsafe derived image must be retired after closing SQLite")
	Recovered := KLR_BuildDatabase(_KLRDC_Root())
	AssertTrue(Recovered != 0)
	AssertEqual(2, SQLite_Query(Recovered, "SELECT chars FROM agg_app_day;")[1]["chars"],
		"rejection must allow reconstruction from the encrypted synthetic ledger")
	AssertEqual(0, SQLite_Query(Recovered,
		"SELECT COUNT(*) AS n FROM main.sqlite_schema WHERE name='klr_reader_typing_payload' COLLATE NOCASE;")[1]["n"])
}
for Worker in [false, true]
	Test("KLR cache: unsafe stored image worker=" . Worker . " is rejected (klr-cache-payload-admission)",
		_KLRDC_CheckTeardown.Bind(_KLRCE_PublishedCache.Bind(_KLRCE_UnsafeStoredImage.Bind(, , Worker))))
