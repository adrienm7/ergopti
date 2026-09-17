; tests/unit/test_keylogger_migration_read_refusal.ahk

; ==============================================================================
; MODULE: Migration Native Source Tests
; DESCRIPTION: Native reads preserve refusal recovery and unrelated source bytes.
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

_KLMRR_NulSource(Leading) {
	global _KLMigSuccesses
	_KLMig_Reset()
	Body := _KLMig_WriteLedger(["synthetic intact row"])
	Path := Keylogger.data_sql_path
	Writer := 0
	try {
		Writer := FileOpen(Path, Leading ? "w" : "a", "UTF-8-RAW")
		AssertEqual(4, Writer.RawWrite(Buffer(4, 0)))
		Writer.Close()
		Writer := 0
		if Leading
			FileAppend(Body, Path, "UTF-8-RAW")
		KL_Enc_SetEnabled(true)
		_KLMigSuccesses := []
		KLMigration.success_fn := _KLMig_RecordSuccess
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		_KLMig_Drain()
		Output := _KL_ReadRecoveryText(Path)
		Recovered := KL_Enc_Decrypt(_KLMig_FieldOf(Output, 1, "text"))
		AssertEqual("synthetic intact row", Recovered)
		AssertEqual(1, _KLMigSuccesses.Length)
		AssertFalse(KL_Mig_IsActive())
		AssertFalse(FileExist(Path . KL_MIG_STAGING_SUFFIX))
		AssertEqual("on", KL_Mig_ReadMarker())
		Reader := FileOpen(Path, "r")
		try {
			Reader.Seek(Leading ? 0 : Reader.Length - 4, 0)
			Hole := Buffer(4)
			AssertEqual(4, Reader.RawRead(Hole, 4))
			AssertEqual(0, NumGet(Hole, 0, "UInt"),
				"migration must preserve the original NUL bytes outside converted fields")
		} finally Reader.Close()
	} finally {
		if IsObject(Writer)
			Writer.Close()
		KL_Mig_Cancel()
		KL_Enc_SetEnabled(false)
		KLMigration.success_fn := 0
	}
}
for Leading in [true, false]
	Test("KL_Mig: native NUL source leading=" . Leading . " retains unrelated bytes (migration-native-nul)",
		_KLMRR_NulSource.Bind(Leading))

_KLMRR_IncompleteSqlTail() {
	global _KLMigSuccesses
	_KLMig_Reset()
	_KLMig_WriteLedger(["complete synthetic row"])
	Tail := _KLMig_TypingSql("unfinished synthetic row")
	AssertEqual(";", SubStr(Tail, -1))
	Path := Keylogger.data_sql_path
	FileAppend(SubStr(Tail, 1, StrLen(Tail) - 1), Path, "UTF-8-RAW")
	Before := KLR_LedgerSnapshot(Path)
	Source := FileRead(Path, "UTF-8")
	KL_Enc_SetEnabled(true)
	_KLMigSuccesses := []
	KLMigration.success_fn := _KLMig_RecordSuccess
	try {
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		_KLMig_Drain()
		if _KLMigSuccesses.Length
			AssertTrue(KL_Enc_IsEncrypted(_KLMig_FieldOf(FileRead(Path, "UTF-8"), 2, "text")),
				"a completed encryption migration must not retain a plaintext trailing row")
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)),
			"an incomplete SQL tail must not publish a partially encrypted ledger")
		AssertEqual(Source, FileRead(Path, "UTF-8"))
		AssertEqual(0, _KLMigSuccesses.Length)
		AssertFalse(FileExist(Keylogger.by_device_dir . KL_MIG_MARKER_FILE))
		AssertFalse(FileExist(Path . KL_MIG_STAGING_SUFFIX))
		FileAppend(";`n", Path, "UTF-8-RAW")
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		_KLMig_Drain()
		AssertEqual(1, _KLMigSuccesses.Length)
		Converted := FileRead(Path, "UTF-8")
		AssertEqual("complete synthetic row", KL_Enc_Decrypt(_KLMig_FieldOf(Converted, 1, "text")))
		AssertEqual("unfinished synthetic row", KL_Enc_Decrypt(_KLMig_FieldOf(Converted, 2, "text")))
		AssertEqual("on", KL_Mig_ReadMarker())
	} finally {
		KL_Mig_Cancel()
		KL_Enc_SetEnabled(false)
		KLMigration.success_fn := 0
	}
}
Test("KL_Mig: incomplete SQL tail refuses publication and retries after completion (migration-incomplete-tail)",
	_KLMRR_IncompleteSqlTail)

_KLMRR_TriviaClassification() {
	for Tail in ["", " `t`r`n", Chr(0), "-- unfinished comment", "/* closed */",
		"/* open comment", "-- quote '`n /* another */ `t"]
		AssertTrue(_KL_Mig_TailIsTrivia(Tail), "comments and padding remain eligible for verbatim preservation")
	for Tail in ["INSERT", "'open literal", "/* closed */ SELECT", "-- comment`nINSERT",
		Chr(0) . "INSERT", "/* * */ /* second */ INSERT", Format("{:65536}", "") . "INSERT"]
		AssertFalse(_KL_Mig_TailIsTrivia(Tail), "SQL tokens after trivia must prevent completed publication")
}
Test("KL_Mig: trailing trivia cannot hide SQL tokens (migration-incomplete-tail)",
	_KLMRR_TriviaClassification)

_KLMRR_TrailingComment() {
	_KLMig_Reset()
	_KLMig_WriteLedger(["comment control"])
	Tail := "/* trailing ' " . Chr(59) . " comment */`n-- final quote '"
	Path := Keylogger.data_sql_path
	FileAppend(Tail, Path, "UTF-8-RAW")
	KL_Enc_SetEnabled(true)
	try {
		AssertEqual(0, _KL_Mig_StatementEnd(Tail), "a comment semicolon cannot end a SQL statement")
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		_KLMig_Drain()
		Output := FileRead(Path, "UTF-8")
		AssertEqual(Tail, SubStr(Output, -StrLen(Tail)), "valid trailing comments must remain byte-exact")
		AssertEqual("comment control", KL_Enc_Decrypt(_KLMig_FieldOf(Output, 1, "text")))
		AssertEqual("on", KL_Mig_ReadMarker())
	} finally {
		KL_Mig_Cancel()
		KL_Enc_SetEnabled(false)
	}
}
Test("KL_Mig: valid trailing comments remain publishable (migration-incomplete-tail)",
	_KLMRR_TrailingComment)

_KLMRR_CommentCannotRedirectConversion(Block) {
	_KLMig_Reset()
	Fake := "INSERT OR IGNORE INTO events_typing (device_id,id,text) VALUES ('test-device',999,'comment only');"
	Comment := Block ? "/* " . Fake . " */`n" : "-- " . Fake . "`n"
	Sql := Comment . _KLMig_TypingSql("actual synthetic event")
	KL_Enc_SetEnabled(true)
	try {
		AssertEqual(StrLen(Sql), _KL_Mig_StatementEnd(Sql))
		Result := KL_Mig_ConvertStatement(Sql, Keylogger._device_id_lit, KL_MIG_MODE_ENCRYPT)
		AssertTrue(Result["ok"])
		AssertEqual(Comment, SubStr(Result["sql"], 1, StrLen(Comment)),
			"SQL-shaped comments must remain untouched by the row converter")
		Actual := _KLMig_FieldOf(Result["sql"], 2, "text")
		AssertTrue(KL_Enc_IsEncrypted(Actual), "the real statement after the comment must be converted")
		AssertEqual("actual synthetic event", KL_Enc_Decrypt(Actual))
		Path := Keylogger.data_sql_path
		FileAppend(Sql, Path, "UTF-8-RAW")
		AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
		_KLMig_Drain()
		Published := FileRead(Path, "UTF-8")
		AssertEqual(Comment, SubStr(Published, 1, StrLen(Comment)))
		Actual := _KLMig_FieldOf(Published, 2, "text")
		AssertTrue(KL_Enc_IsEncrypted(Actual), "the native pass must publish the converted real row")
		AssertEqual("actual synthetic event", KL_Enc_Decrypt(Actual))
		AssertEqual("on", KL_Mig_ReadMarker())
	} finally {
		KL_Mig_Cancel()
		KL_Enc_SetEnabled(false)
	}
}
for Block in [false, true]
	Test("KL_Mig: SQL-shaped comment block=" . Block . " cannot redirect encryption (migration-comment-target)",
		_KLMRR_CommentCannotRedirectConversion.Bind(Block))
