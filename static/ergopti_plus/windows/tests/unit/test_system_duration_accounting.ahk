; tests/unit/test_system_duration_accounting.ahk

; ==============================================================================
; MODULE: System Duration Accounting Tests
; DESCRIPTION: Preserve measured passive categories through SQL rebuilds and cache upgrades.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRSDA_Row(Device, Id, Day, Action, Metadata) {
	return "INSERT OR IGNORE INTO events_system(device_id,id,ts,date,action,metadata_json) VALUES("
		. SQLite_Q(Device) . "," . Id . "," . SQLite_Q(Day . " 10:00:00.000") . ","
		. SQLite_Q(Day) . "," . SQLite_Q(Action) . "," . SQLite_Q(KL_JsonEncode(Metadata)) . ");"
}

_KLRSDA_Assert(Row, Locked, Sleep, Awake) {
	AssertEqual(Locked, Row["locked_ms"], "only measured lock intervals belong to locked time")
	AssertEqual(Sleep, Row["sleep_ms"], "resume durations belong to sleep time")
	AssertEqual(Awake, Row["awake_ms"], "only keep-awake intervals belong to awake time")
}

_KLRSDA_Protocol(Db) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	AssertTrue(KLR_EnsureTypingProjectionTable(Db))
	Sql := ""
	for Index, Kind in ["lock", "sleep", "awake"]
		Sql .= _KLRSDA_Row("current", Index, "2026-01-01", "passive_period",
			Map("kind", Kind, "duration_ms", Index * 100))
	; A focus attribution describes the same awake interval, not a second one.
	Sql .= _KLRSDA_Row("current", 4, "2026-01-01", "awake_focus", Map("duration_ms", 300, "app", "fixture"))
	for Index, Action in ["lock", "sleep"]
		Sql .= _KLRSDA_Row("current", 4 + Index, "2026-01-01", Action, Map("duration_ms", 999))
	Sql .= _KLRSDA_Row("current", 7, "2026-01-01", "passive_period", Map("kind", "unknown", "duration_ms", 999))
	Sql .= _KLRSDA_Row("legacy'Ω", 1, "2026-01-01", "unlock", Map("duration_ms", 40))
	Sql .= _KLRSDA_Row("legacy'Ω", 2, "2026-01-01", "wake", Map("duration_ms", 50))
	AssertTrue(SQLite_Exec(Db, Sql))
	AssertTrue(SQLite_Exec(Db, "INSERT INTO agg_system_day(device_id,date,space_switches,passive_count)"
		. " VALUES('current','2026-01-01',7,3);"))
	AssertTrue(KLR_RebuildAggregates(Db))
	Rows := SQLite_Query(Db, "SELECT * FROM agg_system_day ORDER BY device_id;")
	AssertEqual(2, Rows.Length)
	_KLRSDA_Assert(Rows[1], 100, 200, 300)
	_KLRSDA_Assert(Rows[2], 40, 50, 0)
	AssertEqual(7, Rows[1]["space_switches"], "SQL must preserve walker-owned fields")
	AssertEqual(3, Rows[1]["passive_count"])
	AssertTrue(KLR_RebuildAggregates(Db, Map("2026-01-01", true)))
	Rows := SQLite_Query(Db, "SELECT * FROM agg_system_day ORDER BY device_id;")
	_KLRSDA_Assert(Rows[1], 100, 200, 300)
	_KLRSDA_Assert(Rows[2], 40, 50, 0)
}

_KLRSDA_Replay() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	SavedBatch := KLW.batch
	KLW_ResetBatch()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRSDA_Row("dev-one", 10, "2026-01-01",
			"passive_period", Map("kind", "sleep", "duration_ms", 200)))
		Db := _KLRDC_BuildAsWorker()
		_KLRSDA_Assert(SQLite_Query(Db, "SELECT * FROM agg_system_day;")[1], 0, 200, 0)
		_KLRDC_AppendLedger(_KLRSDA_Row("dev-one", 1, "2026-01-01",
			"passive_period", Map("kind", "sleep", "duration_ms", 50))
			. _KLRSDA_Row("dev-one", 2, "2026-01-02",
				"passive_period", Map("kind", "lock", "duration_ms", 80)))
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0)
		Rows := SQLite_Query(Db, "SELECT * FROM agg_system_day ORDER BY date;")
		AssertEqual(2, Rows.Length)
		_KLRSDA_Assert(Rows[1], 0, 250, 0)
		_KLRSDA_Assert(Rows[2], 80, 0, 0)
		CachePath := KLR_CachePath(_KLRDC_Root())
		KLR_ResetCache()
		Stored := SQLite_Open(CachePath)
		AssertTrue(Stored != 0)
		try {
			AssertTrue(SQLite_Exec(Stored, "UPDATE klr_cache_meta SET value='7' WHERE key='format_version';"
				. "UPDATE agg_system_day SET locked_ms=0,sleep_ms=0,awake_ms=777;"))
		} finally SQLite_Close(Stored)
		AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), ""),
			"the previous accounting format must not preserve mislabeled historical totals")
		Db := _KLRDC_BuildAsWorker()
		Rows := SQLite_Query(Db, "SELECT * FROM agg_system_day ORDER BY date;")
		AssertEqual(2, Rows.Length)
		_KLRSDA_Assert(Rows[1], 0, 250, 0)
		_KLRSDA_Assert(Rows[2], 80, 0, 0)
	} finally {
		_KLRDC_Cleanup()
		KLW.batch := SavedBatch
	}
}

Test("system accounting: passive categories and legacy resume events agree (system-duration-accounting)",
	_SQLRD_WithDatabase.Bind(_KLRSDA_Protocol))
Test("system accounting: cold, tail and obsolete cache preserve durations (system-duration-accounting)",
	_KLRDC_CheckTeardown.Bind(_KLRSDA_Replay))
