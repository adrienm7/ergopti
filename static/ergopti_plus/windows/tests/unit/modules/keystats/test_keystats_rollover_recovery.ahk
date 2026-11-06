; tests/unit/modules/keystats/test_keystats_rollover_recovery.ahk

; ==============================================================================
; MODULE: Keystats Rollover Recovery Integration Tests
; DESCRIPTION: Native state refusal cannot strand a consumed journal checkpoint.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRR_AfterProof(Root, Entry, Probe, Replace) {
	Probe["calls"] += 1
	Path := Keystats.today_log_path
	if Replace {
		AssertTrue(DllCall("Kernel32\MoveFileExW", "Str", Path, "Str", Root . "\consumed.log", "UInt", 8, "Int"),
			"the real verified reader permits rename at the original deletion cutpoint")
		FileAppend(KL_JsonEncode(Entry) . "`n", Path, "UTF-8-RAW")
	}
	Probe["snapshot"] := KLR_LedgerSnapshot(Path)
	AssertTrue(Probe["snapshot"].Get("ok", false), "the cutpoint observes a complete native source receipt")
}

; The deadline only aborts a faulty non-progressing drain; it never supplies
; a journal result or changes the real reader's framing/EOF contract.
_KLRR_DrainDeadline(Probe) {
	Probe["expired"] := true
	Keystats.initialized := false
}

_KLRR_StateRefusal(Mode := "prepare") {
	Names := ["initialized", "_shutting_down", "rollover_in_progress", "today_log_path",
		"today_log_offset", "today_log_date", "state_json_path", "data_sql_path",
		"_today_fh", "_today_fh_date", "_pending_entries", "next_event_id", "rollover_pending", "data_sql_receipt"]
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
		Keystats.data_sql_receipt := 0
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
		if Mode = "torn-drain" || Mode = "undelimited-drain" || Mode = "blank-batch-drain" {
			AssertTrue(KL_CloseTodayFh())
			Next := Entry.Clone()
			Next["_event_id"] := 11
			Fragment := Mode = "torn-drain" ? '{"type":"shortcut","_event_id":11' : KL_JsonEncode(Next)
			if Mode = "blank-batch-drain" {
				Blank := ""
				Loop KeystatsConst.INGEST_BATCH_LINES + 1
					Blank .= "`n"
				Fragment := Blank . Fragment . "`n"
			}
			FileAppend(Fragment, Keystats.today_log_path, "UTF-8-RAW")
			Pending := Entry.Clone()
			Pending["_event_id"] := 12
			Keystats._pending_entries := [Pending]
			SourceBefore := FileRead(Keystats.today_log_path, "UTF-8-RAW")
			ReceiptBefore := KLR_LedgerSnapshot(Keystats.today_log_path)
			StateBefore := FileRead(Keystats.state_json_path, "UTF-8-RAW")
			Probe := Map("expired", false)
			Deadline := _KLRR_DrainDeadline.Bind(Probe)
			try {
				SetTimer(Deadline, Mode = "blank-batch-drain" ? -5000 : -1000)
				Result := KL_DayRollover()
			} finally SetTimer(Deadline, 0)
			_TestPrint("# ROLLOVER_DRAIN_NATIVE_RETURN " . KL_JsonEncode(Map("mode", Mode,
				"deadline_used", Probe["expired"], "ok", Result["ok"], "reason", Result["reason"],
				"before_offset", Offset, "after_offset", Keystats.today_log_offset)))
			if Mode != "blank-batch-drain"
				AssertEqual(Offset, Keystats.today_log_offset, "the observed blocked reader must keep its original checkpoint")
			AssertFalse(Probe["expired"], "the real drain required a lifecycle escape: reason=" . Result["reason"]
				. ", checkpoint=" . Keystats.today_log_offset . ", original=" . Offset)
			if Mode = "blank-batch-drain" {
				AssertTrue(Result["ok"], "eventless bounded batches must keep draining when their byte checkpoint advances")
				AssertFalse(FileExist(Keystats.today_log_path))
				AssertEqual(0, Keystats._pending_entries.Length)
				Db := _WJFM_OpenMemory()
				AssertTrue(KLR_LoadSchema(Db))
				AssertTrue(SQLite_Exec(Db, FileRead(Keystats.data_sql_path, "UTF-8")))
				Rows := SQLite_Query(Db, "SELECT id FROM events_shortcut ORDER BY id;")
				AssertEqual(3, Rows.Length)
				AssertEqual(10, Rows[1]["id"])
				AssertEqual(11, Rows[2]["id"])
				AssertEqual(12, Rows[3]["id"])
				return
			}
			AssertFalse(Result["ok"])
			AssertEqual("journal_no_progress", Result["reason"])
			AssertEqual(Offset, Keystats.today_log_offset)
			AssertEqual("2000-01-01", Keystats.today_log_date)
			AssertFalse(_KL_RolloverPending())
			AssertEqual(1, Keystats._pending_entries.Length)
			AssertTrue(Pending == Keystats._pending_entries[1])
			AssertEqual(SourceBefore, FileRead(Keystats.today_log_path, "UTF-8-RAW"))
			AssertTrue(KLR_LedgerSnapshotIsSame(ReceiptBefore, KLR_LedgerSnapshot(Keystats.today_log_path)))
			AssertEqual(StateBefore, FileRead(Keystats.state_json_path, "UTF-8-RAW"))
			; Once a delimiter really exists, ordinary retry still drains and rotates.
			FileAppend("`n", Keystats.today_log_path, "UTF-8-RAW")
			AssertTrue(KL_DayRollover()["ok"])
			AssertFalse(FileExist(Keystats.today_log_path))
			AssertEqual(0, Keystats._pending_entries.Length)
			Db := _WJFM_OpenMemory()
			AssertTrue(KLR_LoadSchema(Db))
			AssertTrue(SQLite_Exec(Db, FileRead(Keystats.data_sql_path, "UTF-8")))
			Rows := SQLite_Query(Db, "SELECT id FROM events_shortcut ORDER BY id;")
			AssertEqual(Mode = "torn-drain" ? 2 : 3, Rows.Length)
			AssertEqual(10, Rows[1]["id"])
			AssertEqual(12, Rows[Rows.Length]["id"])
			return
		}
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
		if Mode = "swap-after-proof" || Mode = "same-after-proof" {
			NewEntry := Entry.Clone()
			NewEntry["_event_id"] := 11
			NewEntry["key"] := "Ctrl+V"
			ExpectedNew := KL_JsonEncode(NewEntry) . "`n"
			; Acquire the genuine owner directly: outer _JournalEnter would resume
			; the pending rotation before the I/O cutpoint can be supplied.
			Probe := Map("calls", 0)
			Replace := Mode = "swap-after-proof"
			Owner := _KL_JournalOwnerFor()
			Token := Owner.Acquire()
			AssertTrue(IsObject(Token))
			try Accepted := _KL_RolloverResume(Token, _KLRR_AfterProof.Bind(Root, NewEntry, Probe, Replace))
			finally Owner.Release(Token)
			_TestPrint("# ROLLOVER_NATIVE_RETURN " . KL_JsonEncode(Map("replacement", Replace,
				"accepted", Accepted, "path_present", FileExist(Keystats.today_log_path) != "",
				"cutpoint_calls", Probe["calls"], "pending_receipt", _KL_RolloverPending() is Map)))
			AssertEqual(1, Probe["calls"], "the exact original I/O cutpoint must run once")
			if !Replace {
				AssertTrue(Accepted, "an unchanged consumed journal still completes through the same cutpoint")
				AssertFalse(FileExist(Keystats.today_log_path))
				AssertFalse(_KL_RolloverPending())
				AssertEqual(0, Keystats.today_log_offset)
				return
			}
			AssertFalse(KLR_LedgerFileIsSame(Before, Probe["snapshot"]), "the replacement is genuinely another native file")
			AssertFalse(Accepted, "a newly published journal cannot inherit an older consumed receipt")
			AssertTrue(FileExist(Keystats.today_log_path), "the unconsumed replacement journal must survive")
			AssertEqual(ExpectedNew, FileRead(Keystats.today_log_path, "UTF-8-RAW"))
			AssertTrue(KLR_LedgerSnapshotIsSame(Probe["snapshot"], KLR_LedgerSnapshot(Keystats.today_log_path)))
			AssertEqual(Offset, Keystats.today_log_offset, "the old consumed offset cannot acknowledge the new file")
			AssertTrue(_KL_RolloverPending() is Map)
			AssertEqual(StateBefore, FileRead(Keystats.state_json_path, "UTF-8"))
			AssertTrue(FileExist(Root . "\consumed.log"), "the exact checked file moved instead of disappearing")
			AssertFalse(KL_DayRollover()["ok"], "retry must remain fenced rather than re-ingest or delete the replacement")
			AssertEqual(ExpectedNew, FileRead(Keystats.today_log_path, "UTF-8-RAW"))
			Db := _WJFM_OpenMemory()
			AssertTrue(KLR_LoadSchema(Db))
			AssertTrue(SQLite_Exec(Db, FileRead(Keystats.data_sql_path, "UTF-8")))
			Rows := SQLite_Query(Db, "SELECT id FROM events_shortcut ORDER BY id;")
			AssertEqual(1, Rows.Length, "the consumed original event must not be ingested twice")
			AssertEqual(10, Rows[1]["id"])
			return
		}
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
		AssertEqual(1, State["ngram_ctx"]["key_format"])
		AssertEqual(0, State["ngram_ctx"]["contexts"].Count)
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
for Mode in ["prepare", "delete", "final", "restore", "changed", "replaced", "malformed", "swap-after-proof", "same-after-proof", "torn-drain", "undelimited-drain", "blank-batch-drain"]
	Test("keystats: recoverable day transition " . Mode . " (rollover-state-recovery)",
		_KLRR_StateRefusal.Bind(Mode))
