; tests/unit/modules/keystats/test_keystats_migration_literal_values.ahk

; ==============================================================================
; MODULE: Migration SQL Literal Value Tests
; DESCRIPTION:
; The real typing builder serializes CR and NUL as SQLite char() expressions.
; Public migration must encrypt their VALUES, not the expression's spelling.
; SQLite executes each actual ledger; hex(text) is independent of the migration
; tokeniser. Crypto and both publication directions are genuine native paths.
; ==============================================================================

#Requires AutoHotkey v2.0

_KMLV_Hex(Value) {
	Bytes := Buffer(StrPut(Value, "UTF-8"))
	Count := StrPut(Value, Bytes, "UTF-8") - 1
	Result := ""
	loop Count
		Result .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Result
}

_KMLV_ReadLedger(Path) {
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0, "The oracle must acquire a genuine SQLite database.")
	try {
		AssertTrue(KLR_LoadSchema(Db), "The oracle must install the canonical schema.")
		AssertTrue(SQLite_Exec(Db, FileRead(Path, "UTF-8")),
			"The actual ledger must execute successfully in SQLite.")
		Rows := SQLite_Query(Db, "SELECT id, text, hex(text) AS h, events_json, app, wpm "
			. "FROM events_typing ORDER BY id;")
		AssertEqual(1, Rows.Length, "Exactly the real builder's one row must survive.")
		return Rows[1]
	} finally {
		AssertEqual(SQLiteConst.OK, SQLite_CloseChecked(Db),
			"The oracle must retire its native database before returning.")
	}
}

_KMLV_RunPass(Mode) {
	AssertTrue(KL_Mig_Start(Mode, false), "Public migration must admit the private ledger.")
	Passes := 0
	while KL_Mig_IsActive() && Passes < 1000 {
		KL_Mig_Slice()
		Passes += 1
	}
	AssertFalse(KL_Mig_IsActive(), "The genuine pass must settle within the bounded driver.")
	AssertEqual("", KLMigration.pendingMarker, "No posture marker debt may be hidden.")
	AssertEqual(1, KLMigration.converted, "The actual typing row must be converted.")
	AssertEqual(Mode == KL_MIG_MODE_ENCRYPT ? "on" : "off", KL_Mig_ReadMarker())
}

_KMLV_Exercise(Mode, Path) {
	if Mode == "cr"
		Text := "left'" . Chr(13) . Chr(10) . "right;--é"
	else if Mode == "nul"
		Text := "left'" . Chr(0) . "right😀"
	else {
		AssertEqual("quoted-control", Mode)
		Text := "plain é😀 'a'||char(13)||'b' and 'x'||char(0)||'y'"
	}
	Expected := _KMLV_Hex(Text)
	Event := Map("type", "typing", "timestamp", "2026-10-23 12:00:00.000",
		"app", "MigrationFixture", "text", Text, "events", Map(), "wpm", 42)
	Rows := KL_BuildInserts(Event)
	AssertEqual(1, Rows.Length, "The genuine producer must create a typing statement.")
	Ledger := "BEGIN TRANSACTION;`n" . Rows[1] . "`nCOMMIT;`n"
	FileAppend(Ledger, Path, "UTF-8")
	Before := _KMLV_ReadLedger(Path)
	AssertEqual(Expected, Before["h"], "The canonical builder must admit the exact input bytes.")
	AssertEqual(1, Before["id"])
	AssertEqual("MigrationFixture", Before["app"])
	AssertEqual(42, Before["wpm"])

	KL_Enc_SetEnabled(true)
	AssertTrue(KL_Enc_IsAvailable(), "The real CNG key must be available before migration.")
	_KMLV_RunPass(KL_MIG_MODE_ENCRYPT)
	Encrypted := _KMLV_ReadLedger(Path)
	AssertTrue(KL_Enc_IsEncrypted(Encrypted["text"]), "SQLite must read a genuine envelope.")
	AssertTrue(KL_Enc_IsEncrypted(Encrypted["events_json"]))
	Plain := KL_Enc_Decrypt(Encrypted["text"])
	Actual := _KMLV_Hex(Plain)
	_TestPrint("# MIGRATION_LITERAL_RECEIPT mode=" . Mode . " expected_hex=" . Expected
		. " decrypted_hex=" . Actual . " converted=" . KLMigration.converted)
	AssertEqual(Expected, Actual,
		"Migration must encrypt the SQLite value, not the char() expression's spelling.")
	AssertEqual("{}", KL_Enc_Decrypt(Encrypted["events_json"]))
	AssertEqual(Before["app"], Encrypted["app"])
	AssertEqual(Before["wpm"], Encrypted["wpm"])

	KL_Enc_SetEnabled(false)
	_KMLV_RunPass(KL_MIG_MODE_DECRYPT)
	After := _KMLV_ReadLedger(Path)
	AssertEqual(Expected, After["h"], "The reverse public pass must restore every original byte.")
	AssertEqual("{}", After["events_json"])
	AssertEqual(Before["app"], After["app"])
	AssertEqual(Before["wpm"], After["wpm"])
	AssertFalse(FileExist(Path . KL_MIG_STAGING_SUFFIX))
	_TestPrint("# MIGRATION_LITERAL_COMPLETE mode=" . Mode . " restored_hex=" . After["h"])
}

_KMLV_Case(Mode) {
	global KL_ENC_Enabled, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
	global KL_ENC_MachineIdOverride, KL_ENC_MachineIdOverrideActive
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	MigrationNames := ["active", "mode", "sourcePath", "stagePath", "readFh", "writeFh",
		"stageBytesWritten", "inSlice", "buffer", "eof", "scanned", "converted", "paused",
		"syncPending", "pendingMarker", "pendingMarkerScanned", "pendingMarkerConverted",
		"pendingMarkerAnnounceSuccess", "commitPending", "timer_fn", "marker_commit_fn",
		"success_fn", "flush_fn", "size_fn"]
	KeystatsNames := ["by_device_dir", "data_sql_path", "device_id", "_device_id_lit",
		"next_event_id", "initialized"]
	CipherNames := ["KL_ENC_Enabled", "KL_ENC_KeyBuffer", "KL_ENC_DerivationFailed",
		"KL_ENC_MachineIdOverride", "KL_ENC_MachineIdOverrideActive"]
	LoggerNames := ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN",
		"_LOGGER_PATH_DATE", "_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED",
		"_LOGGER_ERROR_ENABLED", "_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
	SavedMigration := Map(), SavedKeystats := Map(), SavedCipher := Map(), SavedExtras := Map()
	SavedLogger := 0
	PreviousCritical := Critical("On")
	Owned := false, Root := "", Primary := 0
	try {
		AssertFalse(A_IsSuspended)
		AssertFalse(KL_Mig_IsActive() || KLMigration.inSlice || KLMigration.syncPending
			|| KLMigration.pendingMarker != "" || KLMigration.paused,
			"A foreign migration or retry must not be parked by this fixture.")
		SavedLogger := _TLOG_CaptureLoggerState()
		AssertFalse(SavedLogger.FlushActive, "A foreign logger flush cannot be detached by this fixture.")
		for Name in LoggerNames
			SavedExtras[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
		for Name in MigrationNames
			SavedMigration[Name] := KLMigration.%Name%
		for Name in KeystatsNames
			SavedKeystats[Name] := Keystats.%Name%
		for Name in CipherNames
			SavedCipher[Name] := %Name%
		Owned := true
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		KLMigration.timer_fn := 0, KLMigration.marker_commit_fn := 0
		KLMigration.success_fn := 0, KLMigration.flush_fn := 0, KLMigration.size_fn := 0
		Critical("Off")
		Root := _FSWL_Path() . ".migration-literal"
		DirCreate(Root)
		Path := Root . "\data.sql"
		Keystats.by_device_dir := Root . "\", Keystats.data_sql_path := Path
		Keystats.device_id := "migration-literal-private"
		Keystats._device_id_lit := KL_SqlStr(Keystats.device_id)
		Keystats.next_event_id := 1, Keystats.initialized := true
		KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-0000000000BC")
		KL_Enc_SetEnabled(false)
		_KMLV_Exercise(Mode, Path)
	} catch Any as Failure {
		Primary := Failure
	}
	try {
		if Owned {
			KL_Mig_Cancel()
			AssertFalse(KL_Mig_IsActive())
		}
		if Root != "" && DirExist(Root)
			DirDelete(Root, true)
	} catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	} finally {
		Critical("On")
		try {
			if Owned {
				for Name, Value in SavedMigration
					KLMigration.%Name% := Value
				for Name, Value in SavedKeystats
					Keystats.%Name% := Value
				for Name, Value in SavedCipher
					%Name% := Value
				_TLOG_RestoreLoggerState(SavedLogger)
				for Name, Item in SavedExtras
					%Name% := Item.Present ? Item.Value : unset
			}
		} finally Critical(PreviousCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _KMLV_Mode in ["quoted-control", "cr", "nul"]
	Test("Migration literal values: " . _KMLV_Mode . " survives real encryption and SQLite (migration-literal-value-owner)",
		_KMLV_Case.Bind(_KMLV_Mode))
