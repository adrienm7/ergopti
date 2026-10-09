; tests/unit/test_klr_projection_page_work.ahk

; ==============================================================================
; MODULE: Typing Projection Page Work Tests
; DESCRIPTION: Later pages must seek past completed rows instead of rescanning them.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRPW_Profile(State, EventKind, Context, Statement, Elapsed) {
	try {
		SqlPtr := DllCall(SQLiteConst.DLL . "\sqlite3_sql", "Ptr", Statement, "Ptr")
		if SqlPtr && RegExMatch(StrGet(SqlPtr, "UTF-8"),
			"^SELECT\s+t\.device_id,\s*t\.id,\s*t\.events_json\s+FROM\s+") {
			; SQLITE_STMTSTATUS_VM_STEP counts native work independently of CPU load.
			State["steps"].Push(DllCall(SQLiteConst.DLL . "\sqlite3_stmt_status",
				"Ptr", Statement, "Int", 4, "Int", 0, "Int"))
			; SQLITE_STMTSTATUS_SORT exposes repeated date-index page sorts.
			State["sorts"] += DllCall(SQLiteConst.DLL . "\sqlite3_stmt_status",
				"Ptr", Statement, "Int", 2, "Int", 0, "Int")
		}
	} catch {
		State["failed"] := true
	}
	return 0
}

_KLRPW_BoundedPages(Db, Scoped := false) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	AssertTrue(SQLite_Exec(Db,
		"WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<1024) "
		. "INSERT INTO events_typing(device_id,id,ts,date,app,is_fullscreen,in_meeting,"
		. "mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) "
		. "SELECT 'device',i,'2026-01-01 10:00:00.000','2026-01-01','fixture.exe',0,0,0,0,0,'','[]' FROM n;"))
	State := Map("steps", [], "sorts", 0, "failed", false)
	Callback := CallbackCreate(_KLRPW_Profile.Bind(State), "C", 4)
	try {
		; SQLITE_TRACE_PROFILE runs while the completed statement remains valid.
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_trace_v2", "Ptr", Db,
			"UInt", 2, "Ptr", Callback, "Ptr", 0, "Int"))
		AssertTrue(KLR_PrepareTypingProjection(Db, Scoped ? ["2026-01-01"] : 0))
	} finally {
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_trace_v2", "Ptr", Db,
			"UInt", 0, "Ptr", 0, "Ptr", 0, "Int"))
		CallbackFree(Callback)
	}
	AssertFalse(State["failed"], "native statement observation must not fail silently")
	Steps := State["steps"]
	AssertTrue(Steps.Length >= 8, "the fixture must observe enough real projection pages to expose rescanning")
	if Scoped
		AssertTrue(State["sorts"] <= 1,
			"scoped pages must not repeatedly sort the same day; sorts=" . State["sorts"])
	AssertTrue(Steps[1] > 0, "the first complete page must establish a nonzero work baseline")
	Maximum := 0
	for Work in Steps
		Maximum := Max(Maximum, Work)
	AssertTrue(Maximum <= 2 * Steps[1],
		"later page work must stay within twice the first page; first=" . Steps[1] . " max=" . Maximum)
	AssertEqual(1024, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM klr_reader_typing_counts;")[1]["n"])
	AssertEqual(1024, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM temp.klr_reader_typing_payload;")[1]["n"])
	_SQLRD_AssertNoStatements(Db)
}
Test("KLR projection: native work remains bounded across pages (klr-projection-page-work)",
	_SQLRD_WithDatabase.Bind(_KLRPW_BoundedPages))

_KLRPW_ScopedPages(Db) {
	_KLRPW_BoundedPages(Db, true)
}
Test("KLR projection: scoped pages do not repeat native sorts (klr-projection-scoped-work)",
	_SQLRD_WithDatabase.Bind(_KLRPW_ScopedPages))
