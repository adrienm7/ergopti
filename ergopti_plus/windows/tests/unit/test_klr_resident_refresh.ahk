; tests/unit/test_klr_resident_refresh.ahk

; ==============================================================================
; MODULE: Resident Reader Refresh Tests
; DESCRIPTION: Failed rollups must preserve the published resident projection.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRRF_FailedRefresh() {
	SavedBatch := KLW.batch
	SavedDevice := Keylogger._device_id_lit
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "code.exe", ["a", "b"]))
		Db := _KLRDC_BuildAsWorker()
		KLRCache.disposable := false
		KLW_ResetBatch()
		Keylogger._device_id_lit := "'dev-one'"
		KLW.batch["app_day"]["pending"] := Map("date", "2026-01-01", "app", "code.exe", "time_ms", 5)
		Pending := KLW.batch
		AssertTrue(SQLite_Exec(Db, "UPDATE agg_app_day SET chars=7;"
			. "CREATE TRIGGER reject_hourly BEFORE INSERT ON agg_app_day_hourly "
			. "BEGIN SELECT RAISE(ABORT,'fixture hourly rejected'); END;"))
		Before := _KLRDC_DerivedFingerprint(Db)
		AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()), "failed refresh must retain the published handle")
		AssertEqual(Before, _KLRDC_DerivedFingerprint(Db),
			"a later rollup failure must undo earlier writes to the published projection")
		AssertTrue(SQLite_IsAutocommit(Db), "failed refresh must release its transaction")
		AssertTrue(KLW.batch = Pending, "failed rollups must not consume the pending live accumulator")
		AssertTrue(SQLite_Exec(Db, "DROP TRIGGER reject_hourly;"))
		AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()))
		AssertEqual(2, SQLite_Query(Db, "SELECT chars FROM agg_app_day;")[1]["chars"],
			"removing the failure must allow the real SQL rollup to replace the sentinel")
		AssertEqual(245, SQLite_Query(Db, "SELECT time_ms FROM agg_app_day;")[1]["time_ms"])
		AssertEqual(0, KLW.batch["app_day"].Count, "successful retry must drain the pending live contribution")
		AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()))
		AssertEqual(245, SQLite_Query(Db, "SELECT time_ms FROM agg_app_day;")[1]["time_ms"],
			"a later empty refresh must not count the live contribution twice")
	} finally {
		KLW.batch := SavedBatch
		Keylogger._device_id_lit := SavedDevice
		_KLRDC_Cleanup()
	}
}
Test("KLR resident refresh: later SQL failure preserves the published projection (klr-resident-refresh)",
	_KLRDC_CheckTeardown.Bind(_KLRRF_FailedRefresh))

_KLRRF_OuterTransaction() {
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0)
	try {
		AssertTrue(SQLite_Exec(Db, "CREATE TABLE sentinel(n);BEGIN;INSERT INTO sentinel VALUES(17);"))
		AssertFalse(KLR_RefreshResidentAggregates(Db), "refresh must reject a caller-owned transaction")
		AssertFalse(SQLite_IsAutocommit(Db), "rejection must not commit or roll back the caller's work")
		AssertEqual(17, SQLite_Query(Db, "SELECT n FROM sentinel;")[1]["n"])
		AssertTrue(SQLite_Exec(Db, "ROLLBACK;"))
		AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM sentinel;")[1]["n"])
	} finally SQLite_Close(Db)
}
Test("KLR resident refresh: caller transaction retains ownership (klr-resident-refresh)", _KLRRF_OuterTransaction)

_KLRRF_DenyTransaction(Wanted, State, Context, Action, Argument, Other, Database, Trigger) {
	; SQLITE_TRANSACTION is 22; SQLITE_DENY is 1.
	if Action = 22 && Argument && StrGet(Argument, "UTF-8") = Wanted {
		State["denied"] += 1
		return 1
	}
	return 0
}

_KLRRF_TransactionFailure(Stage) {
	SavedBatch := KLW.batch
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Callback := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "code.exe", ["a", "b"]))
		Db := _KLRDC_BuildAsWorker()
		KLRCache.disposable := false
		KLW_ResetBatch()
		AssertTrue(SQLite_Exec(Db, "UPDATE agg_app_day SET chars=7;"))
		Before := _KLRDC_DerivedFingerprint(Db)
		if Stage = "ROLLBACK"
			AssertTrue(SQLite_Exec(Db, "CREATE TRIGGER reject_hourly BEFORE INSERT ON agg_app_day_hourly "
				. "BEGIN SELECT RAISE(ABORT,'fixture hourly rejected'); END;"))
		State := Map("denied", 0)
		Callback := CallbackCreate(_KLRRF_DenyTransaction.Bind(Stage, State), "C", 6)
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", Callback, "Ptr", 0, "Cdecl Int"))
		Result := KLR_BuildDatabase(_KLRDC_Root())
		AssertEqual(1, State["denied"], "the requested native transaction failure must be reached")
		if Stage = "ROLLBACK" {
			AssertEqual(0, Result, "an unrollbackable partial projection must not be returned")
			AssertEqual(0, KLRCache.db, "failed rollback must invalidate the published handle")
			AssertEqual(0, KLRCache.last_sizes.Count, "offsets must be invalidated with their database")
		} else {
			AssertEqual(Db, Result)
			AssertTrue(SQLite_IsAutocommit(Db))
			AssertEqual(Before, _KLRDC_DerivedFingerprint(Db), "failed transaction boundary must preserve the prior rows")
			AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
				"Ptr", Db, "Ptr", 0, "Ptr", 0, "Cdecl Int"))
			AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()))
			AssertEqual(2, SQLite_Query(Db, "SELECT chars FROM agg_app_day;")[1]["chars"])
		}
	} finally {
		try _KLRDC_Cleanup()
		finally {
			if Callback
				CallbackFree(Callback)
			KLW.batch := SavedBatch
		}
	}
}
for Stage in ["BEGIN", "COMMIT", "ROLLBACK"]
	Test("KLR resident refresh: transaction failure " . Stage . " rejects partial publication (klr-resident-refresh)",
		_KLRDC_CheckTeardown.Bind(_KLRRF_TransactionFailure.Bind(Stage)))
