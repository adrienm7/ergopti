; tests/unit/adapters/sqlite/test_sqlite_read_dispatch.ahk

; ==============================================================================
; MODULE: SQLite read dispatch tests
; DESCRIPTION:
; Exercise native row decoding and statement ownership across nested reads,
; cancellation, and exceptional consumers using disposable in-memory databases.
; ==============================================================================

#Requires AutoHotkey v2.0

_SQLRD_WithDatabase(Body) {
	Module := DllCall("LoadLibraryW", "Str", SQLiteConst.DLL, "Ptr")
	AssertTrue(Module != 0, "the fixture must retain the real SQLite module")
	Db := 0
	try {
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0, "the fixture must open a real in-memory database")
		Body.Call(Db)
	} finally {
		; Clean up a regressed implementation's leaked statement as well, so a
		; failed ownership assertion cannot contaminate later suite cases.
		if Db {
			while Statement := DllCall(SQLiteConst.DLL . "\sqlite3_next_stmt",
				"Ptr", Db, "Ptr", 0, "Ptr")
				SQLite_FinalizeStatement(Statement)
			SQLite_Close(Db)
		}
		if !DllCall("FreeLibrary", "Ptr", Module, "Int")
			throw OSError()
	}
}

_SQLRD_AssertNoStatements(Db) {
	AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_next_stmt",
		"Ptr", Db, "Ptr", 0, "Ptr"),
		"every completed or aborted reader must finalize its native statement")
}

_SQLRD_TypedSql() {
	return "SELECT 9223372036854775807 AS big, -9223372036854775808 AS small,"
		. " 1.25 AS fraction, NULL AS missing, '' AS empty, '0' AS zero,"
		. " 'é漢😀' AS [clé], CAST('été' AS BLOB) AS blob"
}

_SQLRD_AssertTypedRow(Row) {
	AssertEqual(8, Row.Count, "all column names must survive native decoding")
	AssertEqual("Integer", Type(Row["big"]))
	AssertEqual(9223372036854775807, Row["big"], "int64 must not lose precision")
	AssertEqual("Integer", Type(Row["small"]))
	AssertEqual(-9223372036854775808, Row["small"])
	AssertEqual("Float", Type(Row["fraction"]))
	AssertEqual(1.25, Row["fraction"])
	AssertEqual("String", Type(Row["missing"]))
	AssertEqual("", Row["missing"], "NULL keeps the wrapper's empty-string contract")
	AssertEqual("", Row["empty"])
	AssertEqual("String", Type(Row["zero"]))
	AssertEqual("0", Row["zero"])
	AssertEqual("é漢😀", Row["clé"], "UTF-8 values and aliases must round-trip")
	AssertEqual("été", Row["blob"], "BLOB retains the existing text conversion")
	return true
}

_SQLRD_TypedReads(Db) {
	Loop 3 {
		Rows := SQLite_Query(Db, _SQLRD_TypedSql(), 1)
		AssertEqual(1, Rows.Length)
		_SQLRD_AssertTypedRow(Rows[1])
		_SQLRD_AssertNoStatements(Db)
		AssertEqual(1, SQLite_EachRow(Db, _SQLRD_TypedSql(), _SQLRD_AssertTypedRow, 1))
		_SQLRD_AssertNoStatements(Db)
	}
}

Test("SQLite reads: native types survive repeated dispatch (sqlite-read-dispatch)",
	() => _SQLRD_WithDatabase(_SQLRD_TypedReads))

; Generate NUL inside SQLite, so the fixture never passes a truncated SQL input.
_SQLRD_LengthfulSql() {
	return "SELECT char(0) AS leading, 'before'||char(0)||'after' AS middle,"
		. " 'suffix'||char(0) AS trailing, 'é'||char(0)||'界😀' AS unicode_value,"
		. " CAST(X'41004200' AS TEXT) AS raw_value, '' AS empty, '0' AS zero"
}

_SQLRD_AssertTextUnits(Expected, Actual) {
	AssertEqual("String", Type(Actual), "SQLite text keeps its string type")
	AssertEqual(StrLen(Expected), StrLen(Actual), "the complete UTF-16 length must survive")
	Loop StrLen(Expected)
		AssertEqual(NumGet(StrPtr(Expected), (A_Index - 1) * 2, "UShort"),
			NumGet(StrPtr(Actual), (A_Index - 1) * 2, "UShort"),
			"every code unit after an embedded NUL must remain intact")
}

_SQLRD_AssertLengthfulRow(Row) {
	AssertEqual(7, Row.Count)
	_SQLRD_AssertTextUnits(Chr(0), Row["leading"])
	_SQLRD_AssertTextUnits("before" . Chr(0) . "after", Row["middle"])
	_SQLRD_AssertTextUnits("suffix" . Chr(0), Row["trailing"])
	_SQLRD_AssertTextUnits("é" . Chr(0) . "界😀", Row["unicode_value"])
	_SQLRD_AssertTextUnits("A" . Chr(0) . "B" . Chr(0), Row["raw_value"])
	_SQLRD_AssertTextUnits("", Row["empty"])
	_SQLRD_AssertTextUnits("0", Row["zero"])
	return true
}

_SQLRD_LengthfulReads(Db, Stream) {
	Sql := _SQLRD_LengthfulSql() . " UNION ALL " . _SQLRD_LengthfulSql()
	if Stream {
		AssertEqual(2, SQLite_EachRow(Db, Sql, _SQLRD_AssertLengthfulRow, 1),
			"both streamed rows must reach the independent code-unit oracle")
	} else {
		Rows := SQLite_Query(Db, Sql, 1)
		AssertEqual(2, Rows.Length)
		for Row in Rows
			_SQLRD_AssertLengthfulRow(Row)
	}
	_SQLRD_AssertNoStatements(Db)
	_SQLRD_AssertTypedRow(SQLite_Query(Db, _SQLRD_TypedSql())[1])
	_SQLRD_AssertNoStatements(Db)
}

Test("SQLite reads: query retains text bytes after NUL (sqlite-text-byte-length)",
	() => _SQLRD_WithDatabase(_SQLRD_LengthfulReads.Bind(, false)))
Test("SQLite reads: streaming retains text bytes after NUL (sqlite-text-byte-length)",
	() => _SQLRD_WithDatabase(_SQLRD_LengthfulReads.Bind(, true)))

_SQLRD_NestedConsumer(Db, Seen, Row) {
	Rows := SQLite_Query(Db, _SQLRD_TypedSql(), 1)
	AssertEqual(1, Rows.Length)
	_SQLRD_AssertTypedRow(Rows[1])
	AssertEqual(1, SQLite_EachRow(Db, _SQLRD_TypedSql(), _SQLRD_AssertTypedRow, 1))
	Statement := DllCall(SQLiteConst.DLL . "\sqlite3_next_stmt",
		"Ptr", Db, "Ptr", 0, "Ptr")
	AssertTrue(Statement != 0, "the outer reader must remain live after both nested readers")
	AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_next_stmt",
		"Ptr", Db, "Ptr", Statement, "Ptr"), "only the outer statement may remain")
	Seen.Push(Row["id"])
	return true
}

_SQLRD_NestedReads(Db) {
	Seen := []
	AssertEqual(3, SQLite_EachRow(Db,
		"SELECT 1 AS id UNION ALL SELECT 2 UNION ALL SELECT 3",
		_SQLRD_NestedConsumer.Bind(Db, Seen), 1))
	AssertEqual(3, Seen.Length)
	for Index, Id in Seen
		AssertEqual(Index, Id, "nested reads must not disturb outer row order")
	_SQLRD_AssertNoStatements(Db)
}

Test("SQLite reads: nested readers retain independent ownership (sqlite-read-dispatch)",
	() => _SQLRD_WithDatabase(_SQLRD_NestedReads))

_SQLRD_StopConsumer(Seen, Row) {
	Seen.Push(Row["id"])
	return false
}

_SQLRD_ThrowConsumer(Expected, Row) {
	throw Expected
}

_SQLRD_ConsumerExits(Db) {
	Sql := "SELECT 7 AS id, 'fixture-ts' AS ts UNION ALL SELECT 8, 'later-ts'"
	Seen := []
	AssertEqual(1, SQLite_EachRow(Db, Sql, _SQLRD_StopConsumer.Bind(Seen), 1),
		"early stop counts the delivered row")
	AssertEqual(1, Seen.Length)
	AssertEqual(7, Seen[1])
	_SQLRD_AssertNoStatements(Db)

	Expected := Error("injected consumer failure")
	Failure := Map()
	AssertEqual(-1, SQLite_EachRow(Db, Sql,
		_SQLRD_ThrowConsumer.Bind(Expected), 1, Failure))
	AssertEqual(1, Failure["row_index"])
	AssertEqual(7, Failure["row_id"])
	AssertEqual("fixture-ts", Failure["timestamp"])
	AssertTrue(Failure["error"] = Expected, "the exact consumer exception must remain available")
	_SQLRD_AssertNoStatements(Db)

	; The wrapper catches Error objects only. An arbitrary thrown value must
	; still propagate, but it must no longer bypass statement/module cleanup.
	Caught := ""
	try SQLite_EachRow(Db, Sql, _SQLRD_ThrowConsumer.Bind("non-error sentinel"))
	catch Any as Thrown
		Caught := Thrown
	AssertEqual("non-error sentinel", Caught)
	_SQLRD_AssertNoStatements(Db)
	AssertEqual(2, SQLite_Query(Db, Sql).Length, "an exceptional reader must leave the DB usable")
}

Test("SQLite reads: every consumer exit releases its statement (sqlite-read-dispatch)",
	() => _SQLRD_WithDatabase(_SQLRD_ConsumerExits))

_SQLRD_InterruptConsumer(Db, Seen, Row) {
	Seen.Push(Row["id"])
	DllCall(SQLiteConst.DLL . "\sqlite3_interrupt", "Ptr", Db)
	return true
}

_SQLRD_SqlFailures(Db) {
	for Sql in ["BROKEN SQL", "", "SELECT abs(-9223372036854775808)"] {
		if (Sql = "")
			AssertEqual(0, SQLite_Query(Db, Sql, 1).Length)
		else
			AssertThrows(SQLite_Query.Bind(Db, Sql, 1))
		_SQLRD_AssertNoStatements(Db)
		AssertEqual(-1, SQLite_EachRow(Db, Sql, (*) => true, 1))
		_SQLRD_AssertNoStatements(Db)
	}
	Seen := []
	AssertEqual(-1, SQLite_EachRow(Db,
		"WITH RECURSIVE seq(id) AS (VALUES(1) UNION ALL SELECT id+1 FROM seq WHERE id<100) SELECT id FROM seq",
		_SQLRD_InterruptConsumer.Bind(Db, Seen), 1),
		"native interruption must remain an unsuccessful stream")
	AssertEqual(1, Seen.Length, "interruption must prevent the next delivery")
	_SQLRD_AssertNoStatements(Db)
	AssertEqual(1, SQLite_Query(Db, "SELECT 1").Length,
		"a terminal failure must leave the database reusable")
}

Test("SQLite reads: prepare and step failures preserve results and cleanup (sqlite-read-dispatch)",
	() => _SQLRD_WithDatabase(_SQLRD_SqlFailures))
