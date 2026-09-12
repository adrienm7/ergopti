; tests/unit/test_keylogger_full_id_recovery.ahk

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
		Tail := _KL_ReadRecoveryText(Path, 0, KeylogConst.DATA_SQL_SCAN_TAIL_BYTES)
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
Test("keylogger: full recovery preserves IDs outside an out-of-order tail (full-id-recovery)",
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
		for Size in [7, 31, KeylogConst.DATA_SQL_SCAN_TAIL_BYTES]
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
Test("keylogger: historical recovery retains bounded token fragments (full-id-recovery)",
	_KFIR_ChunkBoundaries)

_KFIR_StateCounterValidity() {
	Path := _FSWL_Path()
	HadPath := Keylogger.HasOwnProp("state_json_path")
	SavedPath := HadPath ? Keylogger.state_json_path : ""
	SavedCounter := Keylogger.next_event_id
	HadOffset := Keylogger.HasOwnProp("today_log_offset")
	SavedOffset := HadOffset ? Keylogger.today_log_offset : 0
	try {
		Keylogger.state_json_path := Path
		Keylogger.next_event_id := 77
		AssertFalse(KL_LoadState(), "missing state cannot authorize tail-only recovery")
		for Source in ["broken", "{}", '{"next_event_id":0}', '{"next_event_id":-1}',
			'{"next_event_id":1.5}', '{"next_event_id":"42"}',
			'{"next_event_id":0,"today_log_offset":4096}'] {
			FileAppend(Source, Path, "UTF-8-RAW")
			AssertFalse(KL_LoadState(), "invalid allocation counters require historical recovery")
			AssertEqual(77, Keylogger.next_event_id)
			AssertEqual(HadOffset, Keylogger.HasOwnProp("today_log_offset"))
			if HadOffset
				AssertEqual(SavedOffset, Keylogger.today_log_offset,
					"an invalid allocation state cannot hide journal entries behind its offset")
			FileDelete(Path)
		}
		FileAppend('{"next_event_id":42}', Path, "UTF-8-RAW")
		AssertTrue(KL_LoadState(), "a native positive integer counter keeps ordinary recovery bounded")
		AssertEqual(42, Keylogger.next_event_id)
	} finally {
		if HadPath
			Keylogger.state_json_path := SavedPath
		else
			Keylogger.DeleteProp("state_json_path")
		Keylogger.next_event_id := SavedCounter
		if HadOffset
			Keylogger.today_log_offset := SavedOffset
		else if Keylogger.HasOwnProp("today_log_offset")
			Keylogger.DeleteProp("today_log_offset")
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keylogger: state validity selects exceptional identity recovery (full-id-recovery)",
	_KFIR_StateCounterValidity)

_KFIR_StateFieldsAtomic(Source, Valid := false) {
	Path := _FSWL_Path()
	Saved := Map()
	for Name in ["state_json_path", "next_event_id", "today_log_offset", "today_log_date"] {
		if Keylogger.HasOwnProp(Name)
			Saved[Name] := Keylogger.%Name%
	}
	try {
		Keylogger.state_json_path := Path
		Keylogger.next_event_id := 77
		Keylogger.today_log_offset := 0
		Keylogger.today_log_date := "2026-09-12"
		FileAppend(Source, Path, "UTF-8-RAW")
		Before := KLR_LedgerSnapshot(Path)
		AssertEqual(Valid, KL_LoadState(), "invalid checkpoints must select exceptional recovery")
		AssertEqual(Valid ? 42 : 77, Keylogger.next_event_id,
			"rejected state must not partially publish its allocation counter")
		AssertEqual(Valid ? 4 : 0, Keylogger.today_log_offset,
			"rejected state must not change the journal checkpoint")
		AssertEqual(Valid ? "2026-09-11" : "2026-09-12", Keylogger.today_log_date)
		AssertEqual(Source, FileRead(Path, "UTF-8"))
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
	} finally {
		for Name in ["state_json_path", "next_event_id", "today_log_offset", "today_log_date"] {
			if Saved.Has(Name)
				Keylogger.%Name% := Saved[Name]
			else if Keylogger.HasOwnProp(Name)
				Keylogger.DeleteProp(Name)
		}
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Offset in ["-1", "1.5", '"4"', '"invalid"', "{}"]
	Test("keylogger: reject checkpoint " . Offset . " atomically (state-fields-atomic)",
		_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":' . Offset . '}'))
for Date in ["{}", "42"]
	Test("keylogger: reject date type " . Date . " atomically (state-fields-atomic)",
		_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":4,"today_log_date":' . Date . '}'))
Test("keylogger: restore valid checkpoint fields together (state-fields-atomic)",
	_KFIR_StateFieldsAtomic.Bind('{"next_event_id":42,"today_log_offset":4,"today_log_date":"2026-09-11"}', true))
