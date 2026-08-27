; tests/unit/test_keylogger_shortcut_projection.ahk
;
; ==============================================================================
; MODULE: Durable Shortcut Projection Tests
; DESCRIPTION:
; Proves that the raw events_shortcut rows written by the live ingest path are
; replayed into the same shortcut n-grams as direct walker delivery.
; ==============================================================================

_KLRShortcut_OpenFixture() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the shortcut fixture must keep the real SQLite DLL loaded")
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the shortcut fixture must open an in-memory DB")
	AssertTrue(KLR_LoadSchema(db),
		"the shortcut fixture must use the canonical production schema")
	return db
}

_KLRShortcut_AssertProjection(db, ExpectedCount := 1) {
	rows := SQLite_Query(db,
		"SELECT token,c FROM ngram_shortcuts WHERE device_id='device-a' "
		. "AND date='2026-08-27' AND app='editor.exe' ORDER BY token;")
	AssertEqual(2, rows.Length, "both durable shortcuts must be projected")
	for _, row in rows
		AssertEqual(ExpectedCount, row["c"], "shortcut count must be idempotent")
	bigram_rows := SQLite_Query(db,
		"SELECT token,c FROM ngram_shortcut_bigrams WHERE device_id='device-a' "
		. "AND date='2026-08-27' AND app='editor.exe';")
	AssertEqual(1, bigram_rows.Length, "the ordered shortcut pair must be projected")
	AssertEqual("Ctrl+S→Ctrl+C", bigram_rows[1]["token"])
	AssertEqual(ExpectedCount, bigram_rows[1]["c"])
}

_KLRShortcut_LiveAndColdProjectionAgree() {
	saved_ctx := KLW.ctx
	saved_batch := KLW.batch
	saved_device_id := Keylogger.device_id
	saved_device_lit := Keylogger._device_id_lit
	saved_next_id := Keylogger.next_event_id
	db := _KLRShortcut_OpenFixture()
	try {
		KLW.ctx := Map()
		KLW_ResetBatch()
		AssertTrue(KLW_WalkShortcut(Map(
			"timestamp", "2026-08-27 21:30:00.000",
			"app", "editor.exe", "key", "Ctrl+S")))
		AssertTrue(KLW_WalkShortcut(Map(
			"timestamp", "2026-08-27 21:30:01.000",
			"app", "editor.exe", "key", "Ctrl+C")))
		AssertEqual(2,
			KLW.batch["sc_ngram"]["ngram_shortcuts"].Count,
			"direct delivery must project both shortcut tokens")
		AssertEqual(1,
			KLW.batch["sc_ngram"]["ngram_shortcut_bigrams"].Count,
			"direct delivery must project the ordered shortcut pair")

		Keylogger.device_id := "device-a"
		Keylogger._device_id_lit := SQLite_Q(Keylogger.device_id)
		Keylogger.next_event_id := 1
		for _, entry in [
			Map("type", "shortcut", "timestamp", "2026-08-27 21:30:00.000",
				"app", "editor.exe", "key", "Ctrl+S"),
			Map("type", "shortcut", "timestamp", "2026-08-27 21:30:01.000",
				"app", "editor.exe", "key", "Ctrl+C")
		] {
			for _, sql in KL_BuildInserts(entry)
				AssertTrue(SQLite_Exec(db, sql),
					"the live ingest SQL must persist the raw shortcut")
		}

		Loop 2 {
			KLR_ClearAggregates(db)
			AssertEqual(2, KLR_RebuildWalkerAggregates(db),
				"cold replay must consume both raw shortcut rows")
			_KLRShortcut_AssertProjection(db)
		}
	} finally {
		try SQLite_Close(db)
		KLW.ctx := saved_ctx
		KLW.batch := saved_batch
		Keylogger.device_id := saved_device_id
		Keylogger._device_id_lit := saved_device_lit
		Keylogger.next_event_id := saved_next_id
	}
}
Test("Keylogger reader: live shortcut ingest survives idempotent cold rebuild (shortcut-projection)",
	_KLRShortcut_LiveAndColdProjectionAgree)
