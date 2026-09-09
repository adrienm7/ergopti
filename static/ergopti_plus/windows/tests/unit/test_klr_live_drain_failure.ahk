; static/ergopti_plus/windows/tests/unit/test_klr_live_drain_failure.ahk

; ==============================================================================
; MODULE: Reader Live Drain Failure Tests
; DESCRIPTION: A rejected batch must remain retryable without partial SQL writes.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRLDF_RetryRejectedBatch() {
	SavedBatch := KLW.batch
	SavedDevice := Keylogger._device_id_lit
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0)
	try {
		_KLRDC_EnsureSharedDir()
		AssertTrue(KLR_LoadSchema(Db))
		Keylogger._device_id_lit := "'drain-device'"
		KLW_ResetBatch()
		KLW.batch["app_day"]["fixture"] := Map("date", "2026-09-09",
			"app", "drain.exe", "time_ms", 7)
		KLW.batch["system_day"]["fixture"] := Map("date", "2026-09-09",
			"space_switches", 1, "audio_muted_ms", 0, "passive_count", 0, "night_wake_count", 0)
		AssertTrue(SQLite_Exec(Db,
			"CREATE TRIGGER reject_drain BEFORE INSERT ON agg_system_day "
			. "BEGIN SELECT RAISE(ABORT,'fixture drain rejected'); END;"))
		Failure := 0
		BeforeCritical := A_IsCritical
		try KLR_InjectKlwBatch(Db)
		catch Error as Caught
			Failure := Caught
		AssertEqual(1, KLW.batch["app_day"].Count, "failed SQL must retain the pending batch")
		AssertEqual(BeforeCritical, A_IsCritical, "failed drain must restore the caller's interruptibility")
		AssertTrue(SQLite_IsAutocommit(Db), "failed drain must close its own transaction")
		AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM agg_app_day;")[1]["n"],
			"a later rejected statement must undo earlier additive writes")
		AssertTrue(Failure is Error, "failure must prevent callers from publishing success")
		AssertContains(Failure.Message, "fixture drain rejected")
		AssertTrue(SQLite_Exec(Db, "DROP TRIGGER reject_drain;"))
		AssertTrue(KLR_InjectKlwBatch(Db))
		AssertEqual(0, KLW.batch["app_day"].Count)
		AssertEqual(7, SQLite_Query(Db, "SELECT time_ms FROM agg_app_day;")[1]["time_ms"])
		AssertEqual(1, SQLite_Query(Db, "SELECT space_switches FROM agg_system_day;")[1]["space_switches"])
		AssertTrue(KLR_InjectKlwBatch(Db))
		AssertEqual(7, SQLite_Query(Db, "SELECT time_ms FROM agg_app_day;")[1]["time_ms"],
			"retry and subsequent empty drain must apply the batch exactly once")
	} finally {
		KLW.batch := SavedBatch
		Keylogger._device_id_lit := SavedDevice
		SQLite_Close(Db)
	}
}
Test("KLR retains rejected live batch for an atomic retry (klr-live-drain-failure)",
	_KLRLDF_RetryRejectedBatch)

_KLRLDF_RejectInvalidBoundary(OuterTransaction) {
	SavedBatch := KLW.batch
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0)
	BeforeCritical := A_IsCritical
	try {
		KLW_ResetBatch()
		; Missing date is a construction failure, not a valid empty batch.
		KLW.batch["app_day"]["fixture"] := Map("app", "drain.exe")
		Pending := KLW.batch
		if OuterTransaction
			AssertTrue(SQLite_Exec(Db, "CREATE TABLE sentinel(n);BEGIN;INSERT INTO sentinel VALUES(17);"))
		Failure := 0
		try KLR_InjectKlwBatch(Db)
		catch Error as Caught
			Failure := Caught
		AssertTrue(Failure is Error, "invalid ownership or batch shape must not return success")
		AssertTrue(KLW.batch = Pending, "rejection must preserve the exact pending accumulator")
		AssertEqual(BeforeCritical, A_IsCritical)
		if OuterTransaction {
			AssertContains(Failure.Message, "idle SQLite transaction")
			AssertFalse(SQLite_IsAutocommit(Db), "a drain must not roll back its caller's transaction")
			AssertEqual(17, SQLite_Query(Db, "SELECT n FROM sentinel;")[1]["n"])
			AssertTrue(SQLite_Exec(Db, "ROLLBACK;"))
		} else {
			AssertTrue(Failure is UnsetItemError, "the malformed fixture must fail at the missing date")
			AssertTrue(SQLite_IsAutocommit(Db))
		}
	} finally {
		KLW.batch := SavedBatch
		SQLite_Close(Db)
	}
}
for OuterTransaction in [false, true]
	Test("KLR rejects invalid live drain boundary outer=" . OuterTransaction . " (klr-live-drain-failure)",
		_KLRLDF_RejectInvalidBoundary.Bind(OuterTransaction))

_KLRLDF_DenyRollback(Context, Action, Argument, Other, Database, Trigger) {
	; SQLite authorizer action 22 is SQLITE_TRANSACTION; 1 is SQLITE_DENY.
	return Action = 22 && Argument && StrGet(Argument, "UTF-8") = "ROLLBACK" ? 1 : 0
}

_KLRLDF_RollbackFailureInvalidatesCache() {
	SavedBatch := KLW.batch
	SavedDevice := Keylogger._device_id_lit
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Callback := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header())
		Db := _KLRDC_BuildAsWorker()
		KLRCache.disposable := false
		Keylogger._device_id_lit := "'drain-device'"
		KLW_ResetBatch()
		KLW.batch["app_day"]["fixture"] := Map("date", "2026-09-09", "app", "drain.exe", "time_ms", 7)
		AssertTrue(SQLite_Exec(Db,
			"CREATE TRIGGER reject_drain BEFORE INSERT ON agg_app_day "
			. "BEGIN SELECT RAISE(ABORT,'fixture drain rejected'); END;"))
		Callback := CallbackCreate(_KLRLDF_DenyRollback, "C", 6)
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", Callback, "Ptr", 0, "Cdecl Int"))
		Failure := 0
		try KLR_InjectKlwBatch(Db)
		catch Error as Caught
			Failure := Caught
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, "fixture drain rejected")
		AssertContains(Failure.Message, "Rollback failed")
		AssertEqual(0, KLRCache.db, "a cache whose rollback failed must never remain readable")
		AssertEqual(0, KLRCache.last_sizes.Count)
		AssertEqual(1, KLW.batch["app_day"].Count, "cache invalidation must preserve the pending batch")
	} finally {
		try _KLRDC_Cleanup()
		finally {
			if Callback
				CallbackFree(Callback)
			KLW.batch := SavedBatch
			Keylogger._device_id_lit := SavedDevice
		}
	}
}
Test("KLR invalidates a cache after rejected rollback (klr-live-drain-failure)",
	_KLRDC_CheckTeardown.Bind(_KLRLDF_RollbackFailureInvalidatesCache))
