; tests/unit/modules/keystats/reader/test_klr_utc_offset_rows.ahk

; ==============================================================================
; MODULE: Rows in UTC With Their Recorded Offset (Windows, KMD-1)
; DESCRIPTION:
; Decided by the maintainer on 2026-11-11: a raw row stores its instant in UTC
; and the local UTC offset in force when it was recorded; hours, night wakes
; and days are read in the local time the user lived. Covers the Windows port
; of _shared/metrics/engine/local_time.lua, every raw-row writer, the purge
; tombstone, the walker and the reader's replay and hourly rollups, and pins the
; reader's migration statements to _shared/metrics/engine/utc_offset_column.lua.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Row time helpers =======
; ===================================
; ===================================

_KLUOR_NowOffsetIsTheZoneOffset() {
	LocalTs := KL_NowTimestamp()
	Expected := NativeTimeZoneOffsetMinutesEast()
	AssertTrue(Expected is Integer, "Windows supplies the active zone's bias")
	Instant := KL_TimestampFromLocal(LocalTs)
	AssertEqual(Expected, Instant["utc_offset_min"], "the offset of now is the zone's current offset")
	AssertEqual(KL_TimestampShift(LocalTs, -Expected), Instant["ts"], "ts is the local stamp minus its offset")
	AssertEqual(SubStr(LocalTs, -4), SubStr(Instant["ts"], -4), "the milliseconds survive the conversion")
	AssertEqual(LocalTs, KL_RowLocalTimestamp(Instant["ts"], Instant["utc_offset_min"]),
		"the stored pair reads back as the local stamp")
}
Test("KMD-1: a journal stamp of now converts with the zone's offset (utc-offset-rows)", _KLUOR_NowOffsetIsTheZoneOffset)

_KLUOR_RowLocalTimestamp() {
	; The cases of local_time.local_ts: offset given, none on a local row, none
	; on a Linux row (the reader's current offset), across a day, no fraction.
	AssertEqual("2026-11-05 23:15:00.000", KL_RowLocalTimestamp("2026-11-05 22:15:00.000", 60))
	AssertEqual("2026-11-05 09:15:00.000", KL_RowLocalTimestamp("2026-11-05 09:15:00.000", ""))
	AssertEqual("2026-11-05 04:15:00", KL_RowLocalTimestamp("2026-11-05 09:15:00", "", true, -300))
	AssertEqual("2026-11-06 01:30:00", KL_RowLocalTimestamp("2026-11-05 23:30:00", 120))
	AssertEqual("2025-12-31 23:00:00.500", KL_RowLocalTimestamp("2026-01-01 02:00:00.500", -180))
	AssertEqual("2026-11-05 10:00:00.000", KL_RowLocalTimestamp("2026-11-05 09:15:00.000", "45"),
		"an offset SQLite returns as text is whole minutes too")
	AssertEqual("", KL_RowLocalTimestamp("not a timestamp", 60))
	AssertThrows(() => KL_RowLocalTimestamp("2026-11-05 09:15:00", 1.5), "a fractional offset is refused")
}
Test("KMD-1: a row reads as ts plus its offset, a legacy row by its device (utc-offset-rows)", _KLUOR_RowLocalTimestamp)

_KLUOR_SeasonsRoundTrip() {
	for LocalTs in ["2026-01-15 08:00:00.250", "2026-07-01 23:30:00.125", "2026-12-31 23:59:59.999"] {
		Instant := KL_TimestampFromLocal(LocalTs)
		AssertEqual(KL_UtcOffsetAt(StrReplace(StrReplace(StrReplace(SubStr(Instant["ts"], 1, 19), "-"), " "), ":")),
			Instant["utc_offset_min"], "the stored offset is the one in force at the UTC instant of " . LocalTs)
		AssertEqual(LocalTs, KL_RowLocalTimestamp(Instant["ts"], Instant["utc_offset_min"]), LocalTs . " reads back")
	}
}
Test("KMD-1: winter, summer and year-end stamps keep their own offset (utc-offset-rows)", _KLUOR_SeasonsRoundTrip)





; ==============================
; ==============================
; ======= 2/ The writers =======
; ==============================
; ==============================

_KLUOR_EveryWriterStoresUtcAndOffset() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	LocalTs := "2026-07-01 23:30:00.125"
	Expected := KL_TimestampFromLocal(LocalTs)
	; One entry per raw table but typing (whose text needs the cipher), each
	; through the production dispatch.
	Entries := [
		["events_app_switch", Map("type", "app_switch", "prev_app", "A", "next_app", "B", "duration_ms", 5)],
		["events_window_switch", Map("type", "window_switch", "app", "A", "prev_title", "x", "duration_ms", 5)],
		["events_shortcut", Map("type", "shortcut", "app", "A", "key", "ctrl+s")],
		["events_system", Map("type", "system_event", "action", "wake", "duration_ms", 5)],
		["events_hotstring", Map("type", "hotstring_suggested", "app", "A", "trigger", "t", "replacement", "r")],
		["events_llm", Map("type", "llm_generation", "app", "A", "context", "c")],
		["events_session", Map("type", "session_start")],
		["events_ergo", Map("type", "ergo_event", "kind", "posture", "app", "A")],
		["events_window_topo", Map("type", "window_move", "app", "A")],
		["events_mouse", Map("type", "mouse_click", "app", "A")],
		["events_av", Map("type", "volume_change", "app", "A")],
		["events_network", Map("type", "network_change", "app", "A")],
		["events_clipboard", Map("type", "clipboard_copy", "app", "A")],
		["events_roi", Map("type", "roi_snapshot", "app", "A")]]
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0)
	try {
		AssertTrue(KLR_LoadSchema(Db))
		for Index, Item in Entries {
			Entry := Item[2]
			Entry["timestamp"] := LocalTs
			Entry["_event_id"] := Index
			for Sql in KL_BuildInserts(Entry)
				AssertTrue(SQLite_Exec(Db, Sql), Item[1] . " takes the row: " . SQLite_LastError(Db))
			Rows := SQLite_Query(Db, "SELECT ts, date, utc_offset_min FROM " . Item[1] . " WHERE id=" . Index . ";")
			AssertEqual(1, Rows.Length, Item[1] . " holds the row")
			AssertEqual(Expected["ts"], Rows[1]["ts"], Item[1] . " stores the UTC instant")
			AssertEqual("2026-07-01", Rows[1]["date"], Item[1] . " keeps the local day")
			AssertEqual(Expected["utc_offset_min"], Rows[1]["utc_offset_min"], Item[1] . " stores the offset")
		}
	} finally {
		SQLite_Close(Db)
	}
}
Test("KMD-1: every raw-row writer stores ts in UTC and utc_offset_min (utc-offset-rows)",
	_KLUOR_EveryWriterStoresUtcAndOffset)

; The tombstone of a purge at a local instant, and rows a second around it, all
; written by the production builders: the triggers compare them in UTC, and an
; older Linux row (UTC, no offset) with the tombstone's UTC instant.
_KLUOR_TombstonePurgesInUtc() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	LocalTs := "2026-11-06 11:00:00.250"
	Tombstone := KL_MetricsTombstone(LocalTs)
	Utc := KL_TimestampFromLocal(LocalTs)["ts"]
	AssertEqual(Utc, Tombstone["utc"], "the tombstone's utc is its own instant, milliseconds kept")
	Db := SQLite_Open(":memory:")
	SavedDevice := Keystats.device_id
	try {
		AssertTrue(KLR_LoadSchema(Db))
		_KLUOR_Devices(Db)
		Keystats.device_id := "pc"
		AssertTrue(SQLite_Exec(Db, KL_BuildInsertSystem(Map("type", "system_event", "action", "lock",
			"timestamp", "2026-11-06 10:59:59.900"), 1)))
		AssertTrue(SQLite_Exec(Db, KL_BuildInsertSystem(Tombstone, 2)))
		AssertTrue(SQLite_Exec(Db, KL_BuildInsertSystem(Map("type", "system_event", "action", "unlock",
			"timestamp", "2026-11-06 11:00:00.300"), 3)))
		; Older Linux rows in UTC, without an offset, just before and after.
		AssertTrue(SQLite_Exec(Db, "INSERT INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES "
			. "('tux', 1, " . SQLite_Q(SubStr(Utc, 1, 19) . ".200") . ", '2026-11-06', 'wake', '{}');"))
		AssertTrue(SQLite_Exec(Db, "INSERT INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES "
			. "('tux', 2, " . SQLite_Q(SubStr(Utc, 1, 19) . ".300") . ", '2026-11-06', 'sleep', '{}');"))
		Left := []
		for Row in SQLite_Query(Db, "SELECT device_id, id, action, utc_offset_min FROM events_system ORDER BY device_id, id;")
			Left.Push(Row["device_id"] . ":" . Row["id"] . ":" . Row["action"])
		AssertEqual("pc:2:metrics_purge|pc:3:unlock|tux:2:sleep", _KLUOR_Join(Left, "|"),
			"rows up to the instant are purged and ignored, later rows stay")
		Stored := SQLite_Query(Db, "SELECT ts, utc_offset_min, json_extract(metadata_json, '$.utc') AS utc"
			. " FROM events_system WHERE device_id='pc' AND id=2;")[1]
		AssertEqual(Utc, Stored["ts"], "the tombstone row stores its UTC instant")
		AssertEqual(Utc, Stored["utc"], "and carries it under metadata utc")
		AssertEqual(KL_TimestampFromLocal(LocalTs)["utc_offset_min"], Stored["utc_offset_min"],
			"and its own offset")
	} finally {
		Keystats.device_id := SavedDevice
		SQLite_Close(Db)
	}
}
Test("KMD-1: a purge tombstone in UTC removes the rows up to its instant (utc-offset-rows)", _KLUOR_TombstonePurgesInUtc)

; Registers a Windows device "pc" and a Linux device "tux".
_KLUOR_Devices(Db) {
	for Device in [["pc", "windows"], ["tux", "linux"]]
		AssertTrue(SQLite_Exec(Db, KeystatsQuery("devices.upsert", Map("device_id", Device[1], "name", Device[1],
			"os", Device[2], "os_version", "", "host_signature", "", "created_at", "", "updated_at", ""))), Device[1])
}

_KLUOR_Join(List, Separator) {
	Out := ""
	for Item in List
		Out .= (A_Index > 1 ? Separator : "") . Item
	return Out
}





; =============================
; =============================
; ======= 3/ The walker =======
; =============================
; =============================

; A row recorded at 23:30 UTC two hours east of UTC is 01:30 the next local
; day: a night wake of that day, typed in its 01 hour, its app time on that day.
_KLUOR_WalkerReadsLocalTime() {
	SavedBatch := KLW.batch, SavedContext := KLW.ctx
	try {
		KLW_ResetBatch()
		KLW.ctx := Map()
		Utc := "2026-11-10 23:30:00.000"
		KLW_WalkSystemEvent(Map("timestamp", Utc, "utc_offset_min", 120, "action", "wake", "duration_ms", 1000))
		AssertTrue(KLW.batch["system_day"].Has("2026-11-11"), "the wake lands on its local day")
		AssertFalse(KLW.batch["system_day"].Has("2026-11-10"), "not on its UTC day")
		AssertEqual(1, KLW.batch["system_day"]["2026-11-11"]["night_wake_count"], "01:30 local is a night wake")
		KLW_WalkSystemEvent(Map("timestamp", "2026-11-11 01:30:00.000", "utc_offset_min", -600, "action", "wake",
			"duration_ms", 1000))
		AssertEqual(0, KLW.batch["system_day"]["2026-11-10"]["night_wake_count"],
			"01:30 UTC ten hours west is 15:30 the day before, no night wake")
		AssertEqual(1, KLW.batch["system_day"]["2026-11-11"]["night_wake_count"])

		KLW_WalkTypingEntry(Map("timestamp", Utc, "utc_offset_min", 120, "app", "Editor", "events", [["a", 100]]))
		HourDay := ""
		for _, Row in KLW.batch["hourly"]
			HourDay .= Row["date"] . " " . Row["hour"] . ";"
		AssertEqual("2026-11-11 01;", HourDay, "the typing lands in its local hour of its local day")
		Slot := ""
		for _, Row in KLW.batch["hourly_min5"]
			Slot .= Row["slot"] . ";"
		AssertEqual("01:30;", Slot, "and in its local 5-minute slot")

		KLW_WalkAppSwitch(Map("timestamp", Utc, "utc_offset_min", 120, "prev_app", "Editor", "next_app", "Mail",
			"duration_ms", 7))
		KLW_WalkWindowSwitch(Map("timestamp", Utc, "utc_offset_min", 120, "app", "Editor", "prev_title", "Doc",
			"duration_ms", 9))
		for _, Row in KLW.batch["app_time"]
			AssertEqual("2026-11-11", Row["date"], "the app time lands on its local day")
		for _, Row in KLW.batch["switches_to"]
			AssertEqual("2026-11-11", Row["date"], "the switch lands on its local day")
		Titles := 0
		for _, Row in KLW.batch["titles"]
			if (Row["title"] = "Doc") {
				Titles += 1
				AssertEqual("2026-11-11", Row["date"], "the title time lands on its local day")
			}
		AssertEqual(1, Titles)

		; A journal entry has no offset: its stamp is local already.
		KLW_WalkSystemEvent(Map("timestamp", "2026-11-12 02:00:00.000", "action", "wake", "duration_ms", 1))
		AssertEqual(1, KLW.batch["system_day"]["2026-11-12"]["night_wake_count"], "a local stamp is read as it is")
	} finally {
		KLW.batch := SavedBatch
		KLW.ctx := SavedContext
	}
}
Test("KMD-1: the walker's days, hours and night wakes use ts plus the offset (utc-offset-rows)",
	_KLUOR_WalkerReadsLocalTime)

; Replays rows of three shapes through the reader: a row with its offset, an
; older Windows row in local time, an older Linux row in UTC (read with this
; device's current offset), and checks the SQL local time the hourly rollups use.
_KLUOR_ReplayReadsEachRowShape() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	_KLRDC_EnsureSharedDir()
	Db := SQLite_Open(":memory:")
	try {
		AssertTrue(KLR_LoadSchema(Db))
		LinuxUtc := "2026-11-13 23:30:00"
		LinuxLocal := KL_TimestampShift(LinuxUtc, KL_CurrentUtcOffset())
		Meta := SQLite_Q('{"duration_ms":1000}')
		_KLUOR_Devices(Db)
		AssertTrue(SQLite_Exec(Db, "INSERT INTO events_system (device_id, id, ts, date, action, metadata_json, utc_offset_min) VALUES "
			. "('pc', 1, '2026-11-10 23:30:00.000', '2026-11-11', 'wake', " . Meta . ", 120),"
			. "('pc', 2, '2026-11-12 01:30:00.000', '2026-11-12', 'wake', " . Meta . ", NULL),"
			. "('tux', 1, " . SQLite_Q(LinuxUtc) . ", " . SQLite_Q(SubStr(LinuxLocal, 1, 10)) . ", 'wake', " . Meta . ", NULL);"))
		AssertTrue(KLR_RebuildWalkerAggregates(Db) >= 0, "the replay walks the rows")
		Night := Map()
		for Row in SQLite_Query(Db, "SELECT device_id, date, night_wake_count FROM agg_system_day WHERE night_wake_count > 0;")
			Night[Row["device_id"] . " " . Row["date"]] := Row["night_wake_count"]
		AssertEqual(1, Night.Get("pc 2026-11-11", 0), "a row with an offset is a night wake of its local day")
		AssertEqual(1, Night.Get("pc 2026-11-12", 0), "an older Windows row is read as local time")
		AssertEqual(KLW_IsNightWake(LinuxLocal) ? 1 : 0, Night.Get("tux " . SubStr(LinuxLocal, 1, 10), 0),
			"an older Linux row is read with this device's offset")
		AssertFalse(Night.Has("pc 2026-11-10"), "never on the UTC day")

		LocalRows := Map()
		for Row in SQLite_Query(Db, "SELECT e.device_id, e.id, substr(" . KLR_LocalTsSql("e") . ", 1, 16) AS lts FROM events_system AS e;")
			LocalRows[Row["device_id"] . Row["id"]] := Row["lts"]
		AssertEqual("2026-11-11 01:30", LocalRows["pc1"], "the rollups' local time adds the row's offset")
		AssertEqual("2026-11-12 01:30", LocalRows["pc2"], "and reads an older Windows row as it is")
		AssertEqual(SubStr(LinuxLocal, 1, 16), LocalRows["tux1"], "and an older Linux row with this device's offset")
	} finally {
		SQLite_Close(Db)
	}
}
Test("KMD-1: the reader's replay and rollups read each row shape in local time (utc-offset-rows)",
	_KLUOR_ReplayReadsEachRowShape)





; ======================================
; ======================================
; ======= 4/ The migration shape =======
; ======================================
; ======================================

; The reader derives its statements from schema.sql and purge_schema.sql; they
; are the ones _shared/metrics/engine/utc_offset_column.lua writes.
_KLUOR_MigrationMatchesSharedLua() {
	global _SharedDir
	_KLRDC_EnsureSharedDir()
	Lua := FileRead(_SharedDir . "\metrics\engine\utc_offset_column.lua", "UTF-8")
	AssertTrue(RegExMatch(Lua, "s)M\.TABLES = \{(.*?)\}", &Block) > 0, "the Lua module lists its tables")
	LuaTables := []
	Position := 1
	while Position := RegExMatch(Block[1], '"(events_\w+)"', &Found, Position) {
		LuaTables.Push(Found[1])
		Position += Found.Len[0]
	}
	AssertEqual(_KLUOR_Join(LuaTables, ","), _KLUOR_Join(KLR_UtcOffsetShape()["tables"], ","),
		"the raw tables are the Lua module's, in its order")
	; 9359288f59 builds the Lua definition from local_time.MAX_OFFSET_MIN; the
	; Windows one must spell the same CHECK with the same bound.
	LocalTime := FileRead(_SharedDir . "\metrics\engine\local_time.lua", "UTF-8")
	AssertTrue(RegExMatch(LocalTime, "m)^M\.MAX_OFFSET_MIN = (\d+)$", &Bound) > 0, "local_time declares its widest offset")
	Expected := "INTEGER CHECK (utc_offset_min IS NULL OR (typeof(utc_offset_min) = 'integer'"
		. " AND utc_offset_min BETWEEN -" . Bound[1] . " AND " . Bound[1] . "))"
	AssertTrue(InStr(Lua, 'BETWEEN -" .. MAX_OFFSET_MIN .. " AND " .. MAX_OFFSET_MIN') > 0,
		"the Lua module bounds its CHECK by MAX_OFFSET_MIN")
	AssertEqual(Expected, KLR_UtcOffsetShape()["definition"], "the column definition is the Lua module's")

	Purge := FileRead(_SharedDir . "\metrics\data\db\purge_schema.sql", "UTF-8")
	Statements := KLR_UtcOffsetStatements(["events_av", "events_typing"], Purge)
	Expected := ["ALTER TABLE events_av ADD COLUMN utc_offset_min " . KLR_UtcOffsetShape()["definition"] . ";",
		"ALTER TABLE events_typing ADD COLUMN utc_offset_min " . KLR_UtcOffsetShape()["definition"] . ";",
		"DROP TRIGGER IF EXISTS metrics_purge_apply;"]
	for Name in LuaTables
		Expected.Push("DROP TRIGGER IF EXISTS metrics_purge_guard_" . SubStr(Name, 8) . ";")
	AssertEqual(_KLUOR_Join(Expected, "`n"), _KLUOR_Join(Statements, "`n"),
		"the statements are utc_offset_column.statements(): the ALTERs, then the 16 trigger drops")
	AssertEqual(0, KLR_UtcOffsetStatements([], Purge).Length, "no statement when no table lacks the column")
}
Test("KMD-1: the reader's migration writes utc_offset_column.lua's statements (utc-offset-rows)",
	_KLUOR_MigrationMatchesSharedLua)
