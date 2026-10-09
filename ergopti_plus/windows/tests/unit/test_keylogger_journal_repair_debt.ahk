; tests/unit/test_keylogger_journal_repair_debt.ahk

; ==============================================================================
; MODULE: Keylogger Journal Repair Debt Tests
; DESCRIPTION:
; A refused compensation pins the original file and prevents another batch from
; appending until repair succeeds, while newly accepted events retain their order.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk

_KJRD_Open(State) {
	State["opens"] += 1
	return State["file"]
}

_KJRD_Append(State, FileObject, Line) {
	State["appends"] += 1
	return _FSWriteUtf8Bytes(FileObject, Line . "`n")
}

_KJRD_Repair(State, FileObject, Boundary) {
	State["repairs"] += 1
	if FileObject != State["file"]
		throw Error("repair changed file identity")
	if !State["repair_allowed"]
		return false
	return _KL_JournalRollbackAppend(FileObject, Boundary, FSFlushFileBuffers)
}

_KJRD_RetryAfterRepair() {
	SavedPending := Keylogger._pending_entries
	Path := _FSWL_Path()
	FileObject := 0
	try {
		FileAppend("prior`n", Path, "UTF-8")
		FileObject := FileOpen(Path, "a", "UTF-8-RAW")
		Owner := KL_JournalOwner()
		State := Map("file", FileObject, "opens", 0, "appends", 0,
			"repairs", 0, "repair_allowed", false, "flush_allowed", false)
		Port := Map("owner", Owner, "open", _KJRD_Open.Bind(State),
			"encode", (Entry) => '{"id":' . Entry["id"] . '}',
			"append", _KJRD_Append.Bind(State),
			"flush", (Fh) => State["flush_allowed"] && FSFlushFileBuffers(Fh),
			"rollback", _KJRD_Repair.Bind(State))
		First := Map("id", 901)
		Second := Map("id", 902)
		Third := Map("id", 903)
		Keylogger._pending_entries := [First, Second]
		Initial := _KL_JournalPendingEntries(Port)
		AssertEqual("journal_repair_pending", Initial["reason"])
		AssertTrue(Owner.HasDebt())
		Keylogger._pending_entries.Push(Third)
		Queue := Keylogger._pending_entries
		Before := FileRead(Path, "UTF-8")
		Blocked := _KL_JournalPendingEntries(Port)
		AssertFalse(Blocked["ok"])
		AssertEqual("journal_repair_pending", Blocked["reason"])
		AssertTrue(Keylogger._pending_entries = Queue, "blocked repair must not detach the queue again")
		AssertEqual(3, Queue.Length)
		AssertTrue(Queue[1] = First && Queue[2] = Second && Queue[3] = Third)
		AssertEqual(1, State["opens"])
		AssertEqual(2, State["appends"], "no append may overtake an unresolved rollback")
		AssertEqual(Before, FileRead(Path, "UTF-8"))
		State["repair_allowed"] := true
		State["flush_allowed"] := true
		Retry := _KL_JournalPendingEntries(Port)
		AssertTrue(Retry["ok"])
		AssertEqual(3, Retry["journaled"])
		AssertFalse(Owner.HasDebt())
		AssertEqual(0, Keylogger._pending_entries.Length)
		AssertEqual(3, State["repairs"])
		AssertEqual("prior`n" . '{"id":901}' . "`n" . '{"id":902}' . "`n" . '{"id":903}' . "`n",
			FileRead(Path, "UTF-8"))
	} finally {
		Keylogger._pending_entries := SavedPending
		if IsObject(FileObject)
			FileObject.Close()
		if FileExist(Path)
			FileDelete(Path)
	}
}

Test("keylogger: refused journal repair blocks new batches until recovery (keylogger-journal-repair-debt)", _KJRD_RetryAfterRepair)
