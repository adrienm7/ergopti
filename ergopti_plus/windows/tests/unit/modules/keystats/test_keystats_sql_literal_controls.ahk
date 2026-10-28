; tests/unit/modules/keystats/test_keystats_sql_literal_controls.ahk

; ==============================================================================
; MODULE: SQL Literal Control-Byte Round Trip Tests
; DESCRIPTION:
; Every SQL text literal the Windows driver builds goes either straight to
; sqlite3_prepare_v2, which reads a NUL-terminated statement, or into the
; data.sql ledger, whose reader translates CRLF to LF and skips NUL bytes as
; the hole of an interrupted append. A raw NUL in a literal therefore cut the
; statement short or vanished from the value, and a CR inside a CRLF pair was
; lost. The shared policy (_shared/lua/sqlite/literal.lua) expresses CR and
; NUL as SQLite char() concatenations; each Windows encoder must keep every
; value byte-exact through both paths. hex(v) computed by SQLite is the
; independent oracle for the stored bytes.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../support/filesystem_write_lock.ahk

_KLSLC_Values() {
	return [
		"a" . Chr(0) . "b", Chr(0), "x" . Chr(0), Chr(0) . "y",
		"it's" . Chr(0) . "'q'", "l1" . Chr(13) . Chr(10) . "l2",
		"bare" . Chr(13) . "cr", Chr(13), "lf" . Chr(10) . "only",
		"é😀" . Chr(0) . "z", "plain", ""
	]
}

_KLSLC_Hex(Value) {
	Bytes := Buffer(StrPut(Value, "UTF-8"))
	Count := StrPut(Value, Bytes, "UTF-8") - 1
	Hex := ""
	loop Count
		Hex .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Hex
}

_KLSLC_Describe(Value) {
	return "hex " . _KLSLC_Hex(Value)
}

_KLSLC_HasControlUnit(Text) {
	loop StrLen(Text) {
		Unit := NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort")
		if Unit == 0 || Unit == 13
			return true
	}
	return false
}

_KLSLC_OpenTable() {
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0, "the fixture must open a real in-memory database")
	AssertTrue(SQLite_Exec(Db, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);"),
		"the fixture table must be created")
	return Db
}

_KLSLC_ReadBack(Db, Value, Label) {
	Rows := SQLite_Query(Db, "SELECT v, hex(v) AS h FROM t ORDER BY id;")
	AssertEqual(1, Rows.Length, Label . ": exactly one row must be stored for " . _KLSLC_Describe(Value))
	AssertEqual(_KLSLC_Hex(Value), Rows[1]["h"], Label . ": SQLite must store the exact UTF-8 bytes of " . _KLSLC_Describe(Value))
	AssertEqual(StrLen(Value), StrLen(Rows[1]["v"]), Label . ": the read-back value must keep every code unit of " . _KLSLC_Describe(Value))
	AssertTrue(Rows[1]["v"] == Value, Label . ": the read-back value must equal " . _KLSLC_Describe(Value))
}

_KLSLC_WriteLedger(Path, Sql) {
	Bytes := Buffer(StrPut(Sql, "UTF-8"))
	Count := StrPut(Sql, Bytes, "UTF-8") - 1
	Handle := FileOpen(Path, "w")
	try Handle.RawWrite(Bytes, Count)
	finally Handle.Close()
}

_KLSLC_RoundTrip(Name, Encoder) {
	Root := _FSWL_Path() . ".sql-literal"
	DirCreate(Root)
	Failures := []
	try {
		for Value in _KLSLC_Values() {
			Literal := Encoder.Call(Value)
			Insert := "INSERT INTO t (v) VALUES (" . Literal . ");"
			try {
				Db := _KLSLC_OpenTable()
				try {
					AssertTrue(SQLite_Exec(Db, Insert), Name . ": direct execution must accept " . _KLSLC_Describe(Value))
					_KLSLC_ReadBack(Db, Value, Name . " direct")
				} finally SQLite_Close(Db)
				Ledger := Root . "\data.sql"
				_KLSLC_WriteLedger(Ledger, "BEGIN TRANSACTION;`n" . Insert . "`nCOMMIT;`n")
				Db := _KLSLC_OpenTable()
				try {
					Offset := -1
					AssertTrue(KLR_ExecLargeFile(Db, Ledger, &Offset), Name . ": the ledger replay must accept " . _KLSLC_Describe(Value))
					_KLSLC_ReadBack(Db, Value, Name . " ledger")
				} finally SQLite_Close(Db)
				AssertFalse(_KLSLC_HasControlUnit(Literal),
					Name . ": the literal must carry no raw NUL or CR for " . _KLSLC_Describe(Value))
			} catch as Err {
				Failures.Push(Err.Message)
			}
		}
	} finally DirDelete(Root, true)
	Report := ""
	for Message in Failures
		Report .= (Report == "" ? "" : " | ") . Message
	AssertEqual(0, Failures.Length, Failures.Length . " of " . _KLSLC_Values().Length . " values were altered: " . Report)
}

/** Registers one round trip per encoder without publishing loop variables. */
_KLSLC_RegisterEncoders() {
	local Name, Encoder
	for Name, Encoder in Map("SQLite_Q", SQLite_Q, "KL_SqlStr", KL_SqlStr, "KLW_SqlEscape", KLW_SqlEscape)
		Test("SQL literals: " . Name . " keeps NUL and CR byte-exact through exec and the ledger (sql-literal-controls)",
			_KLSLC_RoundTrip.Bind(Name, Encoder))
}
_KLSLC_RegisterEncoders()

; The encoded form must match the shared Lua policy character for character,
; so a ledger written by one driver reads back identically on another.
_KLSLC_MatchesSharedPolicy() {
	Q := "'"
	; Pairs, not a Map: a native Map key stops at NUL.
	Cases := [
		["plain", Q . "plain" . Q],
		["it's", Q . "it''s" . Q],
		["a" . Chr(0) . "b", Q . "a'||char(0)||'b" . Q],
		["l1" . Chr(13) . Chr(10) . "l2", Q . "l1'||char(13)||'" . Chr(10) . "l2" . Q],
		[Chr(0) . "'", Q . "'||char(0)||'''" . Q]]
	for Pair in Cases
		AssertEqual(Pair[2], SQLite_Q(Pair[1]), "SQLite_Q must follow the shared literal policy for " . _KLSLC_Describe(Pair[1]))
}
Test("SQL literals: SQLite_Q follows the shared char() literal policy (sql-literal-controls)",
	_KLSLC_MatchesSharedPolicy)
