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
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
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

Test("sqlite: SQLite_Exec and SQLite_Query expose YieldOps (sqlite-wrapper-no-bounded-blocking-on-main-thread)", _SSPY_AssertYieldOpsParams)
Test("sqlite: sqlite3_progress_handler is used for cooperative yielding (sqlite-wrapper-no-bounded-blocking-on-main-thread)", _SSPY_AssertProgressHandler)
