; tests/unit/test_klr_sql_operational_retry.ahk

; ==============================================================================
; MODULE: Reader SQL Operational Retry Tests
; DESCRIPTION: Resource failures must not become stable incomplete ledger bytes.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRSOR_PrepareLimit(Db, Terminator) {
	Sql := "SELECT 'synthetic resource limit fixture'" . Terminator
	; SQLITE_LIMIT_SQL_LENGTH is connection-local and restored before recovery.
	Previous := DllCall(SQLiteConst.DLL . "\sqlite3_limit", "Ptr", Db, "Int", 1, "Int", 12, "Int")
	try {
		Result := SQLite_ExecReturnCarry(Db, Sql)
		AssertEqual(18, SQLite_LastErrorCode(Db) & 0xFF, "the native prepare must refuse an oversized statement")
		AssertFalse(Result["ok"], "a resource refusal must not masquerade as incomplete SQL")
		AssertTrue(Result.Get("retry", false), "resource recovery must not require changed source bytes")
	} finally DllCall(SQLiteConst.DLL . "\sqlite3_limit", "Ptr", Db, "Int", 1, "Int", Previous, "Int")
	AssertTrue(SQLite_ExecReturnCarry(Db, Sql)["ok"], "the identical statement must succeed after resource recovery")
	_SQLRD_AssertNoStatements(Db)
}

_KLRSOR_ResidentRecovery() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	SavedBatch := KLW.batch
	KLW_ResetBatch()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRHU_Row("dev-one", 1, "2026-01-01", "fixture", "x", "abcd", 3))
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0)
		AssertFalse(KLRCache.disposable)
		Offset := KLRCache.last_sizes[_KLRDC_LedgerPath()]
		AssertTrue(SQLite_Exec(Db, "CREATE TRIGGER refuse_tail BEFORE INSERT ON events_hotstring "
			. "BEGIN SELECT RAISE(ABORT,'synthetic private insert refusal');END;"))
		_KLRDC_AppendLedger(_KLRHU_Row("dev-one", 2, "2026-01-02", "fixture", "x", "abcd", 3))
		Snapshot := KLR_LedgerSnapshot(_KLRDC_LedgerPath())
		AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()))
		AssertEqual(Offset, KLRCache.last_sizes[_KLRDC_LedgerPath()])
		AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_hotstring;")[1]["n"])
		AssertTrue(SQLite_Exec(Db, "DROP TRIGGER refuse_tail;"))
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(KLR_LedgerSnapshotIsSame(Snapshot, KLR_LedgerSnapshot(_KLRDC_LedgerPath())))
		AssertEqual(2, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_hotstring;")[1]["n"],
			"a recovered database refusal must retry unchanged ledger bytes")
		AssertEqual(Snapshot["size"], KLRCache.last_sizes[_KLRDC_LedgerPath()])
	} finally {
		_KLRDC_Cleanup()
		KLW.batch := SavedBatch
	}
}

Test("SQLite reader: resident retries after a database refusal (reader-sql-operational-retry)",
	_KLRDC_CheckTeardown.Bind(_KLRSOR_ResidentRecovery))

for Terminator in ["", ";"]
	Test("SQLite reader: resource refusal is retryable terminator=" . StrLen(Terminator) . " (reader-sql-operational-retry)",
		_SQLRD_WithDatabase.Bind(_KLRSOR_PrepareLimit.Bind(, Terminator)))
