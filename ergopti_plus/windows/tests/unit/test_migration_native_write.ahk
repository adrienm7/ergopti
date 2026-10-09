; tests/unit/test_migration_native_write.ahk

; ==============================================================================
; MODULE: Migration Native Write Receipt Tests
; DESCRIPTION: Reject buffered acceptance when Windows refuses a staging write.
; ==============================================================================

#Requires AutoHotkey v2.0

_MNW_Outcome(Locked) {
	SavedFile := KLMigration.writeFh
	SavedBytes := KLMigration.stageBytesWritten
	Path := _FSWL_Path()
	Lock := _FSWL_Lock()
	File := 0
	Content := "étoile😀`nline"
	try {
		File := Locked ? Lock.Open(Path, "w", "UTF-8-RAW") : FSOpenWrite(Path)
		AssertTrue(IsObject(File))
		KLMigration.writeFh := File
		KLMigration.stageBytesWritten := 0
		Accepted := _KL_Mig_WriteStage(Content)
		; Close while the lock still denies writes, exposing any buffered loss.
		File.Close()
		File := 0
		Lock.Release()
		AssertEqual(Locked, Lock.Acquired, "the refusal must come from a real Windows lock")
		AssertEqual(!Locked, Accepted, "stage acceptance must require a successful native write")
		Expected := Locked ? "" : Content
		AssertEqual(StrPut(Expected, "UTF-8") - 1, KLMigration.stageBytesWritten,
			"refused bytes must not enter the migration publication receipt")
		AssertEqual(Expected, FileRead(Path, "UTF-8-RAW"))
		AssertEqual(StrPut(Expected, "UTF-8") - 1, FileGetSize(Path))
	} finally {
		if IsObject(File)
			File.Close()
		Lock.Release()
		KLMigration.writeFh := SavedFile
		KLMigration.stageBytesWritten := SavedBytes
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Locked in [true, false]
	Test("migration: native stage write locked=" . Locked . " (migration-native-write)", _MNW_Outcome.Bind(Locked))

_MNW_LedgerRows(Sql) {
	_KLRDC_EnsureSharedDir()
	Db := _WJFM_OpenMemory()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, Sql))
		return KL_JsonEncode(SQLite_Query(Db, "SELECT * FROM events_typing ORDER BY device_id,id;"))
			. KL_JsonEncode(SQLite_Query(Db, "SELECT * FROM events_shortcut ORDER BY device_id,id;"))
	} finally {
		SQLite_Close(Db)
	}
}

_MNW_AbortAndRetry() {
	_KLMig_Reset()
	Original := _KLMig_WriteLedger(["synthetic migration payload"])
	Lock := _FSWL_Lock()
	KL_Enc_SetEnabled(true)
	try {
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		Stage := KLMigration.stagePath
		KLMigration.writeFh.Close()
		KLMigration.writeFh := Lock.Open(Stage, "w", "UTF-8-RAW")
		AssertFalse(KL_Mig_Slice(), "the first refused native write must stop the active slice")
		AssertTrue(Lock.Acquired)
		AssertFalse(KLMigration.active)
		AssertEqual(0, KLMigration.scanned, "a refused first statement must not count as migrated")
		AssertEqual(0, KLMigration.stageBytesWritten)
		AssertFalse(IsObject(KLMigration.writeFh), "abort must release the refused writer")
		AssertEqual(Original, FileRead(Keylogger.data_sql_path, "UTF-8"))
		Lock.Release()
		AssertFalse(FileExist(Stage), "abort must retire only its incomplete stage")
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		_KLMig_Drain()
		AssertFalse(KLMigration.active)
		AssertEqual("on", KL_Mig_ReadMarker())
		KL_Enc_SetEnabled(false)
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_DECRYPT, false))
		_KLMig_Drain()
		; Conversion normalizes spacing around rewritten SQL literals. Compare
		; all stored columns through SQLite, retaining whitespace inside values.
		AssertEqual(_MNW_LedgerRows(Original), _MNW_LedgerRows(FileRead(Keylogger.data_sql_path, "UTF-8")),
			"an unlocked retry must preserve every stored value through encryption and decryption")
	} finally {
		Lock.Release()
		KL_Mig_Cancel()
		KL_Enc_SetEnabled(false)
	}
}
Test("migration: native refusal aborts immediately and permits retry (migration-native-write)", _MNW_AbortAndRetry)
