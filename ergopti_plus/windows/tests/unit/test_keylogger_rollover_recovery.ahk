; tests/unit/test_keylogger_rollover_recovery.ahk

; ==============================================================================
; MODULE: Keylogger Rollover Recovery Integration Tests
; DESCRIPTION: Native state refusal cannot strand a consumed journal checkpoint.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRR_StateRefusal(Mode := "prepare") {
	Names := ["initialized", "_shutting_down", "rollover_in_progress", "today_log_path",
		"today_log_offset", "today_log_date", "state_json_path", "data_sql_path",
		"_today_fh", "_today_fh_date", "_pending_entries", "next_event_id", "rollover_pending"]
	Saved := Map()
	for Name in Names
		if Keylogger.HasOwnProp(Name)
			Saved[Name] := Keylogger.%Name%
	Windows := KLWV.windows
	Context := KLW.ctx
	Batch := KLW.batch
	Root := _FSWL_Path() . "-rollover"
	OwnsRoot := false
	OwnsJournal := false
	StateLock := 0
	Db := 0
	try {
		AssertFalse(DirExist(Root))
		DirCreate(Root)
		OwnsRoot := true
		Keylogger.initialized := true
		Keylogger._shutting_down := false
		Keylogger.rollover_in_progress := false
		Keylogger.rollover_pending := 0
		Keylogger.today_log_path := Root . "\today.log"
		Keylogger.today_log_offset := 0
		Keylogger.today_log_date := "2000-01-01"
		Keylogger.state_json_path := Root . "\state.json"
		Keylogger.data_sql_path := Root . "\data.sql"
		Keylogger._today_fh := unset
		OwnsJournal := true
		Keylogger._today_fh_date := ""
		Keylogger._pending_entries := []
		Keylogger.next_event_id := 20
		KLWV.windows := Map()
		KLW.ctx := Map()
		KLW_ResetBatch()
		Entry := Map("type", "shortcut", "_event_id", 10,
			"timestamp", KL_NowTimestamp(), "app", "fixture.exe", "key", "Ctrl+C")
		FileAppend(KL_JsonEncode(Entry) . "`n", Keylogger.today_log_path, "UTF-8-RAW")
		FileAppend("-- synthetic rollover ledger`n", Keylogger.data_sql_path, "UTF-8-RAW")
		AssertTrue(KL_IngestOnce(true, true)["ok"], "prepare a genuinely committed journal")
		Offset := Keylogger.today_log_offset
		AssertEqual(FileGetSize(Keylogger.today_log_path), Offset)
		Assert(Offset > 0)
		KLW.ctx := Map("old-day", Map("word", "synthetic"))
		AssertTrue(KL_SaveState())
		Before := KLR_LedgerSnapshot(Keylogger.today_log_path)
		if Mode != "prepare" {
			Scope := _KL_JournalEnter()
			AssertTrue(IsObject(Scope))
			try AssertTrue(_KL_RolloverPrepare(Scope.Token, KL_Today()))
			finally _KL_JournalLeave(Scope)
			AssertTrue(_KL_RolloverPending() is Map)
		}
		if Mode = "changed" || Mode = "replaced" {
			if Mode = "replaced"
				FileMove(Keylogger.today_log_path, Root . "\prior.log")
			FileAppend(KL_JsonEncode(Entry) . "`n", Keylogger.today_log_path, "UTF-8-RAW")
			Changed := KLR_LedgerSnapshot(Keylogger.today_log_path)
			AssertFalse(KL_DayRollover()["ok"], "changed bytes invalidate the consumed-file proof")
			AssertTrue(KLR_LedgerSnapshotIsSame(Changed, KLR_LedgerSnapshot(Keylogger.today_log_path)))
			AssertTrue(_KL_RolloverPending() is Map)
			return
		}
		StateBefore := FileRead(Keylogger.state_json_path, "UTF-8")
		if Mode = "malformed" {
			Malformed := KL_JsonDecode(StateBefore)
			Malformed["rollover_pending"]["version"] := "1"
			FileDelete(Keylogger.state_json_path)
			FileAppend(KL_JsonEncode(Malformed), Keylogger.state_json_path, "UTF-8-RAW")
			Keylogger.rollover_pending := 0
			Keylogger.next_event_id := 77
			AssertFalse(KL_LoadState())
			AssertEqual(77, Keylogger.next_event_id)
			AssertFalse(KL_DayRollover()["ok"])
			AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Keylogger.today_log_path)))
			return
		}
		StateLock := FileOpen(Mode = "delete" ? Keylogger.today_log_path : Keylogger.state_json_path, "r-wd")
		Refused := KL_DayRollover()
		AssertFalse(Refused["ok"])
		AssertEqual(StateBefore, FileRead(Keylogger.state_json_path, "UTF-8"))
		if Mode = "prepare" || Mode = "delete" {
			AssertTrue(FileExist(Keylogger.today_log_path),
				"without a durable recovery receipt, state refusal must preserve the consumed journal")
			AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Keylogger.today_log_path)))
		} else {
			AssertFalse(FileExist(Keylogger.today_log_path), "the refusal must occur after deletion")
			AssertTrue(_KL_RolloverPending() is Map, "final refusal must retain the recovery receipt")
			AssertThrows(() => KL_OpenTodayFh(), "new writers must remain fenced during failed recovery")
			AssertFalse(FileExist(Keylogger.today_log_path))
		}
		AssertEqual(Offset, Keylogger.today_log_offset)
		AssertTrue(KLW.ctx.Has("old-day"), "failed finalization must restore the previous context")
		StateLock.Close()
		StateLock := 0
		if Mode = "restore" {
			Keylogger.today_log_date := ""
			Keylogger.today_log_offset := 0
			Keylogger.next_event_id := 1
			Keylogger.rollover_pending := 0
			AssertTrue(KL_LoadState())
			AssertEqual(Offset, Keylogger.today_log_offset)
			AssertTrue(_KL_RolloverPending() is Map)
		}
		Accepted := KL_DayRollover()
		AssertTrue(Accepted["ok"], "unlocked retry must complete the day transition")
		AssertEqual(0, Keylogger.today_log_offset)
		AssertEqual(KL_Today(), Keylogger.today_log_date)
		AssertFalse(FileExist(Keylogger.today_log_path))
		State := KL_JsonDecode(FileRead(Keylogger.state_json_path, "UTF-8"))
		AssertFalse(State.Has("rollover_pending"))
		AssertEqual(0, State["today_log_offset"])
		AssertEqual(0, State["ngram_ctx"].Count)
		Db := _WJFM_OpenMemory()
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, FileRead(Keylogger.data_sql_path, "UTF-8")))
		Rows := SQLite_Query(Db, "SELECT id FROM events_shortcut;")
		AssertEqual(1, Rows.Length)
		AssertEqual(10, Rows[1]["id"])
	} finally {
		if IsObject(StateLock)
			StateLock.Close()
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
		KLW.ctx := Context
		KLW.batch := Batch
		if OwnsRoot && DirExist(Root)
			DirDelete(Root, true)
	}
}
for Mode in ["prepare", "delete", "final", "restore", "changed", "replaced", "malformed"]
	Test("keylogger: recoverable day transition " . Mode . " (rollover-state-recovery)",
		_KLRR_StateRefusal.Bind(Mode))
