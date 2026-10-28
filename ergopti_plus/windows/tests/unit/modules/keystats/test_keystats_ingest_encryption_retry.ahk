; tests/unit/modules/keystats/test_keystats_ingest_encryption_retry.ahk

; ==============================================================================
; MODULE: Journal Encryption Retry Integration Tests
; DESCRIPTION: Exercise real journal ingestion without installing input hooks.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../../../modules/keystats/keystats_ingest.ahk
#Include ../../../../modules/keystats/keystats_rollover.ahk
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
		if Keystats.HasOwnProp(Name)
			Saved[Name] := Keystats.%Name%
	Windows := KLWV.windows
	Root := _FSWL_Path() . "-ingest"
	Db := 0
	StateLock := 0
	OwnsRoot := false
	OwnsJournal := false
	try {
		AssertFalse(DirExist(Root), "the fixture must own a fresh directory")
		DirCreate(Root)
		OwnsRoot := true
		Keystats.initialized := true
		Keystats._shutting_down := false
		Keystats.today_log_path := Root . "\today.log"
		Keystats.today_log_offset := 0
		Keystats.today_log_date := KL_Today()
		Keystats.state_json_path := Root . "\state.json"
		Keystats.data_sql_path := Root . "\data.sql"
		Keystats._today_fh := unset
		OwnsJournal := true
		Keystats._today_fh_date := ""
		Keystats.next_event_id := 20
		KLWV.windows := Map()
		Entry := Map("type", "typing", "_event_id", 10, "timestamp", KL_NowTimestamp(),
			"app", "fixture.exe", "text", "synthetic-private-marker",
			"events", [["x", 120, Map()]])
		Keystats._pending_entries := Mode = "pending" ? [Entry] : []
		FileAppend(Mode = "pending" ? "" : KL_JsonEncode(Entry) . "`n",
			Keystats.today_log_path, "UTF-8-RAW")
		if Mode = "mixed"
			Keystats._pending_entries.Push(Map("type", "shortcut", "_event_id", 11,
				"timestamp", KL_NowTimestamp(), "app", "fixture.exe", "key", "Ctrl+C"))
		FileAppend("-- prior`n", Keystats.data_sql_path, "UTF-8-RAW")
		AssertTrue(KL_SaveState())
		StateBefore := FileRead(Keystats.state_json_path, "UTF-8")
		KL_Enc_SetMachineIdOverride(Mode = "state" ? "00000000-0000-0000-0000-000000000001" : "")
		KL_Enc_SetEnabled(true)
		if Mode = "state"
			StateLock := FileOpen(Keystats.state_json_path, "r-wd")
		Refused := KL_IngestOnce(true, true)
		if IsObject(StateLock) {
			StateLock.Close()
			StateLock := 0
		}
		AssertFalse(Refused["ok"], "publication refusal must not acknowledge the consumed journal")
		AssertEqual(0, Keystats.today_log_offset)
		AssertEqual(StateBefore, FileRead(Keystats.state_json_path, "UTF-8"))
		if Mode = "state" {
			AssertEqual("state_failed", Refused["reason"])
			AssertContains(FileRead(Keystats.data_sql_path, "UTF-8"), "INSERT OR IGNORE INTO events_typing",
				"the refusal must occur after the SQL append")
		} else {
			AssertEqual("-- prior`n", FileRead(Keystats.data_sql_path, "UTF-8"),
				"a mixed batch must not partially publish its unencrypted sibling")
		}
		JournalBeforeRetry := FileRead(Keystats.today_log_path, "UTF-8")
		JournalRead := _KL_JournalReadLines(Keystats.today_log_path, 0, 10, KL_JsonDecode)
		AssertEqual(Mode = "mixed" ? 2 : 1, JournalRead["entries"].Length,
			"the synthetic journal must retain every refused event: " . JournalBeforeRetry)
		AssertEqual(0, Keystats._pending_entries.Length,
			"durably journaled rows must not also be requeued")
		KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
		Accepted := KL_IngestOnce(true, true)
		AssertTrue(Accepted["ok"])
		AssertEqual(FileGetSize(Keystats.today_log_path), Keystats.today_log_offset)
		AssertEqual(JournalBeforeRetry, FileRead(Keystats.today_log_path, "UTF-8"))
		Sql := FileRead(Keystats.data_sql_path, "UTF-8")
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
		AssertEqual(Sql, FileRead(Keystats.data_sql_path, "UTF-8"), "a drained journal must not append again")
	} finally {
		if IsObject(StateLock)
			StateLock.Close()
		if Db
			SQLite_Close(Db)
		if OwnsJournal && Keystats.HasOwnProp("_today_fh") && IsObject(Keystats._today_fh)
			Keystats._today_fh.Close()
		for Name in Names {
			if Saved.Has(Name)
				Keystats.%Name% := Saved[Name]
			else if Keystats.HasOwnProp(Name)
				Keystats.DeleteProp(Name)
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
	Test("Keystats ingestion: encryption retry " . Mode . " (ingest-encryption-retry)",
		_KIER_EncryptionRetry.Bind(Mode))

; The harness writes state directly. This tests ingestion's failure transaction,
; not the production atomic rename implementation.
Test("Keystats ingestion: state refusal after SQL append replays exactly once (ingest-state-retry)",
	_KIER_EncryptionRetry.Bind("state"))

_KIER_RequeueOnlyUnwritten() {
	Saved := Keystats._pending_entries
	Logged := Map("id", 1)
	Unwritten := Map("id", 2)
	Newer := Map("id", 3)
	try {
		Keystats._pending_entries := [Newer]
		AssertEqual(1, _KL_IngestRequeueUnwritten([Logged, Unwritten], 1))
		AssertEqual(2, Keystats._pending_entries.Length)
		AssertTrue(Keystats._pending_entries[1] == Unwritten)
		AssertTrue(Keystats._pending_entries[2] == Newer)
		AssertEqual(0, _KL_IngestRequeueUnwritten([Logged], 1))
		AssertEqual(2, Keystats._pending_entries.Length, "journaled entries must not also return to RAM")
		AssertThrows(() => _KL_IngestRequeueUnwritten([Logged], 2),
			"invalid ownership counts must fail before mutation")
		AssertEqual(2, Keystats._pending_entries.Length)
	} finally Keystats._pending_entries := Saved
}
Test("Keystats ingestion: retry restores only unwritten ownership (ingest-encryption-retry)",
	_KIER_RequeueOnlyUnwritten)
