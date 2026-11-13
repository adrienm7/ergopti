; tests/unit/metrics/engine/journal/test_sealing.ahk

; ==============================================================================
; MODULE: Keystats Journal Sealing Tests
; DESCRIPTION:
; "Encrypt logs on disk" sealed data.sql but wrote every typing row to today.log
; in clear, so the typed text and per-key events stayed readable on disk until
; the day's rollover (audit WM-002). These cases drive the real durable handoff
; into a real file, scan its bytes, then read it back through the real reader.
; ==============================================================================

#Requires AutoHotkey v2.0

_KJS_Path() {
	return A_Temp . "\ergopti_journal_sealing_" . A_ScriptHwnd . "_" . A_TickCount . ".log"
}

_KJS_Entry() {
	return Map("_event_id", 4242, "type", "typing", "timestamp", "2026-11-06 10:00:00",
		"app", "fixture.exe", "text", "zq-sealed-marker", "rich_text", "zq-sealed-marker",
		"events", [["z", 120, Map("k", "zq-per-key")]], "mouse_clicks", 0)
}

; Runs one real handoff of Entry into a fresh journal file.
; @returns {Map} The handoff receipt plus the file's text.
_KJS_Handoff(Path, Entry) {
	SavedPending := Keystats._pending_entries
	FileObject := 0
	try {
		FileObject := FileOpen(Path, "w", "UTF-8-RAW")
		Keystats._pending_entries := [Entry]
		Result := _KL_JournalPendingEntries(Map("owner", KL_JournalOwner(), "open", (*) => FileObject))
		Result["pending"] := Keystats._pending_entries.Length
		FileObject.Close(), FileObject := 0
		Result["disk"] := FileRead(Path, "UTF-8")
		return Result
	} finally {
		Keystats._pending_entries := SavedPending
		if IsObject(FileObject)
			FileObject.Close()
	}
}

_KJS_SealedOnDisk() {
	Path := _KJS_Path()
	try {
		KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000042")
		KL_Enc_SetEnabled(true)
		Entry := _KJS_Entry()
		Result := _KJS_Handoff(Path, Entry)
		AssertTrue(Result["ok"] && Result["journaled"] = 1, "the sealed row must be journaled")
		AssertFalse(InStr(Result["disk"], "zq-sealed-marker"), "typed text must not reach today.log in clear")
		AssertFalse(InStr(Result["disk"], "zq-per-key"), "per-key events must not reach today.log in clear")
		AssertContains(Result["disk"], "ergopti-enc-v1:", "the literal fields must be envelopes")
		AssertEqual("zq-sealed-marker", Entry["text"], "the accepted RAM entry stays in clear for SQL")
		AssertFalse(Entry.Has("_sealed"), "sealing works on a clone")

		Read := _KL_ReadJournalEvents(Path, 0, 100)
		AssertTrue(Read["ok"] && Read["entries"].Length = 1, "the sealed row must read back")
		Back := Read["entries"][1]
		AssertEqual("zq-sealed-marker", Back["text"])
		AssertEqual("zq-sealed-marker", Back["rich_text"])
		AssertEqual("zq-per-key", Back["events"][1][3]["k"], "per-key events must decode back")
		AssertEqual(4242, Back["_event_id"])
		AssertFalse(Back.Has("_sealed"), "the reader returns the ordinary journal form")
	} finally {
		KL_Enc_SetEnabled(false)
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keystats journal: encryption seals typed text and events in today.log (keystats-journal-sealing)",
	_KJS_SealedOnDisk)

; Control: the byte scan above can see the marker, so its absence means sealing.
_KJS_ClearWhenDisabled() {
	Path := _KJS_Path()
	try {
		KL_Enc_SetEnabled(false)
		Result := _KJS_Handoff(Path, _KJS_Entry())
		AssertTrue(Result["ok"])
		AssertContains(Result["disk"], "zq-sealed-marker", "without encryption the journal stays plain")
		AssertFalse(InStr(Result["disk"], "_sealed"))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keystats journal: encryption off keeps the plain journal (keystats-journal-sealing)",
	_KJS_ClearWhenDisabled)

_KJS_SealFailureKeepsBatch() {
	Path := _KJS_Path()
	try {
		KL_Enc_SetMachineIdOverride("")   ; no machine id: no key can be derived
		KL_Enc_SetEnabled(true)
		Result := _KJS_Handoff(Path, _KJS_Entry())
		AssertFalse(Result["ok"], "an impossible seal refuses the handoff")
		AssertEqual(1, Result["pending"], "the refused row stays queued for retry")
		AssertFalse(InStr(Result["disk"], "zq-sealed-marker"), "a failed seal never writes the plaintext")
	} finally {
		KL_Enc_SetEnabled(false)
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keystats journal: a failed seal keeps the row in RAM, never in clear (keystats-journal-sealing)",
	_KJS_SealFailureKeepsBatch)

_KJS_UnreadableSealHoldsCheckpoint() {
	Path := _KJS_Path()
	try {
		KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000042")
		KL_Enc_SetEnabled(true)
		AssertTrue(_KJS_Handoff(Path, _KJS_Entry())["ok"])
		KL_Enc_SetMachineIdOverride("")
		Read := _KL_ReadJournalEvents(Path, 0, 100)
		AssertFalse(Read["ok"], "a sealed row that cannot be opened must not be acknowledged")
		AssertEqual(0, Read["offset"], "the checkpoint stays before the unreadable row")
	} finally {
		KL_Enc_SetEnabled(false)
		KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000042")
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keystats journal: an unopenable sealed row keeps the checkpoint (keystats-journal-sealing)",
	_KJS_UnreadableSealHoldsCheckpoint)
