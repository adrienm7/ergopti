; modules/keylogger/keylogger_journal.ahk

; ==============================================================================
; MODULE: Keylogger Durable Journal Handoff
; DESCRIPTION:
; Moves accepted in-memory events to today.log without running SQL projection.
; This lightweight boundary remains available during continuous typing.
; ==============================================================================


_KL_JournalPortFn(Port, Name, DefaultFn) {
	if !(Port is Map) or !Port.Has(Name)
		return DefaultFn
	Candidate := Port[Name]
	if !HasMethod(Candidate, "Call")
		throw TypeError("keylogger journal port '" . Name . "' must be callable")
	return Candidate
}

_KL_JournalOpenDefault(*) {
	return KL_OpenTodayFh()
}

_KL_JournalEncodeDefault(Entry) {
	return KL_JsonEncode(Entry)
}

_KL_JournalAppendDefault(Fh, Line) {
	Fh.Write(Line . "`n")
	return true
}

_KL_JournalFlushDefault(Fh) {
	return KL_FlushTodayFh(Fh)
}

_KL_JournalRestoreSnapshot(Snapshot, StartIndex := 1) {
	PreviousCritical := Critical("On")
	try {
		loop Snapshot.Length - StartIndex + 1 {
			SnapshotIndex := StartIndex + A_Index - 1
			Keylogger._pending_entries.InsertAt(A_Index, Snapshot[SnapshotIndex])
		}
	} finally {
		Critical(PreviousCritical)
	}
}

_KL_JournalEndsWithNewline(Path, Length) {
	Fh := false
	try {
		Fh := FileOpen(Path, "r")
		if !IsObject(Fh) or Length = 0
			return true
		Fh.Seek(Length - 1, 0)
		Byte := Buffer(1)
		return Fh.RawRead(Byte, 1) = 1 && NumGet(Byte, 0, "UChar") = 0x0A
	} finally {
		if IsObject(Fh)
			try Fh.Close()
	}
}

; Reads only newline-owned JSONL records. A final unterminated record may still
; be in flight, so its starting offset remains the checkpoint until a later read
; observes the delimiter. Malformed interior records are already complete and
; may be skipped without pinning the journal forever.
_KL_JournalReadLines(Path, Offset, MaxLines, DecodeFn) {
	if !HasMethod(DecodeFn, "Call")
		throw TypeError("keylogger journal decoder must be callable")
	if !FileExist(Path)
		return Map("ok", true, "offset", Offset, "entries", [], "eof", true)

	Fh := false
	try {
		Fh := FileOpen(Path, "r", "UTF-8")
		if !IsObject(Fh)
			return Map("ok", false, "offset", Offset, "entries", [], "eof", false)
		Fh.Seek(Offset, 0)
		SnapshotLength := Fh.Length
		SnapshotEndsWithNewline := _KL_JournalEndsWithNewline(Path, SnapshotLength)
		Entries := []
		Lines := 0
		Checkpoint := Offset
		IncompleteTail := false
		while (Lines < MaxLines && Fh.Pos < SnapshotLength) {
			LineStart := Fh.Pos
			Line := Fh.ReadLine()
			if (Fh.Pos >= SnapshotLength && !SnapshotEndsWithNewline) {
				Checkpoint := LineStart
				IncompleteTail := true
				break
			}
			Checkpoint := Fh.Pos
			if (Line = "")
				continue
			try {
				Entry := DecodeFn.Call(Line)
				if (Entry is Map && Entry.Has("type"))
					Entries.Push(Entry)
			}
			Lines += 1
		}
		return Map("ok", true, "offset", Checkpoint, "entries", Entries,
			"eof", Checkpoint >= SnapshotLength && !IncompleteTail)
	} catch as Err {
		try LoggerError("Keylogger", "Cannot read today.log for ingest: {1}.",
			Err.Message)
		return Map("ok", false, "offset", Offset, "entries", [], "eof", false)
	} finally {
		if IsObject(Fh)
			try Fh.Close()
	}
}

; Proves the current typing buffer and pending queue are durable while OnExit is
; still reversible. A detached flush keeps its only snapshot in the interrupted
; thread, so its latch must be checked before attempting this handoff. Any I/O
; failure restores the queue and refuses shutdown before producers are stopped.
KL_FlushShutdownReady(Port := 0, FlushBufferFn := KL_FlushBuffer) {
	PreviousCritical := Critical("On")
	try {
		if Keylogger._flush_in_progress
			return false
	} finally {
		Critical(PreviousCritical)
	}
	FlushComplete := false
	try FlushComplete := FlushBufferFn.Call() = true
	if !FlushComplete
		return false
	JournalResult := _KL_JournalPendingEntries(Port)
	return JournalResult["ok"] = true
}

; Publishes the current RAM queue to the append-only JSONL journal. A true
; result proves every detached entry crossed the OS-visible flush boundary.
; Failed or unflushed entries are restored ahead of entries accepted while the
; handoff was running, preserving event order without holding Critical over I/O.
_KL_JournalPendingEntries(Port := 0) {
	OpenFn := _KL_JournalPortFn(Port, "open", _KL_JournalOpenDefault)
	EncodeFn := _KL_JournalPortFn(Port, "encode", _KL_JournalEncodeDefault)
	AppendFn := _KL_JournalPortFn(Port, "append", _KL_JournalAppendDefault)
	FlushFn := _KL_JournalPortFn(Port, "flush", _KL_JournalFlushDefault)
	PreviousCritical := Critical("On")
	try {
		Snapshot := Keylogger._pending_entries
		Keylogger._pending_entries := []
	} finally {
		Critical(PreviousCritical)
	}
	if (Snapshot.Length = 0)
		return Map("ok", true, "journaled", 0)

	try Fh := OpenFn.Call()
	catch as Err {
		_KL_JournalRestoreSnapshot(Snapshot)
		try LoggerError("Keylogger", "Cannot open today.log for durable handoff: {1}.",
			Err.Message)
		return Map("ok", false, "journaled", 0, "reason", "open_failed")
	}

	Journaled := 0
	try {
		for Entry in Snapshot {
			Line := StrReplace(EncodeFn.Call(Entry), "`n", "\n")
			Line := StrReplace(Line, "`r", "")
			if !AppendFn.Call(Fh, Line)
				throw Error("journal append port rejected the line")
			Journaled += 1
		}
	} catch as Err {
		PrefixFlushed := false
		try PrefixFlushed := FlushFn.Call(Fh) = true
		_KL_JournalRestoreSnapshot(Snapshot,
			PrefixFlushed ? Journaled + 1 : 1)
		try LoggerError("Keylogger",
			"Cannot append pending keylogger event to today.log: {1}.", Err.Message)
		return Map("ok", false,
			"journaled", PrefixFlushed ? Journaled : 0,
			"reason", "append_failed")
	}

	Flushed := false
	try Flushed := FlushFn.Call(Fh) = true
	if !Flushed {
		_KL_JournalRestoreSnapshot(Snapshot)
		try LoggerError("Keylogger",
			"today.log durable handoff could not prove its flush; batch retained in RAM.")
		return Map("ok", false, "journaled", 0, "reason", "flush_failed")
	}
	return Map("ok", true, "journaled", Journaled)
}
