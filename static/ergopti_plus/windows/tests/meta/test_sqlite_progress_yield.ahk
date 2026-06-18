; tests/meta/test_sqlite_progress_yield.ahk

#Requires AutoHotkey v2.0

_SSPY_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_SSPY_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_SSPY_AssertYieldOpsParams() {
	Src := _SSPY_ReadSource("lib/sqlite3.ahk")
	
	ExecDefIdx := InStr(Src, "SQLite_Exec(db, sql, YieldOps := 0) {")
	Assert(ExecDefIdx > 0, "SQLite_Exec must expose a YieldOps parameter (sqlite-wrapper-no-bounded-blocking-on-main-thread)")

	QueryDefIdx := InStr(Src, "SQLite_Query(db, sql, YieldOps := 0) {")
	Assert(QueryDefIdx > 0, "SQLite_Query must expose a YieldOps parameter (sqlite-wrapper-no-bounded-blocking-on-main-thread)")
}

_SSPY_AssertProgressHandler() {
	Src := _SSPY_ReadSource("lib/sqlite3.ahk")

	YieldCbIdx := InStr(Src, "_SQLite_ProgressCb := CallbackCreate(")
	Assert(YieldCbIdx > 0, "A global CallbackCreate must be defined for progress yielding (sqlite-wrapper-no-bounded-blocking-on-main-thread)")

	ExecBody := _SSPY_FuncBodyStripped(Src, "SQLite_Exec(db, sql, YieldOps := 0) {")
	ExecHandlerIdx := InStr(ExecBody, "sqlite3_progress_handler")
	Assert(ExecHandlerIdx > 0, "SQLite_Exec must register the sqlite3_progress_handler when YieldOps > 0 (sqlite-wrapper-no-bounded-blocking-on-main-thread)")

	QueryBody := _SSPY_FuncBodyStripped(Src, "SQLite_Query(db, sql, YieldOps := 0) {")
	QueryHandlerIdx := InStr(QueryBody, "sqlite3_progress_handler")
	Assert(QueryHandlerIdx > 0, "SQLite_Query must register the sqlite3_progress_handler when YieldOps > 0 (sqlite-wrapper-no-bounded-blocking-on-main-thread)")
}

_SSPY_AssertProgressHandlerDeregisteredOnError() {
	Src := _SSPY_ReadSource("lib/sqlite3.ahk")

	; Locate the prepare-failure block inside SQLite_Exec and verify it
	; deregisters the progress handler (Int 0 disables it) before returning.
	; Without this the handler stays installed permanently after a bad SQL string.
	ExecBody := _SSPY_FuncBodyStripped(Src, "SQLite_Exec(db, sql, YieldOps := 0) {")
	ExecPrepErrIdx := InStr(ExecBody, "sqlite3_prepare_v2 failed")
	Assert(ExecPrepErrIdx > 0, "SQLite_Exec must have a prepare-failure error path (sqlite-progress-handler-leaked-on-prepare-error)")
	ExecErrBlock := SubStr(ExecBody, ExecPrepErrIdx)
	; The deregistration call uses "Int", 0 to disable the handler
	ExecDeregIdx := InStr(ExecErrBlock, '"Int", 0')
	Assert(ExecDeregIdx > 0, "SQLite_Exec prepare-failure path must deregister the progress handler with sqlite3_progress_handler(..., Int 0, ...) (sqlite-progress-handler-leaked-on-prepare-error)")

	; Locate the early-return block inside SQLite_Query (prepare failure /
	; null statement) and verify the same deregistration is present there.
	QueryBody := _SSPY_FuncBodyStripped(Src, "SQLite_Query(db, sql, YieldOps := 0) {")
	QueryPrepErrIdx := InStr(QueryBody, "rc != SQLiteConst.OK || !pstmt")
	Assert(QueryPrepErrIdx > 0, "SQLite_Query must have a prepare-failure early-return path (sqlite-progress-handler-leaked-on-prepare-error)")
	QueryErrBlock := SubStr(QueryBody, QueryPrepErrIdx)
	QueryDeregIdx := InStr(QueryErrBlock, '"Int", 0')
	Assert(QueryDeregIdx > 0, "SQLite_Query prepare-failure path must deregister the progress handler with sqlite3_progress_handler(..., Int 0, ...) (sqlite-progress-handler-leaked-on-prepare-error)")
}

Test("sqlite: SQLite_Exec and SQLite_Query expose YieldOps (sqlite-wrapper-no-bounded-blocking-on-main-thread)", _SSPY_AssertYieldOpsParams)
Test("sqlite: sqlite3_progress_handler is used for cooperative yielding (sqlite-wrapper-no-bounded-blocking-on-main-thread)", _SSPY_AssertProgressHandler)
Test("sqlite: progress handler is deregistered on prepare-failure early-return paths (sqlite-progress-handler-leaked-on-prepare-error)", _SSPY_AssertProgressHandlerDeregisteredOnError)
