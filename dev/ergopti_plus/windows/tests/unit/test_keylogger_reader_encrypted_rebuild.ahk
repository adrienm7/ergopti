; tests/unit/test_keylogger_reader_encrypted_rebuild.ahk

; ==============================================================================
; MODULE: Keylogger Encrypted Reader Rebuild Tests
; DESCRIPTION:
; End-to-end regression coverage for encrypted typing ledgers. The production
; writer must keep literal text encrypted on disk while a fresh reader rebuilds
; the same daily, hourly, and n-gram projections as a plaintext ledger.
; ==============================================================================

_KLRER_EncryptedTypingRebuildMatchesPlaintextOracle() {
	global _AhkSubDir
	global KL_ENC_Enabled, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
	global KL_ENC_MachineIdOverride, KL_ENC_MachineIdOverrideActive
	static ModuleHandle := 0

	Root := A_Temp . "\ergopti_audit_ahk_004_" . A_TickCount
	DeviceId := "audit-ahk-004-device"
	PlainDeviceId := "audit-ahk-004-plain"
	DeviceDir := Root . "\by_device\" . DeviceId
	PlainDeviceDir := Root . "\by_device\" . PlainDeviceId
	LedgerPath := DeviceDir . "\data.sql"
	PlainLedgerPath := PlainDeviceDir . "\data.sql"
	Today := FormatTime(A_Now, "yyyy-MM-dd")
	Timestamp := Today . " 12:34:00.000"
	App := "audit-editor.exe"
	Candidate := 0
	Saved := Map(
		"ahk_subdir_set", IsSet(_AhkSubDir),
		"ahk_subdir", IsSet(_AhkSubDir) ? _AhkSubDir : "",
		"device_id", Keylogger.device_id,
		"device_lit", Keylogger._device_id_lit,
		"enabled", KL_ENC_Enabled,
		"key", KL_ENC_KeyBuffer,
		"derivation_failed", KL_ENC_DerivationFailed,
		"override", KL_ENC_MachineIdOverride,
		"override_active", KL_ENC_MachineIdOverrideActive)

	try {
		if !ModuleHandle
			ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
		AssertTrue(ModuleHandle != 0,
			"the real SQLite DLL must stay loaded for the encrypted rebuild fixture")
		_AhkSubDir := ""
		Keylogger.device_id := DeviceId
		Keylogger._device_id_lit := KL_SqlStr(DeviceId)
		KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000004")
		KL_Enc_SetEnabled(true)
		Events := [
			["a", 25, Map("kc", 65, "sk", 30)],
			["b", 30, Map("kc", 66, "sk", 48)]
		]
		Entry := Map(
			"type", "typing",
			"timestamp", Timestamp,
			"app", App,
			"title", "Encrypted rebuild fixture",
			"layout", "fr",
			"pause_before_ms", 0,
			"text", "audit-secret-typed",
			"events", Events)
		InsertSql := KL_BuildInsertTyping(Entry, 1)
		AssertTrue(InsertSql != "",
			"the production writer must emit the encrypted typing row")
		AssertContains(InsertSql, "ergopti-enc-v1:",
			"the durable fixture must use the production cipher envelope")
		AssertFalse(InStr(InsertSql, "audit-secret-typed") > 0,
			"the writer fixture must not leak its literal typed text")

		DirCreate(DeviceDir)
		_KLRSQL_WriteFixture(LedgerPath,
			"BEGIN IMMEDIATE;" . InsertSql . "COMMIT;")
		Keylogger.device_id := PlainDeviceId
		Keylogger._device_id_lit := KL_SqlStr(PlainDeviceId)
		KL_Enc_SetEnabled(false)
		PlainInsertSql := KL_BuildInsertTyping(Entry, 1)
		AssertContains(PlainInsertSql, "audit-secret-typed",
			"the control ledger must be the exact plaintext writer oracle")
		DirCreate(PlainDeviceDir)
		_KLRSQL_WriteFixture(PlainLedgerPath,
			"BEGIN IMMEDIATE;" . PlainInsertSql . "COMMIT;")
		DurableBefore := FileRead(LedgerPath, "UTF-8")
		Candidate := KLR_BuildColdCandidate(Root . "\", "")
		AssertTrue(Candidate.Get("ok", false),
			"a fresh reader must accept an encrypted typing ledger")
		if !Candidate.Get("ok", false)
			return
		Db := Candidate["db"]

		Daily := SQLite_Query(Db,
			"SELECT chars FROM agg_app_day WHERE device_id=" . SQLite_Q(DeviceId)
			. " AND date=" . SQLite_Q(Today) . " AND app=" . SQLite_Q(App) . ";")
		AssertEqual(1, Daily.Length,
			"the encrypted row must rebuild one daily dashboard bucket")
		AssertEqual(2, Daily[1]["chars"],
			"daily chars must equal the two physical plaintext events")
		PlainDaily := SQLite_Query(Db,
			"SELECT chars FROM agg_app_day WHERE device_id=" . SQLite_Q(PlainDeviceId)
			. " AND date=" . SQLite_Q(Today) . " AND app=" . SQLite_Q(App) . ";")
		AssertEqual(1, PlainDaily.Length,
			"the plaintext oracle must rebuild the same daily dashboard bucket")
		AssertEqual(PlainDaily[1]["chars"], Daily[1]["chars"],
			"encrypted and plaintext daily projections must be identical")

		Hourly := SQLite_Query(Db,
			"SELECT c FROM agg_app_day_hourly WHERE device_id=" . SQLite_Q(DeviceId)
			. " AND date=" . SQLite_Q(Today) . " AND app=" . SQLite_Q(App)
			. " AND hour='12';")
		AssertEqual(1, Hourly.Length,
			"the encrypted row must rebuild its hourly dashboard bucket")
		AssertEqual(2, Hourly[1]["c"],
			"hourly chars must reconcile with the daily plaintext oracle")
		PlainHourly := SQLite_Query(Db,
			"SELECT c FROM agg_app_day_hourly WHERE device_id=" . SQLite_Q(PlainDeviceId)
			. " AND date=" . SQLite_Q(Today) . " AND app=" . SQLite_Q(App)
			. " AND hour='12';")
		AssertEqual(1, PlainHourly.Length,
			"the plaintext oracle must rebuild the same hourly dashboard bucket")
		AssertEqual(PlainHourly[1]["c"], Hourly[1]["c"],
			"encrypted and plaintext hourly projections must be identical")

		Dashboard := KLR_ReadRangeSplitToday(Db, Today, Today, [App])
		AssertTrue(Dashboard["today"].Has(App),
			"the dashboard reader must expose n-grams rebuilt from encrypted events")
		AssertTrue(Dashboard["today"][App]["c"].Has("a"),
			"the first decrypted character must reach the dashboard n-gram projection")
		EncryptedNgram := SQLite_Query(Db,
			"SELECT c FROM ngram_chars WHERE device_id=" . SQLite_Q(DeviceId)
			. " AND date=" . SQLite_Q(Today) . " AND app=" . SQLite_Q(App)
			. " AND token='a';")
		PlainNgram := SQLite_Query(Db,
			"SELECT c FROM ngram_chars WHERE device_id=" . SQLite_Q(PlainDeviceId)
			. " AND date=" . SQLite_Q(Today) . " AND app=" . SQLite_Q(App)
			. " AND token='a';")
		AssertEqual(1, EncryptedNgram.Length)
		AssertEqual(1, PlainNgram.Length)
		AssertEqual(PlainNgram[1]["c"], EncryptedNgram[1]["c"],
			"encrypted and plaintext n-gram projections must be identical")

		RawRows := SQLite_Query(Db,
			"SELECT events_json FROM events_typing WHERE device_id="
			. SQLite_Q(DeviceId) . " AND id=1;")
		AssertEqual(1, RawRows.Length,
			"the raw encrypted event must remain present in the in-memory database")
		AssertTrue(KL_Enc_IsEncrypted(RawRows[1]["events_json"]),
			"reader projections must not overwrite the authoritative raw ciphertext")
		DurableAfter := FileRead(LedgerPath, "UTF-8")
		AssertEqual(DurableBefore, DurableAfter,
			"a rebuild must be read-only with respect to the durable ledger")
		AssertContains(DurableAfter, "ergopti-enc-v1:",
			"the persisted bytes must remain encrypted after projection rebuild")
	} finally {
		if Candidate is Map
			try SQLite_Close(Candidate.Get("db", 0))
		try DirDelete(Root, true)
		Keylogger.device_id := Saved["device_id"]
		Keylogger._device_id_lit := Saved["device_lit"]
		KL_ENC_Enabled := Saved["enabled"]
		KL_ENC_KeyBuffer := Saved["key"]
		KL_ENC_DerivationFailed := Saved["derivation_failed"]
		KL_ENC_MachineIdOverride := Saved["override"]
		KL_ENC_MachineIdOverrideActive := Saved["override_active"]
		if Saved["ahk_subdir_set"]
			_AhkSubDir := Saved["ahk_subdir"]
		else
			_AhkSubDir := unset
	}
}

Test("Keylogger reader: encrypted restart rebuild matches plaintext projections (audit-ahk-004)",
	_KLRER_EncryptedTypingRebuildMatchesPlaintextOracle)
