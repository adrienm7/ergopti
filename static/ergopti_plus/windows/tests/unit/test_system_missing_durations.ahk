; tests/unit/test_system_missing_durations.ahk

; ==============================================================================
; MODULE: System Event Missing Duration Tests
; DESCRIPTION: Replay watcher transitions without inventing an unavailable duration.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRSMD_Replay(Action) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	SavedDevice := Keylogger._device_id_lit
	SavedBatch := KLW.batch
	Keylogger._device_id_lit := SQLite_Q("dev-one")
	KLW_ResetBatch()
	try {
		; Windows watchers emit transitions without duration metadata.
		First := KL_BuildInsertSystem(Map("timestamp", "2026-01-01 10:00:00.000",
			"action", Action), 1)
		_KLRDC_WriteLedger(_KLRDC_Header() . First)
		Db := _KLRDC_BuildAsWorker()
		_KLRSMD_AssertDays(Db, 1)
		Second := KL_BuildInsertSystem(Map("timestamp", "2026-01-02 10:00:00.000",
			"action", Action), 2)
		_KLRDC_AppendLedger(Second)
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0, "a durationless transition must not reject an incremental candidate")
		_KLRSMD_AssertDays(Db, 2)
		; Legacy JSON may explicitly carry null instead of omitting the field.
		_KLRDC_AppendLedger("INSERT INTO events_system(device_id,id,ts,date,action,metadata_json) VALUES("
			. "'dev-one',3,'2026-01-03 10:00:00.000','2026-01-03'," . SQLite_Q(Action)
			. ",'{" . Chr(34) . "duration_ms" . Chr(34) . ":null}');")
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0, "a null duration must retain the valid source event")
		_KLRSMD_AssertDays(Db, 3)
		_KLRDC_AppendLedger(KL_BuildInsertSystem(Map("timestamp", "2026-01-04 10:00:00.000",
			"action", "wake", "duration_ms", 125), 4))
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0)
		AssertEqual(125, SQLite_Query(Db, "SELECT locked_ms+sleep_ms+awake_ms AS duration"
			. " FROM agg_system_day WHERE date='2026-01-04';")[1]["duration"],
			"handling missing metadata must not erase a measured duration")
		AssertEqual(4, SQLite_Query(Db, "SELECT COUNT(*) AS c FROM events_system;")[1]["c"])
	} finally {
		_KLRDC_Cleanup()
		Keylogger._device_id_lit := SavedDevice
		KLW.batch := SavedBatch
	}
}

_KLRSMD_AssertDays(Db, Expected) {
	Rows := SQLite_Query(Db, "SELECT locked_ms,sleep_ms,awake_ms FROM agg_system_day;")
	AssertEqual(Expected, Rows.Length, "every transition day must remain publishable")
	for Row in Rows
		for Field in ["locked_ms", "sleep_ms", "awake_ms"]
			AssertEqual(0, Row[Field], "missing duration contributes no measured milliseconds")
}

for Action in ["lock", "sleep", "wake"]
	Test("system duration: absent " . Action . " metadata survives cold and incremental replay (system-missing-durations)",
		_KLRDC_CheckTeardown.Bind(_KLRSMD_Replay.Bind(Action)))

_KLRSMD_MetadataTypes() {
	for Json in ["{}", '{"duration_ms":null}'] {
		Entry := KLR_SystemRowToEntry(Map("ts", "2026-01-01 10:00:00.000",
			"action", "unlock", "metadata_json", Json))
		AssertFalse(Entry.Has("duration_ms"), "only absent or null duration uses the walker's default")
	}
	for Value in [0, 12.5, "", "invalid"] {
		Entry := KLR_SystemRowToEntry(Map("ts", "2026-01-01 10:00:00.000",
			"action", "wake", "metadata_json", KL_JsonEncode(Map("duration_ms", Value))))
		AssertTrue(Entry.Has("duration_ms"))
		AssertEqual(Type(Value), Type(Entry["duration_ms"]))
		AssertEqual(Value, Entry["duration_ms"], "present values must not be silently replaced")
	}
}
Test("system duration: null normalization preserves present value types (system-missing-durations)",
	_KLRSMD_MetadataTypes)
