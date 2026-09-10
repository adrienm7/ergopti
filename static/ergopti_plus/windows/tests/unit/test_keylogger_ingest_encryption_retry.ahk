; tests/unit/test_keylogger_ingest_encryption_retry.ahk

; ==============================================================================
; MODULE: Journal Encryption Retry Integration Tests
; DESCRIPTION: Exercise real journal ingestion without installing input hooks.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../modules/keylogger/keylogger_ingest.ahk

; Rollover belongs to the resident lifecycle. These cases explicitly own the
; current day; reaching this boundary would invalidate their fixture.
KL_DayRollover(Token := 0) {
	throw Error("Unexpected rollover in isolated ingestion test.")
}

_KIER_EncryptionRetry(Mode) {
	global KL_ENC_Enabled, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
	global KL_ENC_MachineIdOverride, KL_ENC_MachineIdOverrideActive
	Cipher := [KL_ENC_Enabled, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed,
		KL_ENC_MachineIdOverride, KL_ENC_MachineIdOverrideActive]
	Names := ["initialized", "_shutting_down", "today_log_path", "today_log_offset",
		"today_log_date", "state_json_path", "data_sql_path", "_today_fh",
		"_today_fh_date", "_pending_entries", "next_event_id"]
	Saved := Map()
	for Name in Names
		if Keylogger.HasOwnProp(Name)
			Saved[Name] := Keylogger.%Name%
	Windows := KLWV.windows
	Root := _FSWL_Path() . "-ingest"
	Db := 0
	OwnsRoot := false
	OwnsJournal := false
	try {
		AssertFalse(DirExist(Root), "the fixture must own a fresh directory")
		DirCreate(Root)
		OwnsRoot := true
		Keylogger.initialized := true
		Keylogger._shutting_down := false
		Keylogger.today_log_path := Root . "\today.log"
		Keylogger.today_log_offset := 0
		Keylogger.today_log_date := KL_Today()
		Keylogger.state_json_path := Root . "\state.json"
		Keylogger.data_sql_path := Root . "\data.sql"
		Keylogger._today_fh := unset
		OwnsJournal := true
		Keylogger._today_fh_date := ""
		Keylogger.next_event_id := 20
		KLWV.windows := Map()
		Entry := Map("type", "typing", "_event_id", 10, "timestamp", KL_NowTimestamp(),
			"app", "fixture.exe", "text", "synthetic-private-marker",
			"events", [["x", 120, Map()]])
		Keylogger._pending_entries := Mode = "pending" ? [Entry] : []
		FileAppend(Mode = "pending" ? "" : KL_JsonEncode(Entry) . "`n",
			Keylogger.today_log_path, "UTF-8-RAW")
		if Mode = "mixed"
			Keylogger._pending_entries.Push(Map("type", "shortcut", "_event_id", 11,
				"timestamp", KL_NowTimestamp(), "app", "fixture.exe", "key", "Ctrl+C"))
		FileAppend("-- prior`n", Keylogger.data_sql_path, "UTF-8-RAW")
		AssertTrue(KL_SaveState())
		StateBefore := FileRead(Keylogger.state_json_path, "UTF-8")
		KL_Enc_SetMachineIdOverride("")
		KL_Enc_SetEnabled(true)
		Refused := KL_IngestOnce(true, true)
		AssertFalse(Refused["ok"], "encryption refusal must not acknowledge the consumed journal")
		AssertEqual(0, Keylogger.today_log_offset)
		AssertEqual(StateBefore, FileRead(Keylogger.state_json_path, "UTF-8"))
		AssertEqual("-- prior`n", FileRead(Keylogger.data_sql_path, "UTF-8"),
			"a mixed batch must not partially publish its unencrypted sibling")
		JournalBeforeRetry := FileRead(Keylogger.today_log_path, "UTF-8")
		JournalRead := _KL_JournalReadLines(Keylogger.today_log_path, 0, 10, KL_JsonDecode)
		AssertEqual(Mode = "mixed" ? 2 : 1, JournalRead["entries"].Length,
			"the synthetic journal must retain every refused event: " . JournalBeforeRetry)
		AssertEqual(0, Keylogger._pending_entries.Length,
			"durably journaled rows must not also be requeued")
		KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
		Accepted := KL_IngestOnce(true, true)
		AssertTrue(Accepted["ok"])
		AssertEqual(FileGetSize(Keylogger.today_log_path), Keylogger.today_log_offset)
		AssertEqual(JournalBeforeRetry, FileRead(Keylogger.today_log_path, "UTF-8"))
		Sql := FileRead(Keylogger.data_sql_path, "UTF-8")
		Assert(!InStr(Sql, Entry["text"]), "successful retry must still encrypt typing text")
		Db := _WJFM_OpenMemory()
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, Sql))
		Rows := SQLite_Query(Db, "SELECT id,text FROM events_typing;")
		AssertEqual(1, Rows.Length)
		AssertEqual(10, Rows[1]["id"], "retry must preserve the original reserved identity")
		AssertEqual(Entry["text"], KL_Enc_Decrypt(Rows[1]["text"]))
		AssertEqual(Mode = "mixed" ? 1 : 0,
			SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_shortcut;")[1]["n"])
		AssertTrue(KL_IngestOnce(true, true)["ok"])
		AssertEqual(Sql, FileRead(Keylogger.data_sql_path, "UTF-8"), "a drained journal must not append again")
	} finally {
		if Db
			SQLite_Close(Db)
		if OwnsJournal && Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh)
			Keylogger._today_fh.Close()
		for Name in Names {
			if Saved.Has(Name)
				Keylogger.%Name% := Saved[Name]
			else if Keylogger.HasOwnProp(Name)
				Keylogger.DeleteProp(Name)
		}
		KLWV.windows := Windows
		KL_ENC_Enabled := Cipher[1]
		KL_ENC_KeyBuffer := Cipher[2]
		KL_ENC_DerivationFailed := Cipher[3]
		KL_ENC_MachineIdOverride := Cipher[4]
		KL_ENC_MachineIdOverrideActive := Cipher[5]
		if OwnsRoot && DirExist(Root)
			DirDelete(Root, true)
	}
}

for Mode in ["disk", "mixed", "pending"]
	Test("Keylogger ingestion: encryption retry " . Mode . " (ingest-encryption-retry)",
		_KIER_EncryptionRetry.Bind(Mode))

_KIER_RequeueOnlyUnwritten() {
	Saved := Keylogger._pending_entries
	Logged := Map("id", 1)
	Unwritten := Map("id", 2)
	Newer := Map("id", 3)
	try {
		Keylogger._pending_entries := [Newer]
		AssertEqual(1, _KL_IngestRequeueUnwritten([Logged, Unwritten], 1))
		AssertEqual(2, Keylogger._pending_entries.Length)
		AssertTrue(Keylogger._pending_entries[1] == Unwritten)
		AssertTrue(Keylogger._pending_entries[2] == Newer)
		AssertEqual(0, _KL_IngestRequeueUnwritten([Logged], 1))
		AssertEqual(2, Keylogger._pending_entries.Length, "journaled entries must not also return to RAM")
		AssertThrows(() => _KL_IngestRequeueUnwritten([Logged], 2),
			"invalid ownership counts must fail before mutation")
		AssertEqual(2, Keylogger._pending_entries.Length)
	} finally Keylogger._pending_entries := Saved
}
Test("Keylogger ingestion: retry restores only unwritten ownership (ingest-encryption-retry)",
	_KIER_RequeueOnlyUnwritten)
