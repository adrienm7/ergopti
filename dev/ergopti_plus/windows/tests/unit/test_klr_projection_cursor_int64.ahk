; tests/unit/test_klr_projection_cursor_int64.ahk

; ==============================================================================
; MODULE: Exact Projection Cursor Tests
; DESCRIPTION: SQLite row identities must survive every AHK paging boundary.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLPCI_ExactCursor(Scoped, Db) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	Events := '[["a",120,{"s":0}],["b",120,{"s":1}]]'
	Sql := "INSERT INTO events_typing (device_id,id,ts,date,app,is_fullscreen,in_meeting,"
		. "mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) VALUES "
	Count := 0
	for Spec in [["a'Ω", 9223372036854775678], ["b'Ω", -9223372036854775808]] {
		loop 130 {
			; Adjacent IDs at both int64 limits cannot survive a floating-point
			; round trip. Each device also crosses a 128-row page boundary.
			EventId := Spec[2] + (A_Index - 1)
			Sql .= (Count ? "," : "") . "(" . SQLite_Q(Spec[1]) . "," . EventId
				. ",'2026-01-01 10:00:00.000','2026-01-01','fixture.exe',0,0,0,0,0,'ab',"
				. SQLite_Q(Events) . ")"
			Count += 1
		}
	}
	AssertTrue(SQLite_Exec(Db, Sql . ";"))
	AssertEqual(260, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
	Bounds := SQLite_Query(Db, "SELECT MIN(id) AS low,MAX(id) AS high FROM events_typing;")[1]
	AssertEqual(-9223372036854775808, Bounds["low"])
	AssertEqual(9223372036854775807, Bounds["high"])
	for IncludePayload in [false, true] {
		AssertTrue(KLR_PrepareTypingProjection(Db, Scoped ? ["2026-01-01"] : 0, IncludePayload))
		AssertEqual(260, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM klr_reader_typing_counts;")[1]["n"])
		AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing AS t "
			. "LEFT JOIN klr_reader_typing_counts AS c ON c.device_id=t.device_id AND c.event_id=t.id "
			. "WHERE c.device_id IS NULL OR c.chars<>1;")[1]["n"],
			"every exact int64 event identity must retain its manual count")
		if IncludePayload
			AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing AS t "
				. "LEFT JOIN temp.klr_reader_typing_payload AS p ON p.device_id=t.device_id AND p.event_id=t.id "
				. "WHERE p.device_id IS NULL OR p.events_json<>t.events_json;")[1]["n"],
				"payload recovery after count-only preparation must retain exact event identities")
	}
	_SQLRD_AssertNoStatements(Db)
}

for Scoped in [false, true]
	Test("KLR projection: exact int64 cursor scoped=" . Scoped . " (klr-projection-cursor-int64)",
		_SQLRD_WithDatabase.Bind(_KLPCI_ExactCursor.Bind(Scoped)))
