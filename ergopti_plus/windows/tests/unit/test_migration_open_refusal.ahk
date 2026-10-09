; tests/unit/test_migration_open_refusal.ahk

; ==============================================================================
; MODULE: Migration Native Open Refusal Tests
; DESCRIPTION: Refused input admission must not create output staging artifacts.
; ==============================================================================

#Requires AutoHotkey v2.0

_MOR_Refusal(StageLocked) {
	_KLMig_Reset()
	Original := _KLMig_WriteLedger(["synthetic open refusal"])
	Source := Keylogger.data_sql_path
	Stage := Source . KL_MIG_STAGING_SUFFIX
	Lock := 0
	KL_Enc_SetEnabled(true)
	try {
		if StageLocked
			FileAppend("held stage", Stage, "UTF-8-RAW")
		Lock := FileOpen(StageLocked ? Stage : Source, "r-rwd")
		AssertTrue(IsObject(Lock), "the fixture must acquire an exclusive native handle")
		AssertFalse(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		AssertFalse(KLMigration.active)
		AssertFalse(IsObject(KLMigration.readFh), "failed admission must release the input handle")
		AssertFalse(IsObject(KLMigration.writeFh), "failed admission must release the output handle")
		Lock.Close()
		Lock := 0
		AssertEqual(Original, FileRead(Source, "UTF-8"))
		if StageLocked
			AssertEqual("held stage", FileRead(Stage, "UTF-8-RAW"), "a refused output open cannot claim the held stage")
		else
			AssertFalse(FileExist(Stage), "a refused source open must not leave an empty stage behind")
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false), "unlocked admission must permit retry")
		_KLMig_Drain()
		AssertFalse(KLMigration.active)
		AssertEqual("on", KL_Mig_ReadMarker())
		AssertTrue(KL_Enc_IsEncrypted(_KLMig_FieldOf(FileRead(Source, "UTF-8"), 1, "text")))
		AssertFalse(FileExist(Stage), "successful publication must consume the stage")
	} finally {
		if IsObject(Lock)
			Lock.Close()
		KL_Mig_Cancel()
		KL_Enc_SetEnabled(false)
	}
}

for StageLocked in [false, true]
	Test("migration: native open refusal stage=" . StageLocked . " (migration-open-refusal)", _MOR_Refusal.Bind(StageLocked))
