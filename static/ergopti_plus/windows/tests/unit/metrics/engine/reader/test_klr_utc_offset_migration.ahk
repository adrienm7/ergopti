; tests/unit/metrics/engine/reader/test_klr_utc_offset_migration.ahk

; ==============================================================================
; MODULE: Reader Cache utc_offset_min Migration Regression (KMD-1)
; DESCRIPTION:
; Since the shared catalogue's raw INSERTs name utc_offset_min (maintainer
; decision KMD-1 of 11 November 2026), a reader image saved before the column
; refused every new ledger row: SQLite answered "no such column" and the
; dashboard kept the last projection forever. The reader now adds the column to
; every raw table of such an image and renews its purge triggers before
; purge_schema.sql (the statements of _shared/metrics/engine/utc_offset_column.lua).
;
; FEATURES & RATIONALE:
; 1. The image is a real reader.sqlite saved by a worker in a temporary metrics
;    folder, rewritten to the pre-column shape (the column dropped, the purge
;    triggers replaced by older ones that read no offset), then reopened by a
;    second worker through KLR_BuildDatabase with a ledger tail the current
;    writer emitted.
; 2. Only functions that existed before the fix are called, so the test runs
;    unchanged against the original reader and fails there.
; ==============================================================================

#Requires AutoHotkey v2.0

; The raw tables of an image that carry utc_offset_min, by name.
_KLUOM_TablesWithColumn(Db) {
	Names := []
	for Row in SQLite_Query(Db, "SELECT m.name FROM sqlite_master m WHERE m.type='table' AND m.name LIKE 'events\_%' ESCAPE '\'"
			. " AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) p WHERE p.name='utc_offset_min') ORDER BY m.name;")
		Names.Push(Row["name"])
	return Names
}

; Rewrites a saved image into the shape an image saved before KMD-1 has.
_KLUOM_MakePreColumn(Path) {
	Db := SQLite_Open(Path)
	AssertTrue(Db != 0, "the saved image opens read-write")
	try {
		Triggers := SQLite_Query(Db, "SELECT name, tbl_name FROM sqlite_master WHERE type='trigger'"
			. " AND name LIKE 'metrics_purge_%' ORDER BY name;")
		AssertEqual(16, Triggers.Length, "the saved image carries the 16 purge triggers")
		Tables := _KLUOM_TablesWithColumn(Db)
		AssertEqual(15, Tables.Length, "the saved image has the column on the 15 raw tables")
		Sql := ""
		for Row in Triggers
			Sql .= "DROP TRIGGER " . Row["name"] . ";`n"
		for Name in Tables
			Sql .= "ALTER TABLE " . Name . " DROP COLUMN utc_offset_min;`n"
		; Same names, bodies that read no offset: CREATE TRIGGER IF NOT EXISTS
		; keeps them, so only a migration that drops them installs current ones.
		for Row in Triggers
			Sql .= "CREATE TRIGGER " . Row["name"] . " BEFORE INSERT ON " . Row["tbl_name"]
				. " WHEN 0 BEGIN SELECT RAISE(IGNORE); END;`n"
		AssertTrue(SQLite_Exec(Db, Sql), "the image takes the pre-column shape: " . SQLite_LastError(Db))
		AssertEqual(0, _KLUOM_TablesWithColumn(Db).Length, "no raw table keeps the column")
	} finally {
		SQLite_Close(Db)
	}
}

_KLUOM_PreColumnCacheAcceptsRowsAgain() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	SavedDevice := Keystats.device_id
	SavedLiteral := Keystats._device_id_lit
	try {
		Root := _KLRDC_Root()
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1, "2026-11-10 09:00:00.000", "2026-11-10", "Editor", ["a", "b"]))
		_KLRDC_BuildAsWorker()
		KLR_ResetCache()
		AssertTrue(FileExist(KLR_CachePath(Root)) != "", "the first worker saves its reader image")
		_KLUOM_MakePreColumn(KLR_CachePath(Root))

		Keystats.device_id := "dev-one"
		Keystats._device_id_lit := SQLite_Q("dev-one")
		Shortcut := KL_BuildInsertShortcut(Map("type", "shortcut", "timestamp", "2026-11-11 10:00:00.000",
			"app", "Editor", "key", "ctrl+s"), 2)
		Network := KL_BuildInsertNetworkEvent(Map("type", "network_change", "timestamp", "2026-11-11 10:00:01.000",
			"app", "Editor", "state", "connected"), 3)
		AssertContains(Shortcut, "utc_offset_min", "the current writer names the column")
		_KLRDC_AppendLedger("`n-- === ingest batch 2026-11-11 10:00:01.000 (offset 0 -> 0, 2 entry(ies)) ===`n"
			. "BEGIN TRANSACTION;`n" . Shortcut . "`n" . Network . "`nCOMMIT;`n")

		Db := _KLRDC_BuildAsWorker()
		Rows := SQLite_Query(Db, "SELECT id FROM events_shortcut WHERE device_id='dev-one'"
			. " UNION ALL SELECT id FROM events_network WHERE device_id='dev-one' ORDER BY id;")
		AssertEqual(2, Rows.Length, "the existing pre-column image accepts the new raw INSERTs")
		AssertEqual(15, _KLUOM_TablesWithColumn(Db).Length, "every raw table gained the column")
		for Name in _KLUOM_TablesWithColumn(Db) {
			Columns := SQLite_Query(Db, "SELECT name FROM pragma_table_info(" . SQLite_Q(Name) . ") ORDER BY cid DESC LIMIT 1;")
			AssertEqual("utc_offset_min", Columns[1]["name"], Name . " lists the column last, as a fresh schema does")
		}
		Current := SQLite_Query(Db, "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'metrics_purge_%'"
			. " AND sql LIKE '%utc_offset_min%';")
		AssertEqual(16, Current.Length, "the 16 purge triggers are the current ones, which read the offset")
		KLR_ResetCache()

		Saved := SQLite_Open(KLR_CachePath(Root), SQLiteConst.OPEN_RO)
		AssertTrue(Saved != 0, "the migrated image was saved for the next worker")
		try AssertEqual(15, _KLUOM_TablesWithColumn(Saved).Length, "the saved image keeps the column")
		finally SQLite_Close(Saved)
	} finally {
		Keystats.device_id := SavedDevice
		Keystats._device_id_lit := SavedLiteral
		_KLRDC_Cleanup()
	}
}
Test("KLR cache: an image saved before utc_offset_min migrates and accepts raw INSERTs again (klr-utc-offset-migration)",
	_KLRDC_CheckTeardown.Bind(_KLUOM_PreColumnCacheAcceptsRowsAgain))
