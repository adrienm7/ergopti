#Requires AutoHotkey v2.0
#Include ../windows/lib/sqlite3.ahk

global _VendorDir := "../windows/vendor"

_SQLite_ProgressCallback(userData) {
    Sleep(-1)
    return 0
}

db := SQLite_Open(":memory:")
cb := CallbackCreate(_SQLite_ProgressCallback, "C", 1)
DllCall(SQLiteConst.DLL . "\sqlite3_progress_handler", "Ptr", db, "Int", 10, "Ptr", cb, "Ptr", 0)

SQLite_Exec(db, "CREATE TABLE test (id INTEGER);")
SQLite_Exec(db, "WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT 1000) INSERT INTO test SELECT x FROM cnt;")

SQLite_Close(db)
FileAppend("Success`n", "*")
