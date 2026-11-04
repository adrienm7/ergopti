; tests/unit/modules/keystats/test_keystats_rollover_recovery.ahk

; ==============================================================================
; MODULE: Keystats Rollover Recovery Integration Tests
; DESCRIPTION: Native state refusal cannot strand a consumed journal checkpoint.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRR_StateRefusal(Mode := "prepare") {
	Names := ["initialized", "_shutting_down", "rollover_in_progress", "today_log_path",
		"today_log_offset", "today_log_date", "state_json_path", "data_sql_path",
		"_today_fh", "_today_fh_date", "_pending_entries", "next_event_id", "rollover_pending"]
	Saved := Map()
	for Name in Names
		if Keystats.HasOwnProp(Name)
			Saved[Name] := Keystats.%Name%
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
		Keystats.initialized := true
		Keystats._shutting_down := false
		Keystats.rollover_in_progress := false
		Keystats.rollover_pending := 0
		Keystats.today_log_path := Root . "\today.log"
		Keystats.today_log_offset := 0
		Keystats.today_log_date := "2000-01-01"
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
		Entry := Map("type", "shortcut", "_event_id", 10,
			"timestamp", KL_NowTimestamp(), "app", "fixture.exe", "key", "Ctrl+C")
		FileAppend(KL_JsonEncode(Entry) . "`n", Keystats.today_log_path, "UTF-8-RAW")
		FileAppend("-- synthetic rollover ledger`n", Keystats.data_sql_path, "UTF-8-RAW")
		AssertTrue(KL_IngestOnce(true, true)["ok"], "prepare a genuinely committed journal")
		Offset := Keystats.today_log_offset
		AssertEqual(FileGetSize(Keystats.today_log_path), Offset)
		Assert(Offset > 0)
		KLW.ctx := Map("old-day", Map("word", "synthetic"))
		AssertTrue(KL_SaveState())
		Before := KLR_LedgerSnapshot(Keystats.today_log_path)
		if Mode != "prepare" {
			Scope := _KL_JournalEnter()
			AssertTrue(IsObject(Scope))
			try AssertTrue(_KL_RolloverPrepare(Scope.Token, KL_Today()))
			finally _KL_JournalLeave(Scope)
			AssertTrue(_KL_RolloverPending() is Map)
		}
		if Mode = "changed" || Mode = "replaced" {
			if Mode = "replaced"
				FileMove(Keystats.today_log_path, Root . "\prior.log")
			FileAppend(KL_JsonEncode(Entry) . "`n", Keystats.today_log_path, "UTF-8-RAW")
			Changed := KLR_LedgerSnapshot(Keystats.today_log_path)
			AssertFalse(KL_DayRollover()["ok"], "changed bytes invalidate the consumed-file proof")
			AssertTrue(KLR_LedgerSnapshotIsSame(Changed, KLR_LedgerSnapshot(Keystats.today_log_path)))
			AssertTrue(_KL_RolloverPending() is Map)
			return
		}
		StateBefore := FileRead(Keystats.state_json_path, "UTF-8")
		if Mode = "malformed" {
			Malformed := KL_JsonDecode(StateBefore)
			Malformed["rollover_pending"]["version"] := "1"
			FileDelete(Keystats.state_json_path)
			FileAppend(KL_JsonEncode(Malformed), Keystats.state_json_path, "UTF-8-RAW")
			Keystats.rollover_pending := 0
			Keystats.next_event_id := 77
			AssertFalse(KL_LoadState())
			AssertEqual(77, Keystats.next_event_id)
			AssertFalse(KL_DayRollover()["ok"])
			AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Keystats.today_log_path)))
			return
		}
		StateLock := FileOpen(Mode = "delete" ? Keystats.today_log_path : Keystats.state_json_path, "r-wd")
		Refused := KL_DayRollover()
		AssertFalse(Refused["ok"])
		AssertEqual(StateBefore, FileRead(Keystats.state_json_path, "UTF-8"))
		if Mode = "prepare" || Mode = "delete" {
			AssertTrue(FileExist(Keystats.today_log_path),
				"without a durable recovery receipt, state refusal must preserve the consumed journal")
			AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Keystats.today_log_path)))
		} else {
			AssertFalse(FileExist(Keystats.today_log_path), "the refusal must occur after deletion")
			AssertTrue(_KL_RolloverPending() is Map, "final refusal must retain the recovery receipt")
			AssertThrows(() => KL_OpenTodayFh(), "new writers must remain fenced during failed recovery")
			AssertFalse(FileExist(Keystats.today_log_path))
		}
		AssertEqual(Offset, Keystats.today_log_offset)
		AssertTrue(KLW.ctx.Has("old-day"), "failed finalization must restore the previous context")
		StateLock.Close()
		StateLock := 0
		if Mode = "restore" {
			Keystats.today_log_date := ""
			Keystats.today_log_offset := 0
			Keystats.next_event_id := 1
			Keystats.rollover_pending := 0
			AssertTrue(KL_LoadState())
			AssertEqual(Offset, Keystats.today_log_offset)
			AssertTrue(_KL_RolloverPending() is Map)
		}
		Accepted := KL_DayRollover()
		AssertTrue(Accepted["ok"], "unlocked retry must complete the day transition")
		AssertEqual(0, Keystats.today_log_offset)
		AssertEqual(KL_Today(), Keystats.today_log_date)
		AssertFalse(FileExist(Keystats.today_log_path))
		State := KL_JsonDecode(FileRead(Keystats.state_json_path, "UTF-8"))
		AssertFalse(State.Has("rollover_pending"))
		AssertEqual(0, State["today_log_offset"])
		AssertEqual(0, State["ngram_ctx"].Count)
		Db := _WJFM_OpenMemory()
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, FileRead(Keystats.data_sql_path, "UTF-8")))
		Rows := SQLite_Query(Db, "SELECT id FROM events_shortcut;")
		AssertEqual(1, Rows.Length)
		AssertEqual(10, Rows[1]["id"])
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
		KLW.ctx := Context
		KLW.batch := Batch
		if OwnsRoot && DirExist(Root)
			DirDelete(Root, true)
	}
}
for Mode in ["prepare", "delete", "final", "restore", "changed", "replaced", "malformed"]
	Test("keystats: recoverable day transition " . Mode . " (rollover-state-recovery)",
		_KLRR_StateRefusal.Bind(Mode))
