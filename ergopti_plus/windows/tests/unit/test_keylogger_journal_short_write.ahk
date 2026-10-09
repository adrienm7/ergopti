; tests/unit/test_keylogger_journal_short_write.ahk

; ==============================================================================
; MODULE: Keylogger Journal Short Native Write Tests
; DESCRIPTION:
; Real one- and two-byte writes exercise partial BOM and payload compensation.
; Queue ownership returns only with the original file boundary restored.
; ==============================================================================

#Requires AutoHotkey v2.0

_KJSW_Write(State, Handle, Bytes, ByteCount, &Written) {
	Limit := State["short"] ? State["prefix_bytes"] : ByteCount
	Accepted := _FSNativeWrite(Handle, Bytes, Limit, &Written)
	State["receipts"].Push(Written)
	return Accepted
}

_KJSW_Append(State, Fh, Line) {
	return _KL_JournalAppendDefault(Fh, Line, _KJSW_Write.Bind(State))
}

_KJSW_Retry(Existing, PrefixBytes) {
	SavedPending := Keylogger._pending_entries
	Path := _FSWL_Path()
	Fh := 0
	Prefix := Existing ? "prior`n" : ""
	try {
		if Existing
			FileAppend(Prefix, Path, "UTF-8")
		Fh := FileOpen(Path, "a", "UTF-8-RAW")
		Boundary := Fh.Pos
		State := Map("short", true, "prefix_bytes", PrefixBytes, "receipts", [])
		Owner := KL_JournalOwner()
		Port := Map("owner", Owner, "open", (*) => Fh,
			"encode", (Entry) => '{"id":' . Entry["id"] . '}',
			"append", _KJSW_Append.Bind(State), "flush", FSFlushFileBuffers)
		First := Map("id", 801)
		Second := Map("id", 802)
		Keylogger._pending_entries := [First, Second]
		Failed := _KL_JournalPendingEntries(Port)
		AssertFalse(Failed["ok"])
		AssertEqual("append_failed", Failed["reason"])
		AssertEqual(0, Failed["journaled"])
		AssertEqual(1, State["receipts"].Length, "failure must occur at the actual native write")
		AssertEqual(PrefixBytes, State["receipts"][1])
		AssertEqual(Boundary, FileGetSize(Path), "rollback must remove a partial new-file BOM too")
		AssertEqual(Prefix, FileRead(Path, "UTF-8"))
		AssertFalse(Owner.HasDebt())
		AssertEqual(2, Keylogger._pending_entries.Length)
		AssertTrue(Keylogger._pending_entries[1] = First && Keylogger._pending_entries[2] = Second)
		State["short"] := false
		Retry := _KL_JournalPendingEntries(Port)
		AssertTrue(Retry["ok"])
		AssertEqual(2, Retry["journaled"])
		AssertEqual(3, State["receipts"].Length)
		AssertEqual(0, Keylogger._pending_entries.Length)
		Expected := Prefix . '{"id":801}' . "`n" . '{"id":802}' . "`n"
		AssertEqual(Expected, FileRead(Path, "UTF-8"))
		AssertEqual(StrPut(Expected, "UTF-8") + 2, FileGetSize(Path))
	} finally {
		Keylogger._pending_entries := SavedPending
		if IsObject(Fh)
			Fh.Close()
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Existing in [false, true] {
	for PrefixBytes in [1, 2]
		Test("keylogger: short native journal write existing=" . Existing . " bytes=" . PrefixBytes
			. " (keylogger-journal-short-write AHK-076)", _KJSW_Retry.Bind(Existing, PrefixBytes))
}
