; tests/unit/test_klr_projection_paging.ahk

; ==============================================================================
; MODULE: Typing Projection Paging Tests
; DESCRIPTION: Composite cursors must preserve every scoped event across pages.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRPP_RowsAcrossDevices(Db) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	Events := '[["a",120,{"s":0}],["b",120,{"s":1}]]'
	Sql := "INSERT INTO events_typing (device_id,id,ts,date,app,is_fullscreen,in_meeting,"
		. "mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) VALUES "
	Expected := 0
	for Spec in [["device", 127], ["Device", 128], ["quoted'device", 130]] {
		loop Spec[2] {
			; Restart IDs for each device and interleave negative and positive values.
			Id := Mod(A_Index, 2) ? -A_Index : 1000 - A_Index
			Sql .= (Expected ? "," : "") . "(" . SQLite_Q(Spec[1]) . "," . Id
				. ",'2026-01-01 10:00:00.000','2026-01-01','fixture.exe',0,0,0,0,0,'ab',"
				. SQLite_Q(Events) . ")"
			Expected += 1
		}
	}
	AssertEqual(385, Expected, "the fixture must cross multiple 128-row pages and leave a partial final page")
	AssertTrue(SQLite_Exec(Db, Sql . ";"))
	AssertTrue(SQLite_Exec(Db, "INSERT INTO events_typing "
		. "SELECT device_id,0,ts,'2026-01-02',app,app_category,title,url,field_role,layout,document_path,"
		. "is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,pause_before_ms,"
		. "battery_level,audio_volume,wpm,text,rich_text,events_json FROM events_typing WHERE id=-1;"))
	for IncludePayload in [false, true] {
		AssertTrue(KLR_PrepareTypingProjection(Db, ["2026-01-01"], IncludePayload))
		AssertEqual(Expected, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM klr_reader_typing_counts;")[1]["n"],
			"paging must neither skip scoped rows nor include the excluded day")
		Missing := SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing AS t "
			. "LEFT JOIN klr_reader_typing_counts AS c ON c.device_id=t.device_id AND c.event_id=t.id "
			. "WHERE t.date='2026-01-01' AND (c.device_id IS NULL OR c.chars<>1);")[1]["n"]
		AssertEqual(0, Missing, "every exact device/event pair must retain its manual-only count")
		AssertEqual(IncludePayload ? Expected : 0,
			SQLite_Query(Db, "SELECT COUNT(*) AS n FROM temp.klr_reader_typing_payload;")[1]["n"],
			"replay payload admission must work even after every numeric count is cached")
		if IncludePayload {
			Mismatches := SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing AS t "
				. "LEFT JOIN temp.klr_reader_typing_payload AS p ON p.device_id=t.device_id AND p.event_id=t.id "
				. "WHERE t.date='2026-01-01' AND (p.device_id IS NULL OR p.events_json<>t.events_json);")[1]["n"]
			AssertEqual(0, Mismatches, "all ordered payloads must remain attached to their original device/event pair")
		}
	}
	Before := SQLite_Query(Db, "SELECT total_changes() AS n;")[1]["n"]
	AssertTrue(KLR_PrepareTypingProjection(Db, ["2026-01-01"], true))
	AssertEqual(Before, SQLite_Query(Db, "SELECT total_changes() AS n;")[1]["n"],
		"an unchanged complete projection must not rewrite cached pages")
	_SQLRD_AssertNoStatements(Db)
}
Test("KLR projection: composite paging preserves scoped device rows (klr-projection-paging)",
	_SQLRD_WithDatabase.Bind(_KLRPP_RowsAcrossDevices))
