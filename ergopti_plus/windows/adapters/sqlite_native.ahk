; adapters/sqlite_native.ahk

; ==============================================================================
; MODULE: SQLite Native Adapter
; DESCRIPTION:
; Keep new SQLite C API access behind the native boundary while the existing
; wrapper owns statement lifetimes and cached dispatch addresses. These Windows
; helpers do not extend the shared Storage port, which persists Registry values.
; ==============================================================================

#Requires AutoHotkey v2.0+

; The caller retains both the statement and its resolved column-bytes address.
; @param Address {Integer} The sqlite3_column_bytes entry in the owned module.
; @param Statement {Integer} The live SQLite statement handle.
; @param Column {Integer} The zero-based column whose UTF-8 text was requested.
; @returns {Integer} The complete text byte count, including embedded NUL bytes.
SQLiteNativeColumnBytes(Address, Statement, Column) {
	return DllCall(Address, "Ptr", Statement, "Int", Column, "Int")
}

; @param Sql {Buffer|Integer} A NUL-terminated UTF-8 SQLite lexical probe.
; @returns {Boolean} Whether SQLite considers the probe a complete statement.
SQLiteNativeIsComplete(Sql) {
	return DllCall(SQLiteConst.DLL . "\sqlite3_complete", "Ptr", Sql, "Int") != 0
}
