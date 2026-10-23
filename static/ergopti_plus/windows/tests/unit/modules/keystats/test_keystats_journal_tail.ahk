; tests/unit/modules/keystats/test_keystats_journal_tail.ahk

; ==============================================================================
; MODULE: Journal Append Boundary Tests
; DESCRIPTION: Refuse incomplete disk tails before transferring pending ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

_KJT_AppendAdmission(Text, Encoding, Valid) {
	Names := ["today_log_path", "_today_fh", "_today_fh_date", "_pending_entries"]
	Saved := Map()
	for Name in Names
		if Keystats.HasOwnProp(Name)
			Saved[Name] := Keystats.%Name%
	Path := _FSWL_Path()
	Entry := Map("type", "typing", "_event_id", 77, "text", "synthetic")
	OwnsJournal := false
	try {
		FileAppend(Text, Path, Encoding)
		Before := FileRead(Path, "RAW")
		Keystats.today_log_path := Path
		Keystats._today_fh := unset
		Keystats._today_fh_date := ""
		Keystats._pending_entries := [Entry]
		OwnsJournal := true
		Result := _KL_JournalPendingEntries()
		if Valid {
			AssertTrue(Result["ok"])
			AssertEqual(1, Result["journaled"])
			AssertEqual(0, Keystats._pending_entries.Length)
			Read := _KL_JournalReadLines(Path, Before.Size, 10, KL_JsonDecode)
			AssertTrue(Read["ok"])
			AssertEqual(1, Read["entries"].Length)
			AssertEqual(77, Read["entries"][1]["_event_id"])
		} else {
			AssertFalse(Result["ok"], "a torn tail must not absorb the next accepted event")
			AssertEqual(0, Result["journaled"])
			AssertEqual(1, Keystats._pending_entries.Length)
			AssertTrue(Keystats._pending_entries[1] == Entry, "refusal must restore the exact RAM entry")
			AssertFalse(Keystats.HasOwnProp("_today_fh"), "an invalid append handle must not escape")
			After := FileRead(Path, "RAW")
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory",
				"Ptr", Before, "Ptr", After, "UPtr", Before.Size, "UPtr"))
		}
	} finally {
		if OwnsJournal && Keystats.HasOwnProp("_today_fh") && IsObject(Keystats._today_fh)
			Keystats._today_fh.Close()
		for Name in Names {
			if Saved.Has(Name)
				Keystats.%Name% := Saved[Name]
			else if Keystats.HasOwnProp(Name)
				Keystats.DeleteProp(Name)
		}
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Encoding in ["UTF-8", "UTF-8-RAW"] {
	Test("journal: torn tail refuses new handoff " . Encoding . " (journal-append-boundary)",
		_KJT_AppendAdmission.Bind('{"type":"typing","text":"partial', Encoding, false))
	Test("journal: missing delimiter refuses new handoff " . Encoding . " (journal-append-boundary)",
		_KJT_AppendAdmission.Bind('{"type":"typing"}', Encoding, false))
	Test("journal: initial empty text admits handoff " . Encoding . " (journal-append-boundary)",
		_KJT_AppendAdmission.Bind("", Encoding, true))
	Test("journal: complete line admits handoff " . Encoding . " (journal-append-boundary)",
		_KJT_AppendAdmission.Bind('{"type":"typing"}' . "`n", Encoding, true))
}
