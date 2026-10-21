; tests/unit/modules/keylogger/reader/test_klr_manifest_switches_to.ahk

; ==============================================================================
; MODULE: Reader Manifest Directed App Transitions
; DESCRIPTION:
; The rollup persists every directed application switch in
; agg_app_day_switches_to, and both metrics dashboards read the per-app
; switches_to map (switch counts and the app pair affinity), but the Windows
; manifest never projected that table, so those views were empty on Windows.
; Both manifest representations (the Map and the encoded JSON) must sum the
; devices of each date, source and destination, honour the date filter, keep
; typed zeros and UTF-8 names, and omit the field for an app without switches.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRST_OpenFixture() {
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0, "the fixture must open an in-memory database")
	try {
		AssertTrue(KLR_LoadSchema(Db), "the fixture must use the canonical production schema")
		Rows := [
			["device-a", "2025-05-01", "editor.exe", "browser.exe", 2],
			["device-b", "2025-05-01", "editor.exe", "browser.exe", 4],
			["device-a", "2025-05-01", "editor.exe", "café é😀.exe", 3],
			["device-a", "2025-05-01", "editor.exe", "idle.exe", 0],
			["device-b", "2025-05-01", "browser.exe", "editor.exe", 1],
			["device-a", "2025-05-02", "editor.exe", "browser.exe", 7]]
		Sql := ""
		for Row in Rows
			Sql .= "INSERT INTO agg_app_day_switches_to (device_id,date,app_from,app_to,count) VALUES ("
				. SQLite_Q(Row[1]) . "," . SQLite_Q(Row[2]) . "," . SQLite_Q(Row[3]) . ","
				. SQLite_Q(Row[4]) . "," . Row[5] . ");"
		; An app with typing but no switch keeps the field absent.
		Sql .= "INSERT INTO agg_app_day (device_id,date,app,chars) VALUES ('device-a','2025-05-01','notes.exe',5);"
		AssertTrue(SQLite_Exec(Db, Sql), "the fixture rows must persist")
		return Db
	} catch as Failure {
		SQLite_Close(Db)
		throw Failure
	}
}

_KLRST_AssertDay(Manifest, Label) {
	AssertTrue(Manifest.Has("2025-05-01"), Label . ": the fixture day must be projected")
	Day := Manifest["2025-05-01"]
	AssertTrue(Day.Has("editor.exe") && Day["editor.exe"].Has("switches_to"),
		Label . ": a source application must publish its switches_to map")
	Editor := Day["editor.exe"]["switches_to"]
	AssertEqual(3, Editor.Count, Label . ": every destination of the source must be present")
	AssertEqual(6, Editor["browser.exe"], Label . ": device contributions must be summed")
	AssertEqual(3, Editor["café é😀.exe"], Label . ": a UTF-8 destination name must survive")
	AssertEqual(0, Editor["idle.exe"], Label . ": a typed zero must stay a zero")
	AssertEqual(1, Day["browser.exe"]["switches_to"]["editor.exe"], Label . ": the reverse direction stays distinct")
	AssertTrue(Day.Has("notes.exe"), Label . ": the typing-only app must still be projected")
	AssertFalse(Day["notes.exe"].Has("switches_to"), Label . ": an app without switches omits the field")
}

_KLRST_ManifestProjectsTransitions() {
	Db := _KLRST_OpenFixture()
	try {
		_KLRST_AssertDay(KLR_ReadManifest(Db), "Map manifest")
		_KLRST_AssertDay(JsonParse(KLR_BuildManifestJson(Db)), "encoded manifest")
		Filtered := KLR_ReadManifest(Db, "2025-05-02", "2025-05-02")
		AssertFalse(Filtered.Has("2025-05-01"), "the date filter must exclude other days")
		AssertEqual(7, Filtered["2025-05-02"]["editor.exe"]["switches_to"]["browser.exe"],
			"the date filter must keep its own day's transitions")
	} finally SQLite_Close(Db)
}
Test("KLR manifest: directed app transitions reach both manifest forms (klr-manifest-switches-to)",
	_KLRST_ManifestProjectsTransitions)
