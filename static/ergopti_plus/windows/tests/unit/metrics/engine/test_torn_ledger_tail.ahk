; tests/unit/metrics/engine/test_torn_ledger_tail.ahk

; ==============================================================================
; MODULE: Crash-Torn Ledger Tail Tests
; DESCRIPTION:
; A process that dies inside an append leaves bytes past the receipt state.json
; acknowledged. Replaying the real boot repair and the real ingest proves the
; ledger stays readable SQL and that the interrupted events are written again,
; once (2026-10-28 audit, remaining finding 1). Each torn shape was unreadable
; before the repair: the next batch became text of the unterminated literal.
; ==============================================================================

#Requires AutoHotkey v2.0

_KTLT_Tail(Mode) {
	Literal := "`nBEGIN TRANSACTION;`nINSERT INTO events_shortcut (id) VALUES ('"
	switch Mode {
		case "literal": return Literal . "unterminated"
		case "commit": return "`nBEGIN TRANSACTION;`nINSERT INTO events_shortcut (id) VALUES (99);`nCOM"
		case "fake-commit": return Literal . "typed text`nCOMMIT;`n"
		case "utf8": return Literal . "é"
		case "complete": return "`nBEGIN TRANSACTION;`nCOMMIT;`n"
	}
	throw ValueError("Unknown torn tail mode.")
}

; The last byte of the UTF-8 mode is cut so a multi-byte character stays split.
_KTLT_AppendRaw(Path, Text, CutBytes := 0) {
	Size := StrPut(Text, "UTF-8") - 1
	Bytes := Buffer(Size)
	StrPut(Text, Bytes, Size, "UTF-8")
	Fh := FileOpen(Path, "a-w", "UTF-8-RAW")
	try Fh.RawWrite(Bytes, Size - CutBytes)
	finally Fh.Close()
}

_KTLT_Entry(Id) {
	return Map("type", "shortcut", "_event_id", Id,
		"timestamp", KL_NowTimestamp(), "app", "fixture.exe", "key", "Ctrl+C")
}

_KTLT_Scenario(Mode) {
	Names := ["initialized", "_shutting_down", "rollover_in_progress", "today_log_path",
		"today_log_offset", "today_log_date", "state_json_path", "data_sql_path",
		"_today_fh", "_today_fh_date", "_pending_entries", "next_event_id", "rollover_pending",
		"data_sql_receipt"]
	Saved := Map()
	for Name in Names
		if Keystats.HasOwnProp(Name)
			Saved[Name] := Keystats.%Name%
	Windows := KLWV.windows
	Context := KLW.ctx
	Batch := KLW.batch
	Root := _FSWL_Path() . "-torn"
	OwnsRoot := false
	OwnsJournal := false
	Db := 0
	try {
		AssertFalse(DirExist(Root))
		DirCreate(Root)
		OwnsRoot := true
		Keystats.initialized := true
		Keystats._shutting_down := false
		Keystats.rollover_in_progress := false
		Keystats.rollover_pending := 0
		Keystats.data_sql_receipt := 0
		Keystats.today_log_path := Root . "\today.log"
		Keystats.today_log_offset := 0
		Keystats.today_log_date := KL_Today()
		Keystats.state_json_path := Root . "\state.json"
		Keystats.data_sql_path := Root . "\data.sql"
		Keystats._today_fh := unset
		OwnsJournal := true
		Keystats._today_fh_date := ""
		Keystats._pending_entries := []
		Keystats.next_event_id := 20
		KLWV.windows := Map()
		KLW.ctx := Map()
		KLW_ResetBatch()
		FileAppend("-- synthetic torn ledger`n", Keystats.data_sql_path, "UTF-8-RAW")
		FileAppend(KL_JsonEncode(_KTLT_Entry(10)) . "`n", Keystats.today_log_path, "UTF-8-RAW")
		AssertTrue(KL_IngestOnce(true, true)["ok"], "commit one genuine batch")
		Boundary := FileGetSize(Keystats.data_sql_path)
		Offset := Keystats.today_log_offset

		; The crash: a new journal line, then an append that never finished.
		FileAppend(KL_JsonEncode(_KTLT_Entry(11)) . "`n", Keystats.today_log_path, "UTF-8-RAW")
		_KTLT_AppendRaw(Keystats.data_sql_path, _KTLT_Tail(Mode), Mode = "utf8" ? 1 : 0)
		Assert(FileGetSize(Keystats.data_sql_path) > Boundary, "the fixture must leave a tail")

		; The next boot reloads the durable state, as KL_Init does.
		Keystats.data_sql_receipt := 0
		Keystats.today_log_offset := 0
		AssertTrue(KL_LoadState())
		AssertEqual(Offset, Keystats.today_log_offset)
		AssertTrue(KL_AdmitExistingDataSql(), "boot admits a ledger it can repair")
		AssertEqual(Boundary, FileGetSize(Keystats.data_sql_path),
			"the unacknowledged bytes must go, whatever their lexical shape")
		AssertEqual(Offset, Keystats.today_log_offset, "repair must not move the journal offset")

		AssertTrue(KL_IngestOnce(true, true)["ok"], "the interrupted event must be ingested again")
		AssertEqual(FileGetSize(Keystats.today_log_path), Keystats.today_log_offset)

		Db := _WJFM_OpenMemory()
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, FileRead(Keystats.data_sql_path, "UTF-8")),
			"the whole ledger must stay readable SQL")
		Rows := SQLite_Query(Db, "SELECT id FROM events_shortcut ORDER BY id;")
		AssertEqual(2, Rows.Length, "both events exactly once, torn tail excluded")
		AssertEqual(10, Rows[1]["id"])
		AssertEqual(11, Rows[2]["id"])
	} finally {
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
		KLW.ctx := Context
		KLW.batch := Batch
		if OwnsRoot && DirExist(Root)
			DirDelete(Root, true)
	}
}
for _KTLTMode in ["literal", "commit", "fake-commit", "utf8", "complete"]
	Test("keystats: boot repair after a " . _KTLTMode . " tail keeps the ledger readable (torn-ledger-tail)",
		_KTLT_Scenario.Bind(_KTLTMode))

; A receipt describes one file. A ledger the migration published, or a backup,
; has another identity: its longer bytes are history, never a torn tail.
_KTLT_ForeignFile() {
	Root := _FSWL_Path() . "-torn-foreign"
	DirCreate(Root)
	try {
		Path := Root . "\data.sql"
		FileAppend("-- ledger`n", Path, "UTF-8-RAW")
		AssertTrue(KL_AppendDataSqlDurable(Path, "SELECT 1;`n"))
		Receipt := KL_DataSqlAckReceipt(Path)
		AssertEqual(FileGetSize(Path), Receipt["end"])
		FileMove(Path, Root . "\old.sql")
		FileAppend("-- a migrated ledger, longer than the receipt says`nSELECT 2;`n", Path, "UTF-8-RAW")
		Before := FileRead(Path, "UTF-8-RAW")
		Assert(StrLen(Before) > Receipt["end"], "the replacement must exceed the receipt")
		AssertEqual(0, KL_DataSqlRepairTail(Path, Receipt))
		AssertEqual(Before, FileRead(Path, "UTF-8-RAW"))
	} finally {
		DirDelete(Root, true)
	}
}
Test("keystats: a receipt never cuts a file with another identity (torn-ledger-tail)", _KTLT_ForeignFile)

; No receipt yet means no boundary to enforce: the ledger is admitted untouched.
_KTLT_NoReceipt() {
	Root := _FSWL_Path() . "-torn-none"
	DirCreate(Root)
	try {
		Path := Root . "\data.sql"
		FileAppend("-- ledger`nSELECT 1;`n", Path, "UTF-8-RAW")
		Before := FileGetSize(Path)
		AssertEqual(0, KL_DataSqlRepairTail(Path, 0))
		AssertEqual(Before, FileGetSize(Path))
	} finally {
		DirDelete(Root, true)
	}
}
Test("keystats: a ledger without a receipt is admitted untouched (torn-ledger-tail)", _KTLT_NoReceipt)

; A malformed receipt must not authorize a truncation at the next boot.
_KTLT_MalformedReceipt() {
	Base := Map("volume", 1, "index_high", 2, "index_low", 3, "end", 4)
	AssertTrue(_KL_DataSqlReceiptValid(Base))
	for Name in ["volume", "index_high", "index_low", "end"]
		for Bad in ["1", -1] {
			Copy := Base.Clone()
			Copy[Name] := Bad
			AssertFalse(_KL_DataSqlReceiptValid(Copy), Name)
		}
	Copy := Base.Clone()
	Copy.Delete("end")
	AssertFalse(_KL_DataSqlReceiptValid(Copy))
	AssertFalse(_KL_DataSqlReceiptValid(0))
}
Test("keystats: only a well-formed receipt may name a tail (torn-ledger-tail)", _KTLT_MalformedReceipt)
