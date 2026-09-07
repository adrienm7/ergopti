; tests/unit/test_keylogger_journal_flush_retry.ahk

; ==============================================================================
; MODULE: Keylogger Journal Flush Retry Tests
; DESCRIPTION:
; A refused durable fence must not let a later handoff append the same accepted
; JSONL records again. The sink is a real persistent native file, not a line list.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk

_KJFR_Append(State, FileObject, Line) {
	State["appends"] += 1
	if State["reject_second"] && State["appends"] = 2
		return false
	return _FSWriteUtf8Bytes(FileObject, Line . "`n")
}

_KJFR_Flush(State, FileObject) {
	State["flushes"] += 1
	if State["refuse_flush"] && State["flushes"] = 1
		return false
	return FSFlushFileBuffers(FileObject)
}

_KJFR_Retry(RefuseFlush, RejectSecond) {
	SavedPending := Keylogger._pending_entries
	Path := _FSWL_Path()
	FileObject := 0
	First := Map("id", 901)
	Second := Map("id", 902)
	State := Map("appends", 0, "flushes", 0,
		"refuse_flush", RefuseFlush, "reject_second", RejectSecond)
	try {
		FileAppend("prior`n", Path, "UTF-8")
		FileObject := FileOpen(Path, "a", "UTF-8-RAW")
		Keylogger._pending_entries := [First, Second]
		Port := Map("owner", KL_JournalOwner(), "open", (*) => FileObject,
			"encode", (Entry) => '{"id":' . Entry["id"] . '}',
			"append", _KJFR_Append.Bind(State), "flush", _KJFR_Flush.Bind(State))
		Initial := _KL_JournalPendingEntries(Port)
		AssertEqual(!(RefuseFlush || RejectSecond), Initial["ok"])
		AssertEqual(RefuseFlush || RejectSecond ? 0 : 2, Initial["journaled"],
			"a failed atomic handoff retracts its whole batch")
		Retry := _KL_JournalPendingEntries(Port)
		AssertTrue(Retry["ok"], "a successful successor fence must finish the handoff")
		AssertEqual(0, Keylogger._pending_entries.Length)
		AssertEqual("prior`n" . '{"id":901}' . "`n" . '{"id":902}' . "`n",
			FileRead(Path, "UTF-8"), "retry must preserve each real JSONL record exactly once")
	} finally {
		Keylogger._pending_entries := SavedPending
		if IsObject(FileObject)
			FileObject.Close()
		if FileExist(Path)
			FileDelete(Path)
	}
}

for RefuseFlush in [false, true] {
	for RejectSecond in [false, true]
		Test("keylogger: real journal retry flush=" . RefuseFlush . " append=" . RejectSecond
			. " (keylogger-journal-flush-retry)", _KJFR_Retry.Bind(RefuseFlush, RejectSecond))
}
