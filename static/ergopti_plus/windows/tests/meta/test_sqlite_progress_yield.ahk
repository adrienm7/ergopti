; tests/meta/test_sqlite_progress_yield.ahk

#Requires AutoHotkey v2.0

_SSPY_AssertYieldOpsParams() {
	; Move-resilient: scan the whole driver source via the framework helper instead
	; of a pinned infra/sqlite3.ahk read. The exact signature strings below are unique
	; to sqlite3.ahk, so the whole-tree scope cannot trivially satisfy them.
	Src := _DriverSourceConcat()

	ExecDefIdx := InStr(Src, "SQLite_Exec(db, sql, YieldOps := 0) {")
	Assert(ExecDefIdx > 0, "SQLite_Exec must expose a YieldOps parameter (sqlite-wrapper-no-bounded-blocking-on-main-thread)")

	QueryDefIdx := InStr(Src, "SQLite_Query(db, sql, YieldOps := 0) {")
	Assert(QueryDefIdx > 0, "SQLite_Query must expose a YieldOps parameter (sqlite-wrapper-no-bounded-blocking-on-main-thread)")
}

_SSPY_AssertProgressHandler() {
	; The global _SQLite_ProgressCb token is unique to sqlite3.ahk, so a whole-tree
	; scan stays unambiguous; the per-function checks use _DriverFuncBody.
	Src := _DriverSourceConcat()

	YieldCbIdx := InStr(Src, "_SQLite_ProgressCb := CallbackCreate(")
	Assert(YieldCbIdx > 0, "A global CallbackCreate must be defined for progress yielding (sqlite-wrapper-no-bounded-blocking-on-main-thread)")

	ExecBody := _DriverFuncBody("SQLite_Exec")
	ExecHandlerIdx := InStr(ExecBody, "sqlite3_progress_handler")
	Assert(ExecHandlerIdx > 0, "SQLite_Exec must register the sqlite3_progress_handler when YieldOps > 0 (sqlite-wrapper-no-bounded-blocking-on-main-thread)")

	QueryBody := _DriverFuncBody("SQLite_Query")
	QueryHandlerIdx := InStr(QueryBody, "sqlite3_progress_handler")
	Assert(QueryHandlerIdx > 0, "SQLite_Query must register the sqlite3_progress_handler when YieldOps > 0 (sqlite-wrapper-no-bounded-blocking-on-main-thread)")
}

_SSPY_AssertProgressHandlerDeregisteredOnError() {
	; The direct DllCall is centralized so every error exit shares the same
	; deregistration contract instead of growing sibling copies that can drift.
	ClearBody := _DriverFuncBody("SQLite_ClearProgressHandler")
	Assert(ClearBody != "", "SQLite_ClearProgressHandler must exist")
	Assert(InStr(ClearBody, "sqlite3_progress_handler") > 0
		&& InStr(ClearBody, '"Int", 0') > 0,
		"the shared cleanup helper must disable sqlite3_progress_handler with Int 0")

	; Locate the prepare-failure block inside SQLite_Exec and verify it routes
	; through that helper before returning. Without this the handler stays
	; installed permanently after a bad SQL string.
	ExecBody := _DriverFuncBody("SQLite_Exec")
	ExecPrepErrIdx := InStr(ExecBody, "sqlite3_prepare_v2 failed")
	Assert(ExecPrepErrIdx > 0, "SQLite_Exec must have a prepare-failure error path (sqlite-progress-handler-leaked-on-prepare-error)")
	ExecErrBlock := SubStr(ExecBody, ExecPrepErrIdx)
	ExecDeregIdx := InStr(ExecErrBlock, "SQLite_ClearProgressHandler")
	Assert(ExecDeregIdx > 0, "SQLite_Exec prepare-failure path must route through the shared progress-handler cleanup (sqlite-progress-handler-leaked-on-prepare-error)")

	; Locate the early-return block inside SQLite_Query (prepare failure /
	; null statement) and verify the same deregistration is present there.
	QueryBody := _DriverFuncBody("SQLite_Query")
	QueryPrepErrIdx := InStr(QueryBody, "rc != SQLiteConst.OK || !pstmt")
	Assert(QueryPrepErrIdx > 0, "SQLite_Query must have a prepare-failure early-return path (sqlite-progress-handler-leaked-on-prepare-error)")
	QueryErrBlock := SubStr(QueryBody, QueryPrepErrIdx)
	QueryDeregIdx := InStr(QueryErrBlock, "SQLite_ClearProgressHandler")
	Assert(QueryDeregIdx > 0, "SQLite_Query prepare-failure path must route through the shared progress-handler cleanup (sqlite-progress-handler-leaked-on-prepare-error)")
}

Test("sqlite: SQLite_Exec and SQLite_Query expose YieldOps (sqlite-wrapper-no-bounded-blocking-on-main-thread)", _SSPY_AssertYieldOpsParams)
Test("sqlite: sqlite3_progress_handler is used for cooperative yielding (sqlite-wrapper-no-bounded-blocking-on-main-thread)", _SSPY_AssertProgressHandler)
Test("sqlite: progress handler is deregistered on prepare-failure early-return paths (sqlite-progress-handler-leaked-on-prepare-error)", _SSPY_AssertProgressHandlerDeregisteredOnError)
