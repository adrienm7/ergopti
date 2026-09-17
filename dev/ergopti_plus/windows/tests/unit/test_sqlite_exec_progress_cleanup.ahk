; tests/unit/test_sqlite_exec_progress_cleanup.ahk

; ==============================================================================
; MODULE: SQLite Exec Progress Cleanup Tests
; DESCRIPTION: Rejected SQL conversion must not leave native callbacks installed.
; ==============================================================================

#Requires AutoHotkey v2.0

_SEPC_Count(State, Context) {
	State["calls"] += 1
	return 0
}

_SEPC_RejectThenReuse(Db) {
	global _SQLite_ProgressCb
	SavedCallback := _SQLite_ProgressCb
	State := Map("calls", 0)
	Callback := CallbackCreate(_SEPC_Count.Bind(State), "C", 1)
	try {
		_SQLite_ProgressCb := Callback
		; First prove the native observer is live on this exact connection.
		AssertTrue(SQLite_Exec(Db, "SELECT 1;", 1))
		AssertTrue(State["calls"] > 0)
		Rejected := false
		try SQLite_Exec(Db, Map(), 1)
		catch TypeError
			Rejected := true
		AssertTrue(Rejected, "unsupported SQL input must throw before execution")
		State["calls"] := 0
		AssertTrue(SQLite_Exec(Db, "SELECT 1;"))
		AssertEqual(0, State["calls"],
			"the next non-yielding execution must not inherit an abandoned callback")
		_SQLRD_AssertNoStatements(Db)
	} finally {
		SQLite_ClearProgressHandler(Db, 1)
		_SQLite_ProgressCb := SavedCallback
		CallbackFree(Callback)
	}
}

Test("SQLite exec: conversion failure releases progress callback (sqlite-exec-progress-cleanup)",
	_SQLRD_WithDatabase.Bind(_SEPC_RejectThenReuse))
