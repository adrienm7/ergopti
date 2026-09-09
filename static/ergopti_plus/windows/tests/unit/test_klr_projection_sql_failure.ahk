; tests/unit/test_klr_projection_sql_failure.ahk

; ==============================================================================
; MODULE: Scoped Typing Projection SQL Failure Tests
; DESCRIPTION: Native SQLite refusals must reject private projection candidates.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRPS_Authorize(State, Context, Action, NamePtr, ColumnPtr, DatabasePtr, TriggerPtr) {
	try {
		if Action = State["action"] && NamePtr && DatabasePtr
			&& StrGet(NamePtr, "UTF-8") = "klr_reader_typing_keys"
			&& StrGet(DatabasePtr, "UTF-8") = "temp" {
			State["denied"] += 1
			return 1 ; SQLITE_DENY rejects the complete statement.
		}
	} catch {
		State["failed"] := true
		return 1
	}
	return 0
}

_KLRPS_Refusal(Db, Action) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	AssertTrue(KLR_EnsureTypingProjectionTable(Db))
	AssertTrue(SQLite_Exec(Db,
		"INSERT INTO events_typing(device_id,id,ts,date,app,is_fullscreen,in_meeting,"
		. "mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) VALUES "
		. "('device',7,'2026-01-01 10:00:00.000','2026-01-01','fixture.exe',0,0,0,0,0,'','[]');"))
	State := Map("action", Action, "denied", 0, "failed", false)
	Callback := CallbackCreate(_KLRPS_Authorize.Bind(State), "C", 6)
	try {
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", Callback, "Ptr", 0, "Int"))
		AssertFalse(KLR_PrepareTypingProjection(Db, ["2026-01-01"]),
			"a native scoped-key refusal must reject preparation, including failed cleanup")
	} finally {
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", 0, "Ptr", 0, "Int"))
		CallbackFree(Callback)
	}
	AssertFalse(State["failed"], "the native callback must not hide a fixture error")
	AssertTrue(State["denied"] > 0, "the requested native fault must actually occur")
	; SQLITE_DROP_TEMP_TABLE is 13: only this refusal happens after page writes.
	ExpectedRows := Action = 13 ? 1 : 0
	AssertEqual(ExpectedRows, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM klr_reader_typing_counts;")[1]["n"])
	AssertEqual(ExpectedRows, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM temp.klr_reader_typing_payload;")[1]["n"])
	AssertEqual(ExpectedRows, SQLite_Query(Db,
		"SELECT COUNT(*) AS n FROM sqlite_temp_master WHERE name='klr_reader_typing_keys';")[1]["n"],
		"successful cleanup must release keys; denied cleanup must not pretend to have released them")
	AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing WHERE id=7 AND events_json='[]';")[1]["n"],
		"projection failures must preserve the authoritative source row")
	AssertTrue(SQLite_IsAutocommit(Db), "these admission and cleanup faults must not leave a transaction")
	_SQLRD_AssertNoStatements(Db)
	; The database fixture closes the rejected private candidate, including any
	; key table that SQLite refused to drop. Never admit it as a reusable cache.
}

; Native action codes: CREATE_TEMP_TABLE=4, INSERT=18, DROP_TEMP_TABLE=13.
for Spec in [["create", 4], ["insert", 18], ["drop", 13]]
	Test("KLR projection: reject native scoped-key " . Spec[1] . " refusal (klr-projection-sql-failure)",
		_SQLRD_WithDatabase.Bind(_KLRPS_Refusal.Bind(, Spec[2])))

