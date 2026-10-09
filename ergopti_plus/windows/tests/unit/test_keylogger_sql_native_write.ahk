; tests/unit/test_keylogger_sql_native_write.ahk

; ==============================================================================
; MODULE: Keylogger SQL Native Write Receipt Tests
; DESCRIPTION:
; A real Windows write denial must not acknowledge a durable SQL transaction.
; Healthy UTF-8 controls and retry verify exact bytes and the original boundary.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk
#Include ../../modules/keylogger/keylogger_sql_append.ahk

_KDSW_Flush(Lengths, FileObject) {
	Lengths.Push(FileObject.Length)
	return FSFlushFileBuffers(FileObject)
}

_KDSW_Receipt(Existing, Locked) {
	Path := _FSWL_Path()
	Lock := _FSWL_Lock()
	Lengths := []
	Prefix := Existing ? "-- prior`n" : ""
	Body := "BEGIN; INSERT INTO t VALUES ('é😀'); COMMIT;`n"
	OpenFn := Locked ? ObjBindMethod(Lock, "Open") : FileOpen
	try {
		if Existing
			FileAppend(Prefix, Path, "UTF-8")
		Failure := 0
		Accepted := false
		try Accepted := KL_AppendDataSqlDurable(Path, Body, OpenFn, _KDSW_Flush.Bind(Lengths))
		catch as Err
			Failure := Err
		Lock.Release()
		AssertEqual(Locked, Lock.Acquired, "native denial must be established")
		if Locked {
			AssertTrue(Failure is Error, "a lost buffered SQL append must throw, not authorize a checkpoint")
			AssertFalse(Accepted)
			AssertContains(Failure.Message, "data.sql append was incomplete")
			AssertEqual(Prefix, FileRead(Path, "UTF-8"))
			Boundary := Existing ? StrPut(Prefix, "UTF-8") + 2 : 0
			AssertEqual(Boundary, FileGetSize(Path), "rollback must include any new-file BOM")
			AssertEqual(1, Lengths.Length)
			AssertEqual(Boundary, Lengths[1], "the refusal may flush only the restored boundary")
			AssertTrue(KL_AppendDataSqlDurable(Path, Body))
		} else {
			AssertFalse(IsObject(Failure))
			AssertTrue(Accepted)
			AssertEqual(1, Lengths.Length)
			AssertEqual(StrPut(Prefix . Body, "UTF-8") + 2, Lengths[1])
		}
		AssertEqual(Prefix . Body, FileRead(Path, "UTF-8"), "one complete SQL transaction must remain")
		AssertEqual(StrPut(Prefix . Body, "UTF-8") + 2, FileGetSize(Path), "exactly one BOM and no terminator")
	} finally {
		Lock.Release()
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Existing in [false, true] {
	for Locked in [false, true]
		Test("keylogger: native SQL receipt existing=" . Existing . " locked=" . Locked
			. " (keylogger-sql-native-write)", _KDSW_Receipt.Bind(Existing, Locked))
}

_KDSW_RejectUtf16() {
	Path := _FSWL_Path()
	try {
		FileAppend("user-owned é😀", Path, "UTF-16")
		Before := FileRead(Path, "RAW")
		AssertThrows(() => KL_AppendDataSqlDurable(Path, "SELECT 1;"))
		After := FileRead(Path, "RAW")
		AssertEqual(Before.Size, After.Size)
		AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory",
			"Ptr", Before, "Ptr", After, "UPtr", Before.Size, "UPtr"))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

Test("keylogger: SQL refuses UTF-16 without mutation (keylogger-sql-native-write)", _KDSW_RejectUtf16)
