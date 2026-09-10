; tests/unit/test_hotstring_count_units.ahk

; ==============================================================================
; MODULE: Hotstring Count Unit Replay Tests
; DESCRIPTION: Declared Windows units preserve redaction parity across cold and incremental readers.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRHU_Row(Device, Id, Day, App, Trigger, Replacement, Net) {
	return "INSERT INTO events_hotstring(device_id,id,ts,date,app,kind,trigger,replacement,h_type,net_saved_chars) VALUES("
		. SQLite_Q(Device) . "," . Id . "," . SQLite_Q(Day . " 10:00:00.000") . "," . SQLite_Q(Day)
		. "," . SQLite_Q(App) . ",'fired'," . SQLite_Q(Trigger) . "," . SQLite_Q(Replacement) . ",'static'," . Net . ");"
}

_KLRHU_Declare(Device) {
	return "INSERT OR IGNORE INTO meta(key,value) VALUES(" . SQLite_Q("hotstring_count_unit:" . Device) . ",'utf16');"
}

_KLRHU_MixedDevices(Db) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	AssertTrue(KLR_EnsureTypingProjectionTable(Db))
	Trigger := Chr(0x1F600)
	AssertTrue(SQLite_Exec(Db, _KLRHU_Declare("win'Ω")
		. _KLRHU_Row("win'Ω", 1, "2026-01-01", "public", Trigger, "abcd", 2)
		. _KLRHU_Row("win'Ω", 2, "2026-01-01", "masked", "**", "****", 2)
		. _KLRHU_Row("mac", 1, "2026-01-01", "scalar", Trigger, "abcd", 3)))
	AssertTrue(KLR_RebuildAggregates(Db))
	Rows := SQLite_Query(Db, "SELECT app,hs_chars,hs_input_chars FROM agg_app_day ORDER BY app;")
	AssertEqual(3, Rows.Length)
	for Row in Rows {
		AssertEqual(4, Row["hs_chars"], "redaction must not change gross expansion accounting")
		AssertEqual(Row["app"] = "scalar" ? 1 : 2, Row["hs_input_chars"],
			"declared Windows units must not change an unmarked scalar device")
	}
}

_KLRHU_FirstDeclarationRefreshesHistory() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	SavedBatch := KLW.batch
	KLW_ResetBatch()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRHU_Row("dev-one", 1, "2026-01-01", "fixture", Chr(0x1F600), "abcd", 2))
		Db := _KLRDC_BuildAsWorker()
		AssertEqual(1, SQLite_Query(Db, "SELECT hs_input_chars FROM agg_app_day;")[1]["hs_input_chars"],
			"an undeclared legacy row must not be guessed from its net saving")
		_KLRDC_AppendLedger(_KLRHU_Declare("dev-one")
			. _KLRHU_Row("dev-one", 2, "2026-01-02", "fixture", "x", "abcd", 3))
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0)
		Rows := SQLite_Query(Db, "SELECT date,hs_chars,hs_input_chars FROM agg_app_day ORDER BY date;")
		AssertEqual(2, Rows.Length)
		AssertEqual(2, Rows[1]["hs_input_chars"], "the first declaration must also refresh the historical day")
		AssertEqual(4, Rows[1]["hs_chars"])
		AssertEqual(1, Rows[2]["hs_input_chars"])
		AssertTrue(SQLite_Exec(Db, "CREATE TRIGGER refuse_old_recount BEFORE UPDATE ON agg_app_day "
			. "WHEN OLD.date='2026-01-01' BEGIN SELECT RAISE(ABORT,'unexpected historical recount');END;"))
		_KLRDC_AppendLedger(_KLRHU_Declare("dev-one")
			. _KLRHU_Row("dev-one", 3, "2026-01-03", "fixture", "x", "abcd", 3))
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0, "an identical declaration must not repeat the historical recount")
		AssertEqual(3, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM agg_app_day;")[1]["n"])
	} finally {
		_KLRDC_Cleanup()
		KLW.batch := SavedBatch
	}
}

_KLRHU_RecountFailurePreservesImage() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	SavedBatch := KLW.batch
	KLW_ResetBatch()
	Stored := 0
	try {
		Base := _KLRDC_Header() . _KLRHU_Row("dev-one", 1, "2026-01-01", "fixture", Chr(0x1F600), "abcd", 2)
		_KLRDC_WriteLedger(Base)
		_KLRDC_BuildAsWorker()
		Offset := KLRCache.last_sizes[_KLRDC_LedgerPath()]
		Tail := _KLRHU_Declare("dev-one") . _KLRHU_Row("dev-one", 2, "2026-01-02", "fixture", "x", "abcd", 3)
		Fault := "CREATE TRIGGER refuse_unit_recount BEFORE UPDATE ON agg_app_day "
			. "WHEN OLD.date='2026-01-01' BEGIN SELECT RAISE(ABORT,'synthetic unit recount refusal');END;"
		_KLRDC_AppendLedger(Fault . Tail)
		AssertEqual(0, KLR_BuildDatabase(_KLRDC_Root()), "a failed private recount must not publish")
		AssertEqual(0, KLRCache.db)
		Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
		AssertTrue(Stored != 0)
		AssertEqual(Offset, SQLite_Query(Stored, "SELECT end_offset FROM klr_cache_ledger;")[1]["end_offset"])
		AssertEqual(1, SQLite_Query(Stored, "SELECT COUNT(*) AS n FROM events_hotstring;")[1]["n"])
		AssertEqual(1, SQLite_Query(Stored, "SELECT hs_input_chars FROM agg_app_day;")[1]["hs_input_chars"])
		AssertEqual(0, KLHotstringUnits.Read(Stored).Count, "the failed declaration must not escape into the disk image")
		SQLite_Close(Stored)
		Stored := 0
		_KLRDC_WriteLedger(Base . Tail)
		Db := _KLRDC_BuildAsWorker()
		AssertEqual(2, SQLite_Query(Db, "SELECT hs_input_chars FROM agg_app_day WHERE date='2026-01-01';")[1]["hs_input_chars"],
			"a repaired source must recover the historical units")
	} finally {
		SQLite_Close(Stored)
		_KLRDC_Cleanup()
		KLW.batch := SavedBatch
	}
}

_KLRHU_WriterRoundTrip(Db) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	AssertTrue(KLR_EnsureTypingProjectionTable(Db))
	SavedDevice := Keylogger._device_id_lit
	try {
		Keylogger._device_id_lit := SQLite_Q("writer'Ω")
		Expected := Map()
		Vectors := ["ascii", "éà", "e" . Chr(0x301), Chr(0x10000), Chr(0x40000),
			Chr(0x80000), Chr(0xC0000), Chr(0x10FFFF), Chr(0x1F600) . "x"]
		for Index, Trigger in Vectors {
			Replacement := Trigger . "abcd"
			Entry := Map("timestamp", "2026-01-01 10:00:00.000", "app", "app" . Index,
				"trigger", Trigger, "replacement", Replacement,
				"net_saved_chars", StrLen(Replacement) - StrLen(Trigger))
			Sql := KL_BuildInsertHotstring(Entry, Index, "fired")
			AssertTrue(SQLite_Exec(Db, Sql), "new writer output must replay on the existing canonical schema")
			AssertTrue(SQLite_Exec(Db, Sql), "the declaration and event must remain idempotent")
			Expected[Entry["app"]] := [StrLen(Trigger), StrLen(Replacement)]
		}
		AssertEqual("utf16", SQLite_Query(Db, "SELECT value FROM meta WHERE key="
			. SQLite_Q("hotstring_count_unit:writer'Ω") . ";")[1]["value"])
		AssertTrue(KLR_RebuildAggregates(Db))
		Rows := SQLite_Query(Db, "SELECT app,hs_chars,hs_input_chars,hs_triggers FROM agg_app_day;")
		AssertEqual(Expected.Count, Rows.Length)
		for Row in Rows {
			AssertEqual(Expected[Row["app"]][1], Row["hs_input_chars"])
			AssertEqual(Expected[Row["app"]][2], Row["hs_chars"])
			AssertEqual(1, Row["hs_triggers"])
		}
	} finally Keylogger._device_id_lit := SavedDevice
}

_KLRHU_UnsupportedDeclaration(Db, Unit) {
	_KLRDC_EnsureSharedDir()
	AssertTrue(KLR_LoadSchema(Db))
	AssertTrue(KLR_EnsureTypingProjectionTable(Db))
	AssertTrue(SQLite_Exec(Db, "INSERT INTO meta(key,value) VALUES('hotstring_count_unit:device'," . SQLite_Q(Unit) . ");"))
	AssertFalse(KLR_RebuildAggregates(Db), "unknown declared units must fail before publishing guessed metrics")
}

Test("hotstring units: marked Windows and unmarked scalar devices coexist (hotstring-count-units)",
	_SQLRD_WithDatabase.Bind(_KLRHU_MixedDevices))
Test("hotstring units: first declaration refreshes historical days (hotstring-count-units)",
	_KLRDC_CheckTeardown.Bind(_KLRHU_FirstDeclarationRefreshesHistory))
Test("hotstring units: writer receipts preserve native Unicode counts (hotstring-count-units)",
	_SQLRD_WithDatabase.Bind(_KLRHU_WriterRoundTrip))
Test("hotstring units: failed recount preserves the durable image (hotstring-count-units)",
	_KLRDC_CheckTeardown.Bind(_KLRHU_RecountFailurePreservesImage))
for Unit in ["unsupported", "UTF16"]
	Test("hotstring units: unsupported declaration " . Unit . " refuses aggregation (hotstring-count-units)",
		_SQLRD_WithDatabase.Bind(_KLRHU_UnsupportedDeclaration.Bind(, Unit)))
