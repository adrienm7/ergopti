; tests/unit/modules/keystats/test_keystats_full_id_recovery.ahk

; ==============================================================================
; MODULE: Full Historical Identity Recovery Tests
; DESCRIPTION: Missing state cannot hide older high IDs outside the SQL tail.
; ==============================================================================

#Requires AutoHotkey v2.0

_KFIR_OutOfOrderHistory() {
	Path := _FSWL_Path()
	Db := _WJFM_OpenMemory()
	try {
		Sql := "INSERT OR IGNORE INTO events_typing VALUES ('device-a',10000,'highest');`n"
			. "INSERT OR IGNORE INTO events_typing VALUES ('device-a',1001,'existing');`n"
		loop 1000
			Sql .= "INSERT OR IGNORE INTO events_typing VALUES ('device-a'," . A_Index
				. ",'" . Format("{:200}", "synthetic") . "');`n"
		FileAppend(Sql, Path, "UTF-8-RAW")
		Before := KLR_LedgerSnapshot(Path)
		Tail := _KL_ReadRecoveryText(Path, 0, KeystatsConst.DATA_SQL_SCAN_TAIL_BYTES)
		AssertEqual(1000, KL_ScanMaxEventId(Tail, "'device-a'"), "the old high ID must be outside the ordinary tail")
		Recovered := KL_ResolveStartId(1, KL_RecoverSqlEventId(Path, "'device-a'"))
		AssertEqual(10001, Recovered)
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
		AssertTrue(SQLite_Exec(Db, "CREATE TABLE events_typing(device_id TEXT,id INTEGER,text TEXT,PRIMARY KEY(device_id,id));"))
		AssertTrue(SQLite_Exec(Db, Sql))
		AssertTrue(SQLite_Exec(Db, "INSERT OR IGNORE INTO events_typing VALUES ('device-a',"
			. Recovered . ",'new event');"))
		AssertEqual(1, SQLite_Query(Db, "SELECT changes() AS n;")[1]["n"],
			"recovery must allocate an ID SQLite will actually insert")
	} finally {
		SQLite_Close(Db)
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keystats: full recovery preserves IDs outside an out-of-order tail (full-id-recovery)",
	_KFIR_OutOfOrderHistory)

_KFIR_ChunkBoundaries() {
	Path := _FSWL_Path()
	try {
		Writer := FileOpen(Path, "w", "UTF-8-RAW")
		try AssertEqual(4, Writer.RawWrite(Buffer(4, 0)))
		finally Writer.Close()
		Sql := "VALUES ('dev-é'," . Format("{:4096}", "") . Format("{:04096}", 0) . "12345);`n"
			. "VALUES ('other',999999);`nVALUES ('dev-é',234);`nVALUES ('dev-é',0007"
		FileAppend(Sql, Path, "UTF-8-RAW")
		for Size in [7, 31, KeystatsConst.DATA_SQL_SCAN_TAIL_BYTES]
			AssertEqual(12345, KL_RecoverSqlEventId(Path, "'dev-é'", Size),
				"markers, UTF-8, whitespace, zero runs and IDs must survive chunk boundaries")
		AssertEqual(0, KL_RecoverSqlEventId(Path, "'missing'", 31))
		AssertThrows(() => KL_RecoverSqlEventId(Path, "'dev-é'", 0))
		AssertThrows(() => _KL_RecoveryDecimalId("9223372036854775808"),
			"overflow cannot wrap a historical identity into a smaller allocation range")
		FileDelete(Path)
		AssertEqual(0, KL_RecoverSqlEventId(Path, "'dev-é'"))
		FileAppend("", Path, "UTF-8")
		AssertEqual(0, KL_RecoverSqlEventId(Path, "'dev-é'"))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keystats: historical recovery retains bounded token fragments (full-id-recovery)",
	_KFIR_ChunkBoundaries)

_KFIR_StateCounterValidity() {
	Path := _FSWL_Path()
	HadPath := Keystats.HasOwnProp("state_json_path")
	SavedPath := HadPath ? Keystats.state_json_path : ""
	SavedCounter := Keystats.next_event_id
	HadOffset := Keystats.HasOwnProp("today_log_offset")
	SavedOffset := HadOffset ? Keystats.today_log_offset : 0
	try {
		Keystats.state_json_path := Path
		Keystats.next_event_id := 77
		AssertFalse(KL_LoadState(), "missing state cannot authorize tail-only recovery")
		for Source in ["broken", "{}", '{"next_event_id":0}', '{"next_event_id":-1}',
			'{"next_event_id":1.5}', '{"next_event_id":"42"}',
			'{"next_event_id":0,"today_log_offset":4096}'] {
			FileAppend(Source, Path, "UTF-8-RAW")
			AssertFalse(KL_LoadState(), "invalid allocation counters require historical recovery")
			AssertEqual(77, Keystats.next_event_id)
			AssertEqual(HadOffset, Keystats.HasOwnProp("today_log_offset"))
			if HadOffset
				AssertEqual(SavedOffset, Keystats.today_log_offset,
					"an invalid allocation state cannot hide journal entries behind its offset")
			FileDelete(Path)
		}
		FileAppend('{"next_event_id":42}', Path, "UTF-8-RAW")
		AssertTrue(KL_LoadState(), "a native positive integer counter keeps ordinary recovery bounded")
		AssertEqual(42, Keystats.next_event_id)
	} finally {
		if HadPath
			Keystats.state_json_path := SavedPath
		else
			Keystats.DeleteProp("state_json_path")
		Keystats.next_event_id := SavedCounter
		if HadOffset
			Keystats.today_log_offset := SavedOffset
		else if Keystats.HasOwnProp("today_log_offset")
			Keystats.DeleteProp("today_log_offset")
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keystats: state validity selects exceptional identity recovery (full-id-recovery)",
	_KFIR_StateCounterValidity)

_KFIR_StateFieldsAtomic(Source, Valid := false, ExpectedDate := "2026-09-11") {
	Path := _FSWL_Path()
	Saved := Map()
	for Name in ["state_json_path", "next_event_id", "today_log_offset", "today_log_date"] {
		if Keystats.HasOwnProp(Name)
			Saved[Name] := Keystats.%Name%
	}
	try {
		Keystats.state_json_path := Path
		Keystats.next_event_id := 77
		Keystats.today_log_offset := 0
		Keystats.today_log_date := "2026-09-12"
		FileAppend(Source, Path, "UTF-8-RAW")
		Before := KLR_LedgerSnapshot(Path)
		AssertEqual(Valid, KL_LoadState(), "invalid checkpoints must select exceptional recovery")
		AssertEqual(Valid ? 42 : 77, Keystats.next_event_id,
			"rejected state must not partially publish its allocation counter")
		AssertEqual(Valid ? 4 : 0, Keystats.today_log_offset,
			"rejected state must not change the journal checkpoint")
		AssertEqual(Valid ? ExpectedDate : "2026-09-12", Keystats.today_log_date)
		AssertEqual(Source, FileRead(Path, "UTF-8"))
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
	} finally {
		for Name in ["state_json_path", "next_event_id", "today_log_offset", "today_log_date"] {
			if Saved.Has(Name)
				Keystats.%Name% := Saved[Name]
			else if Keystats.HasOwnProp(Name)
				Keystats.DeleteProp(Name)
		}
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Offset in ["-1", "1.5", '"4"', '"invalid"', "{}"]
	Test("keystats: reject checkpoint " . Offset . " atomically (state-fields-atomic)",
		_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":' . Offset . '}'))
for Date in ["{}", "42"]
	Test("keystats: reject date type " . Date . " atomically (state-fields-atomic)",
		_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":4,"today_log_date":' . Date . '}'))
Test("keystats: restore valid checkpoint fields together (state-fields-atomic)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":4,"today_log_date":"2026-09-11"}', true))

_KFIR_StateDate(Date, Valid) {
	Source := KL_JsonEncode(Map("next_event_id", 42, "today_log_offset", 4, "today_log_date", Date))
	_KFIR_StateFieldsAtomic(Source, Valid, Date)
	Receipt := Map("version", 1, "date", Date, "snapshot", Map("present", 0))
	AssertEqual(Valid && Date != "", _KL_RolloverReceiptValid(Receipt, 0),
		"rotation receipts share calendar validation but cannot have an uninitialized date")
}
for Date in ["not-a-date", "2026-02-30", "2025-02-29", "1900-02-29", "2026-00-01",
	"2026-13-01", "2026-09-00", "2026-09-31", "20260912", "2026-9-12",
	"2026-09-12`nINVALID SQL", "2026-09-12`n"]
	Test("keystats: reject noncanonical date case " . A_Index . " (state-calendar-validation)",
		_KFIR_StateDate.Bind(Date, false))
for Date in ["", "2024-02-29", "2000-02-29", "2026-09-12"]
	Test("keystats: preserve valid date case " . A_Index . " (state-calendar-validation)",
		_KFIR_StateDate.Bind(Date, true))

; Write the JSON escapes directly: the input boundary under test is decoding,
; not whether an encoder preserves a leading NUL in an in-memory string.
for JsonDate in ['"\u0000"', '"\u0000hidden"', '"2026-09-12\u0000"']
	Test("keystats: reject NUL date case " . A_Index . " (state-calendar-nul)",
		_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":4,"today_log_date":' . JsonDate . '}'))

Test("keystats: reject nonnumeric state counter-boolean (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":true,"today_log_offset":4}'))
Test("keystats: reject nonnumeric state counter-final-boolean (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"next_event_id":true,"today_log_offset":4}'))
Test("keystats: reject nonnumeric state counter-escaped-boolean (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_\u0069d":true,"today_log_offset":4}'))
Test("keystats: reject nonnumeric state counter-final-escaped-boolean (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"next_event_\u0069d":true,"today_log_offset":4}'))
Test("keystats: reject nonnumeric state offset-true (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":true}'))
Test("keystats: reject nonnumeric state offset-false (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":false}'))
Test("keystats: reject nonnumeric state offset-final-boolean (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":4,"today_log_offset":true}'))
Test("keystats: reject nonnumeric state offset-escaped-boolean (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_\u006fffset":true}'))
Test("keystats: reject nonnumeric state offset-final-escaped-boolean (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":4,"today_log_\u006fffset":false}'))
Test("keystats: preserve canonical numeric state counter-final-number (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":true,"next_event_id":42,"today_log_offset":4,"today_log_date":"2026-09-11"}', true))
Test("keystats: preserve canonical numeric state offset-final-number (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":true,"today_log_offset":4,"today_log_date":"2026-09-11"}', true))
Test("keystats: preserve canonical numeric state counter-escaped-number (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_\u0069d":42,"today_log_offset":4,"today_log_date":"2026-09-11"}', true))
Test("keystats: preserve canonical numeric state offset-escaped-number (state-numeric-provenance)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_\u006fffset":4,"today_log_date":"2026-09-11"}', true))

_KFIR_StateOffsetIngest(BooleanOffset) {
	Names := ["initialized", "_shutting_down", "today_log_path", "today_log_offset",
		"today_log_date", "state_json_path", "data_sql_path", "_today_fh",
		"_today_fh_date", "_pending_entries", "next_event_id", "device_id", "_device_id_lit", "rollover_pending"]
	Saved := Map()
	for Name in Names
		if Keystats.HasOwnProp(Name)
			Saved[Name] := Keystats.%Name%
	Windows := KLWV.windows
	Root := _FSWL_Path() . "-state-ingest"
	Db := 0, OwnsRoot := false, OwnsJournal := false
	try {
		AssertFalse(DirExist(Root))
		DirCreate(Root)
		OwnsRoot := true
		Keystats.initialized := true
		Keystats._shutting_down := false
		Keystats.today_log_path := Root . "\today.log"
		Keystats.today_log_offset := 0
		Keystats.today_log_date := KL_Today()
		Keystats.state_json_path := Root . "\state.json"
		Keystats.data_sql_path := Root . "\data.sql"
		Keystats._today_fh := unset
		OwnsJournal := true
		Keystats._today_fh_date := ""
		Keystats.next_event_id := 77
		Keystats.device_id := "dev-one"
		Keystats._device_id_lit := KL_SqlStr("dev-one")
		Keystats._pending_entries := []
		Keystats.rollover_pending := 0
		KLWV.windows := Map()
		FileAppend("-- private source`n", Keystats.data_sql_path, "UTF-8-RAW")
		Entry := Map("type", "mouse_click", "_event_id", 3, "timestamp", KL_NowTimestamp(), "app", "fixture.exe")
		FileAppend(KL_JsonEncode(Entry) . "`n", Keystats.today_log_path, "UTF-8-RAW")
		Source := '{"next_event_id":42,"today_log_offset":' . (BooleanOffset ? "true" : "0")
			. ',"today_log_date":"' . KL_Today() . '"}'
		FileAppend(Source, Keystats.state_json_path, "UTF-8-RAW")
		Loaded := KL_LoadState()
		Result := KL_IngestOnce(true, true)
		FileAppend("# state_offset_boolean=" . BooleanOffset . " loaded=" . Loaded
			. " ingest_ok=" . Result["ok"] . " reason=" . Result.Get("reason", "accepted") . "`n", "*")
		AssertTrue(Result["ok"], "a rejected boolean checkpoint must leave the real journal readable from its intact initial boundary")
		AssertEqual(!BooleanOffset, Loaded)
		AssertEqual(FileGetSize(Keystats.today_log_path), Keystats.today_log_offset)
		_KLRDC_EnsureSharedDir()
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0)
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, FileRead(Keystats.data_sql_path, "UTF-8")))
		AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_mouse WHERE id=3;")[1]["n"],
			"the actual saved journal record must reach native SQL exactly once")
	} finally {
		if Db
			SQLite_Close(Db)
		if OwnsJournal && Keystats.HasOwnProp("_today_fh") && IsObject(Keystats._today_fh)
			Keystats._today_fh.Close()
		for Name in Names {
			if Saved.Has(Name)
				Keystats.%Name% := Saved[Name]
			else if Keystats.HasOwnProp(Name)
				Keystats.DeleteProp(Name)
		}
		KLWV.windows := Windows
		if OwnsRoot
			DirDelete(Root, true)
	}
}
for _KFIR_BooleanOffset in [false, true]
	Test("keystats: state checkpoint boolean=" . _KFIR_BooleanOffset . " cannot block real journal ingestion (state-numeric-ingest-boundary)",
		_KFIR_StateOffsetIngest.Bind(_KFIR_BooleanOffset))

_KFIR_JournalIdentityIngest(Kind, FieldSource, Accept, Suffix := "") {
	Names := ["initialized", "_shutting_down", "today_log_path", "today_log_offset",
		"today_log_date", "state_json_path", "data_sql_path", "_today_fh",
		"_today_fh_date", "_pending_entries", "next_event_id", "device_id", "_device_id_lit", "rollover_pending"]
	Saved := Map()
	for Name in Names
		if Keystats.HasOwnProp(Name)
			Saved[Name] := Keystats.%Name%
	Windows := KLWV.windows
	Root := _FSWL_Path() . "-journal-id"
	Db := 0, OwnsRoot := false, OwnsJournal := false
	try {
		AssertFalse(DirExist(Root))
		DirCreate(Root)
		OwnsRoot := true
		Keystats.initialized := true
		Keystats._shutting_down := false
		Keystats.today_log_path := Root . "\today.log"
		Keystats.today_log_offset := 0
		Keystats.today_log_date := KL_Today()
		Keystats.state_json_path := Root . "\state.json"
		Keystats.data_sql_path := Root . "\data.sql"
		Keystats._today_fh := unset
		OwnsJournal := true
		Keystats._today_fh_date := ""
		Keystats.next_event_id := 77
		Keystats.device_id := "dev-one"
		Keystats._device_id_lit := KL_SqlStr("dev-one")
		Keystats._pending_entries := []
		Keystats.rollover_pending := 0
		KLWV.windows := Map()
		Prior := Map("type", "mouse_click", "timestamp", KL_NowTimestamp(),
			"app", "fixture.exe", "detail", "prior-owned-event")
		Sql := "PRAGMA foreign_keys=OFF;`nBEGIN TRANSACTION;`n"
			. KL_BuildInsertMouseEvent(Prior, 1) . "`nCOMMIT;`n"
		FileAppend(Sql, Keystats.data_sql_path, "UTF-8-RAW")
		Record := '{"type":"mouse_click","timestamp":"' . KL_NowTimestamp()
			. '","app":"fixture.exe","detail":"new-owned-event",' . FieldSource . '}' . "`n"
		Record .= Suffix
		FileAppend(Record, Keystats.today_log_path, "UTF-8-RAW")
		Decoded := _KL_JournalReadLines(Keystats.today_log_path, 0, 10, KL_JsonDecode)
		AssertTrue(Decoded["ok"])
		AssertEqual(Suffix = "" ? 1 : 2, Decoded["entries"].Length, "the fixtures must be complete typed JSONL records before semantic identity admission")
		AssertTrue(KL_SaveState())
		StateBefore := FileRead(Keystats.state_json_path, "UTF-8")
		Result := KL_IngestOnce(true, true)
		_KLRDC_EnsureSharedDir()
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0)
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, FileRead(Keystats.data_sql_path, "UTF-8")))
		NewRows := SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_mouse WHERE meta_json LIKE '%new-owned-event%';")[1]["n"]
		FileAppend("# journal_identity kind=" . Kind . " ok=" . Result["ok"]
			. " reason=" . Result.Get("reason", "accepted") . " new_rows=" . NewRows
			. " offset=" . Keystats.today_log_offset . " eof=" . FileGetSize(Keystats.today_log_path) . "`n", "*")
		if Accept {
			AssertTrue(Result["ok"])
			AssertEqual(1, NewRows, "a numeric reserved identity must publish the distinct native raw event")
			AssertEqual(FileGetSize(Keystats.today_log_path), Keystats.today_log_offset)
		} else {
			AssertFalse(Result["ok"], "a nonnumeric JSON identity cannot be acknowledged as Integer1 and discarded by INSERT OR IGNORE")
			AssertEqual(0, Keystats.today_log_offset)
			AssertEqual(StateBefore, FileRead(Keystats.state_json_path, "UTF-8"))
			AssertEqual(Sql, FileRead(Keystats.data_sql_path, "UTF-8"))
		}
		AssertEqual(Record, FileRead(Keystats.today_log_path, "UTF-8"))
		AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_mouse WHERE meta_json LIKE '%prior-owned-event%';")[1]["n"])
	} finally {
		if Db
			SQLite_Close(Db)
		if OwnsJournal && Keystats.HasOwnProp("_today_fh") && IsObject(Keystats._today_fh)
			Keystats._today_fh.Close()
		for Name in Names {
			if Saved.Has(Name)
				Keystats.%Name% := Saved[Name]
			else if Keystats.HasOwnProp(Name)
				Keystats.DeleteProp(Name)
		}
		KLWV.windows := Windows
		if OwnsRoot
			DirDelete(Root, true)
	}
}
for _KFIR_JournalCase in [
	["number", '"_event_id":2', true],
	["boolean-true", '"_event_id":true', false],
	["boolean-false", '"_event_id":false', false],
	["escaped-boolean", '"_event_\u0069d":true', false],
	["final-boolean", '"_event_id":2,"_event_id":true', false],
	["final-number", '"_event_id":true,"_event_id":2', true],
	["string", '"_event_id":"2"', false],
	["null", '"_event_id":null', false],
	["array", '"_event_id":[]', false],
	["object", '"_event_id":{}', false],
	["float", '"_event_id":2.0', false],
	["zero", '"_event_id":0', false],
	["negative", '"_event_id":-1', false],
	["nested-boolean", '"_event_id":2,"nested":{"_event_id":true}', true],
	["quoted-boolean", '"_event_id":2,"quoted":"\"_event_id\":true"', true],
	["bad-before-valid", '"_event_id":true', false,
		'{"type":"mouse_click","timestamp":"2026-03-04 11:00:00.000","app":"fixture.exe","detail":"later-owned-event","_event_id":2}' . "`n"],
	["valid-before-bad", '"_event_id":2', false,
		'{"type":"mouse_click","timestamp":"2026-03-04 11:00:00.000","app":"fixture.exe","detail":"later-owned-event","_event_id":true}' . "`n"]
]
	Test("keystats: journal identity " . _KFIR_JournalCase[1] . " retains native row ownership (journal-identity-numeric-provenance)",
		_KFIR_JournalIdentityIngest.Bind(_KFIR_JournalCase*))

_KFIR_JournalIdentityRecovery(Kind, FieldSource, Refuse, Prefix := "") {
	Path := _FSWL_Path()
	try {
		AssertFalse(FileExist(Path))
		Source := Prefix . '{"type":"mouse_click",' . FieldSource . '}' . "`n"
		FileAppend(Source, Path, "UTF-8-RAW")
		Before := KLR_LedgerSnapshot(Path)
		Failure := 0, Recovered := -1
		try Recovered := _KL_RecoverJournalEventId(Path, 0)
		catch as Err
			Failure := Err
		FileAppend("# journal_identity_recovery kind=" . Kind . " refused=" . IsObject(Failure)
			. " maximum=" . Recovered . "`n", "*")
		if Refuse {
			AssertTrue(Failure is Error, "startup cannot trust or silently ignore a nonnumeric reserved journal identity")
			AssertEqual(-1, Recovered)
			AssertThrows(KL_ScanMaxJournalEventId.Bind(Source), "the raw journal recovery helper must share numeric source admission")
		} else {
			AssertFalse(IsObject(Failure))
			AssertEqual(2, Recovered, "canonical numeric identity recovery must survive unrelated malformed or quoted data")
			AssertEqual(2, KL_ScanMaxJournalEventId(Source))
		}
		AssertEqual(Source, FileRead(Path, "UTF-8"))
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
for _KFIR_RecoveryCase in [
	["number", '"_event_id":2', false],
	["boolean-true", '"_event_id":true', true],
	["boolean-false", '"_event_id":false', true],
	["escaped-boolean", '"_event_\u0069d":true', true],
	["final-boolean", '"_event_id":2,"_event_id":true', true],
	["final-number", '"_event_id":true,"_event_id":2', false],
	["nested-boolean", '"_event_id":2,"nested":{"_event_id":true}', false],
	["quoted-boolean", '"_event_id":2,"quoted":"\"_event_id\":true"', false],
	["malformed-prefix", '"_event_id":2', false, "broken`n"],
	["missing-type-prefix", '"_event_id":2', false, '{"_event_id":true}' . "`n"],
	["string", '"_event_id":"2"', true],
	["null", '"_event_id":null', true],
	["array", '"_event_id":[]', true],
	["object", '"_event_id":{}', true]
]
	Test("keystats: startup journal identity " . _KFIR_RecoveryCase[1] . " preserves recovery admission (journal-identity-recovery-provenance)",
		_KFIR_JournalIdentityRecovery.Bind(_KFIR_RecoveryCase*))
