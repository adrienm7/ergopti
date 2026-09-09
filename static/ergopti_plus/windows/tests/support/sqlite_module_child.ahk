; tests/support/sqlite_module_child.ahk

; ==============================================================================
; MODULE: Isolated SQLite Module Lifetime Child
; DESCRIPTION:
; No fixture pins the DLL here. Fail before dereferencing a database if opening
; it did not retain its native module, then verify independent database lifetimes.
; ==============================================================================

#Requires AutoHotkey v2.0
#Warn All, StdOut
#Warn VarUnset, Off
#Warn LocalSameAsGlobal, Off
global _VendorDir := A_ScriptDir . "\..\..\vendor"
#Include ../../infra/sqlite3.ahk

try {
	if DllCall("GetModuleHandleW", "Str", SQLiteConst.DLL, "Ptr")
		throw Error("Fixture unexpectedly inherited a SQLite module reference.")
	Db := SQLite_Open(":memory:")
	if !Db
		throw Error("SQLite fixture could not open its database.")
	Retained := DllCall("GetModuleHandleW", "Str", SQLiteConst.DLL, "Ptr")
	if !Retained
		throw Error("SQLite_Open returned a database without retaining its DLL.")
	Other := SQLite_Open(":memory:")
	if !Other
		throw Error("SQLite fixture could not open its second database.")
	Loop 3 {
		if SQLite_Query(Db, "SELECT 7 AS n")[1]["n"] != 7
			throw Error("SQLite query returned an invalid value.")
		if SQLite_EachRow(Other, "SELECT 1", (*) => true) != 1
			throw Error("SQLite stream did not complete.")
	}
	SQLite_Close(Db)
	if SQLite_Query(Other, "SELECT 9 AS n")[1]["n"] != 9
		throw Error("Closing another database invalidated the remaining owner.")
	SQLite_Close(Other)
	if DllCall("GetModuleHandleW", "Str", SQLiteConst.DLL, "Ptr") != Retained
		throw Error("SQLite module did not retain process lifetime ownership.")
	FileAppend("sqlite-module-lifetime-ok", "*")
	ExitApp(0)
} catch Error as Err {
	; Process teardown is the safe cleanup boundary even for a broken DLL owner.
	FileAppend(Err.Message, "**")
	ExitApp(1)
}
