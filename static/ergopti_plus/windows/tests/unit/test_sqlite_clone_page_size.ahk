; tests/unit/test_sqlite_clone_page_size.ahk

; ==============================================================================
; MODULE: SQLite Clone Page Size Tests
; DESCRIPTION: Private memory clones preserve valid source page geometry and data.
; ==============================================================================

#Requires AutoHotkey v2.0

_SQLPS_Clone(PageSize, Readonly) {
	Path := Readonly ? _FSWL_Path() : ""
	Source := Readonly ? SQLite_Open(Path) : _KLRSQL_OpenMemory()
	Candidate := 0
	try {
		AssertTrue(Source != 0)
		AssertTrue(SQLite_Exec(Source, "PRAGMA page_size=" . PageSize . ";"
			. "CREATE TABLE page_probe(id INTEGER PRIMARY KEY,value TEXT,payload BLOB);"
			. "INSERT INTO page_probe VALUES(1,'original',zeroblob(70000));"))
		AssertEqual(PageSize, SQLite_Query(Source, "PRAGMA page_size;")[1]["page_size"])
		if Readonly {
			SQLite_Close(Source)
			Source := 0
			Source := SQLite_Open(Path, SQLiteConst.OPEN_RO)
			AssertTrue(Source != 0)
			AssertEqual(1, DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly", "Ptr", Source, "AStr", "main", "Int"))
		}
		Candidate := SQLite_CloneMemory(Source)
		AssertTrue(Candidate != 0, "a valid source page size must not prevent a private clone")
		AssertEqual(PageSize, SQLite_Query(Candidate, "PRAGMA page_size;")[1]["page_size"])
		AssertEqual(70000, SQLite_Query(Candidate, "SELECT length(payload) AS n FROM page_probe WHERE id=1;")[1]["n"])
		AssertTrue(SQLite_Exec(Candidate, "UPDATE page_probe SET value='private' WHERE id=1;"
			. "INSERT INTO page_probe VALUES(2,'growth',zeroblob(70000));"))
		AssertEqual(2, SQLite_Query(Candidate, "SELECT COUNT(*) AS n FROM page_probe;")[1]["n"])
		AssertEqual("private", SQLite_Query(Candidate, "SELECT value FROM page_probe WHERE id=1;")[1]["value"])
		AssertEqual(1, SQLite_Query(Source, "SELECT COUNT(*) AS n FROM page_probe;")[1]["n"])
		AssertEqual("original", SQLite_Query(Source, "SELECT value FROM page_probe WHERE id=1;")[1]["value"])
	} finally {
		SQLite_Close(Candidate)
		SQLite_Close(Source)
		if Path != "" && FileExist(Path)
			FileDelete(Path)
	}
}

for PageSize in [512, 4096, 65536] {
	for Readonly in [false, true]
		Test("SQLite clone: source pages=" . PageSize . " readonly=" . Readonly
			. " preserve private growth (sqlite-clone-page-size)", _SQLPS_Clone.Bind(PageSize, Readonly))
}
