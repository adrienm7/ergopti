; tests/unit/test_klr_cache_open_failure.ahk

; ==============================================================================
; MODULE: Reader Cache Stage Open Failure Tests
; DESCRIPTION: Failed native opens must retire owned staging files before retry.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCO_Open(State, Vfs, Name, FilePtr, Flags, OutFlags) {
	try {
		Stage := Name && InStr(StrGet(Name, "UTF-8"), State["prefix"]) = 1
		if Stage {
			State["stage"] := StrGet(Name, "UTF-8")
			if !State["create"] {
				NumPut("Ptr", 0, FilePtr)
				return 14
			}
		}
		Result := DllCall(State["open"], "Ptr", State["original"], "Ptr", Name,
			"Ptr", FilePtr, "Int", Flags, "Ptr", OutFlags, "CDecl Int")
		if Result = 0 && Stage {
			Methods := NumGet(FilePtr, "Ptr")
			CloseFn := NumGet(Methods, A_PtrSize, "Ptr")
			Result := DllCall(CloseFn, "Ptr", FilePtr, "CDecl Int")
			NumPut("Ptr", 0, FilePtr)
			State["closed"] := Result = 0
			State["created"] := !!FileExist(State["stage"])
			return 14
		}
		return Result
	} catch {
		; Exceptions must not cross SQLite's native callback boundary.
		State["callback_failure"] := true
		return 14
	}
}

_KLRCO_Count(Path) {
	Db := SQLite_Open(Path, SQLiteConst.OPEN_RO)
	AssertTrue(Db != 0, "the canonical image must remain readable")
	try return SQLite_Query(Db, "SELECT COUNT(*) AS n FROM stage_open_probe;")[1]["n"]
	finally SQLite_Close(Db)
}

_KLRCO_FailedOpen(CreateFirst) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Db := 0
	Callback := 0
	Registered := false
	State := Map("create", CreateFirst, "stage", "", "closed", false,
		"created", false, "callback_failure", false)
	try {
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0)
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, "CREATE TABLE stage_open_probe(n);INSERT INTO stage_open_probe VALUES(1);"))
		Root := _KLRDC_Root()
		AssertEqual(1, KLR_CacheSave(Db, Map(), Root, "", Map()))
		AssertTrue(SQLite_Exec(Db, "INSERT INTO stage_open_probe VALUES(2);"))
		Original := DllCall(SQLiteConst.DLL . "\sqlite3_vfs_find", "Ptr", 0, "CDecl Ptr")
		AssertTrue(Original != 0)
		AssertEqual(3, NumGet(Original, "Int"), "the fixture requires the documented version-three VFS ABI")
		; sqlite3_vfs: three ints, pointer alignment, then 19 pointer fields.
		Header := A_PtrSize = 8 ? 16 : 12
		Proxy := Buffer(Header + 19 * A_PtrSize, 0)
		DllCall("RtlMoveMemory", "Ptr", Proxy.Ptr, "Ptr", Original, "UPtr", Proxy.Size)
		Name := Buffer(64, 0)
		StrPut("ergopti-stage-open-failure", Name, "UTF-8")
		State["original"] := Original
		State["open"] := NumGet(Original, Header + 3 * A_PtrSize, "Ptr")
		State["prefix"] := StrReplace(KLR_CachePath(Root), "/", "\") . ".stage."
		Callback := CallbackCreate(_KLRCO_Open.Bind(State), "C", 5)
		NumPut("Ptr", 0, Proxy, Header)
		NumPut("Ptr", Name.Ptr, Proxy, Header + A_PtrSize)
		NumPut("Ptr", Callback, Proxy, Header + 3 * A_PtrSize)
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_vfs_register", "Ptr", Proxy.Ptr, "Int", 1, "CDecl Int"))
		Registered := true
		Result := KLR_CacheSave(Db, Map(), Root, "", Map())
		AssertFalse(State["callback_failure"], "the native callback must complete without a fixture exception")
		AssertTrue(State["stage"] != "", "failure must reach the exact staging open")
		if CreateFirst {
			AssertTrue(State["created"], "native xOpen must create the file before the injected error")
			AssertTrue(State["closed"], "native ownership must be released before returning the error")
		}
		AssertEqual(0, Result, "an open error must reject publication")
		AssertFalse(FileExist(State["stage"]), "a failed open must remove its owned staging file")
		AssertEqual(1, _KLRCO_Count(KLR_CachePath(Root)), "failed opening must preserve the last-good image")
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_vfs_register", "Ptr", Original, "Int", 1, "CDecl Int"))
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_vfs_unregister", "Ptr", Proxy.Ptr, "CDecl Int"))
		Registered := false
		AssertEqual(1, KLR_CacheSave(Db, Map(), Root, "", Map()), "a fresh native open must allow retry")
		AssertEqual(2, _KLRCO_Count(KLR_CachePath(Root)), "retry must publish the complete candidate")
	} finally {
		if Registered {
			AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_vfs_register", "Ptr", Original, "Int", 1, "CDecl Int"))
			AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_vfs_unregister", "Ptr", Proxy.Ptr, "CDecl Int"))
		}
		if Callback
			CallbackFree(Callback)
		SQLite_Close(Db)
		_KLRDC_Cleanup()
	}
}
for CreateFirst in [false, true]
	Test("KLR cache: native stage open failure releases its file created=" . CreateFirst . " (klr-cache-open-failure)",
		_KLRDC_CheckTeardown.Bind(_KLRCO_FailedOpen.Bind(CreateFirst)))
