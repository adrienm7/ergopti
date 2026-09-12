; tests/unit/test_keylogger_migration_read_refusal.ahk

; ==============================================================================
; MODULE: Migration Read Refusal Tests
; DESCRIPTION: A refused native source read must never publish an empty stage.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLMRR_NativeReadRefusal(LockedOffset) {
	global _KLMigSuccesses
	_KLMig_Reset()
	Payload := LockedOffset ? Format("{:16384}", "synthetic preserved event") : "synthetic preserved event"
	_KLMig_WriteLedger([Payload])
	Path := Keylogger.data_sql_path
	Before := KLR_LedgerSnapshot(Path)
	Source := FileRead(Path, "UTF-8")
	Probe := Map("file", 0, "locked", false, "page_size", 1, "overlap", Buffer(32, 0))
	KL_Enc_SetEnabled(true)
	_KLMigSuccesses := []
	KLMigration.success_fn := _KLMig_RecordSuccess
	try {
		NumPut("UInt", LockedOffset, Probe["overlap"], 16)
		Probe["file"] := FileOpen(Path, "r")
		Probe["locked"] := DllCall("Kernel32\LockFileEx", "Ptr", Probe["file"].Handle,
			"UInt", 3, "UInt", 0, "UInt", 1, "UInt", 0, "Ptr", Probe["overlap"], "Int")
		AssertTrue(Probe["locked"])
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		_KLMig_Drain()
		_KLRCC_ReleaseLock(Probe)
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)),
			"read refusal must retain the exact source file instead of publishing its empty stage")
		AssertEqual(Source, FileRead(Path, "UTF-8"))
		AssertEqual(0, _KLMigSuccesses.Length, "a refused source read must not announce success")
		AssertFalse(KL_Mig_IsActive())
		AssertFalse(FileExist(Path . KL_MIG_STAGING_SUFFIX))
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		_KLMig_Drain()
		AssertEqual(1, _KLMigSuccesses.Length, "the unchanged source must migrate after unlock")
		AssertEqual(Payload, KL_Enc_Decrypt(
			_KLMig_FieldOf(FileRead(Path, "UTF-8"), 1, "text")))
	} finally {
		_KLRCC_ReleaseLock(Probe)
		KL_Mig_Cancel()
		KL_Enc_SetEnabled(false)
		KLMigration.success_fn := 0
	}
}
for LockedOffset in [0, 8192]
	Test("KL_Mig: native read refusal offset=" . LockedOffset . " preserves the ledger (migration-native-read-refusal)",
		_KLMRR_NativeReadRefusal.Bind(LockedOffset))
