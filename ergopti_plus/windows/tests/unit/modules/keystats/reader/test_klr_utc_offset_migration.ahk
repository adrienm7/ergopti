; tests/unit/modules/keystats/reader/test_klr_utc_offset_migration.ahk

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
; 3. The migration never loses a row: the ledger's older rows (written without
;    the column) keep their local ts and a NULL offset, read as local time. It
;    is idempotent (a migrated image plans nothing, a later worker adds no row,
;    an image missing the column on some tables only gains it there) and a
;    refused migration rolls back in full, so the next open migrates.
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
; @param Only {Array} The raw tables that lose the column; every one when unset.
_KLUOM_MakePreColumn(Path, Only := unset) {
	Db := SQLite_Open(Path)
	AssertTrue(Db != 0, "the saved image opens read-write")
	try {
		Triggers := SQLite_Query(Db, "SELECT name, tbl_name FROM sqlite_master WHERE type='trigger'"
			. " AND name LIKE 'metrics_purge_%' ORDER BY name;")
		AssertEqual(16, Triggers.Length, "the saved image carries the 16 purge triggers")
		Tables := _KLUOM_TablesWithColumn(Db)
		AssertEqual(15, Tables.Length, "the saved image has the column on the 15 raw tables")
		if IsSet(Only)
			Tables := Only
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
		AssertEqual(15 - Tables.Length, _KLUOM_TablesWithColumn(Db).Length, "only the chosen raw tables lose the column")
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
		_KLUOM_AssertOlderRowKept(Db)
		Purge := FSReadStrict(_SharedDir . "\metrics\data\db\purge_schema.sql")
		AssertEqual(0, KLR_UtcOffsetStatements(KLR_UtcOffsetMissing(Db), Purge).Length,
			"a migrated image plans no second migration")
		AssertTrue(KLR_EnsureUtcOffsetColumn(Db, Purge), "running the migration again is a no-op")
		KLR_ResetCache()

		; The next worker opens the migrated image: no duplicate, no loss
		Again := _KLRDC_BuildAsWorker()
		AssertEqual(1, _KLUOM_Count(Again, "events_typing"), "a later worker keeps the one older row")
		AssertEqual(1, _KLUOM_Count(Again, "events_shortcut"), "a later worker adds no second shortcut row")
		AssertEqual(1, _KLUOM_Count(Again, "events_network"), "a later worker adds no second network row")
		_KLUOM_AssertOlderRowKept(Again)
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

_KLUOM_Count(Db, Table) {
	return SQLite_Query(Db, "SELECT COUNT(*) AS n FROM " . Table . " WHERE device_id='dev-one';")[1]["n"]
}

; The ledger's row written before the column: its local ts unchanged, its
; offset NULL, so every reader takes it as local time (KMD-1).
_KLUOM_AssertOlderRowKept(Db) {
	Rows := SQLite_Query(Db, "SELECT ts, date, text, utc_offset_min IS NULL AS legacy FROM events_typing"
		. " WHERE device_id='dev-one' AND id=1;")
	AssertEqual(1, Rows.Length, "the older typing row survives the migration")
	AssertEqual("2026-11-10 09:00:00.000", Rows[1]["ts"], "the older row keeps its local ts")
	AssertEqual("2026-11-10", Rows[1]["date"], "the older row keeps its local day")
	AssertEqual("ab", Rows[1]["text"], "the older row keeps its text")
	AssertEqual(1, Rows[1]["legacy"], "the older row has no recorded offset")
}

_KLUOM_Join(Names) {
	Text := ""
	for Name in Names
		Text .= (A_Index > 1 ? "," : "") . Name
	return Text
}

; An image missing the column on some raw tables only (a partial older shape)
; gains it there, and a refused migration leaves the image as it was.
_KLUOM_PartialAndRefusedMigration() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Root := _KLRDC_Root()
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1, "2026-11-10 09:00:00.000", "2026-11-10", "Editor", ["a", "b"]))
		_KLRDC_BuildAsWorker()
		KLR_ResetCache()
		Path := KLR_CachePath(Root)
		_KLUOM_MakePreColumn(Path, ["events_network", "events_typing"])
		Purge := FSReadStrict(_SharedDir . "\metrics\data\db\purge_schema.sql")

		; A read-only handle refuses the first ALTER: the savepoint rolls back
		Ro := SQLite_Open(Path, SQLiteConst.OPEN_RO)
		AssertTrue(Ro != 0, "the pre-column image opens read-only")
		try {
			AssertEqual("events_network,events_typing", _KLUOM_Join(KLR_UtcOffsetMissing(Ro)),
				"only the two tables lack the column")
			AssertFalse(KLR_EnsureUtcOffsetColumn(Ro, Purge), "a refused migration reports the refusal")
			AssertContains(KLRCache.schema_refusal, "utc_offset_min", "the refusal names the migration")
			AssertEqual(2, KLR_UtcOffsetMissing(Ro).Length, "a refused migration changes no table")
			AssertEqual(16, SQLite_Query(Ro, "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='trigger'"
				. " AND name LIKE 'metrics_purge_%';")[1]["n"], "a refused migration drops no trigger")
		} finally {
			SQLite_Close(Ro)
		}
		KLR_ResetCache()

		; The next open migrates the two tables and keeps the older row
		Db := _KLRDC_BuildAsWorker()
		AssertEqual(15, _KLUOM_TablesWithColumn(Db).Length, "the partial image gains the column where it lacked it")
		_KLUOM_AssertOlderRowKept(Db)
		AssertEqual(1, _KLUOM_Count(Db, "events_typing"), "the partial migration keeps exactly the one row")
		KLR_ResetCache()
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR cache: a partial or refused utc_offset_min migration keeps every row and recovers (klr-utc-offset-migration)",
	_KLRDC_CheckTeardown.Bind(_KLUOM_PartialAndRefusedMigration))
