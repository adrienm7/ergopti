; modules/keylogger/keylogger_journal.ahk

; ==============================================================================
; MODULE: Keylogger Durable Journal Handoff
; DESCRIPTION:
; Moves accepted in-memory events to today.log without running SQL projection.
; This lightweight boundary remains available during continuous typing.
; ==============================================================================

#Include keylogger_journal_owner.ahk
#Include keylogger_sql_append.ahk

_KL_JournalOwnerFor(Port := 0) {
	static SharedOwner := KL_JournalOwner()
	if !(Port is Map) || !Port.Has("owner")
		return SharedOwner
	if !(Port["owner"] is KL_JournalOwner)
		throw TypeError("Journal owner must be a KL_JournalOwner instance.")
	return Port["owner"]
}

; Nested lifecycle operations borrow the same authority without releasing their
; caller's lease. Every admitted operation runs outside the caller's Critical.
_KL_JournalEnter(Token := 0, Port := 0) {
	if !IsObject(Token) && (Type(Token) != "Integer" || Token != 0)
		throw TypeError("Journal token must be an active owner token or integer zero.")
	Owner := _KL_JournalOwnerFor(Port)
	Acquired := !IsObject(Token)
	if Acquired {
		Token := Owner.Acquire()
		if !IsObject(Token)
			return 0
	} else {
		Owner.Require(Token)
		if Owner.HasDebt()
			return 0
	}
	return {Owner: Owner, Token: Token, Acquired: Acquired,
		PreviousCritical: Critical("Off")}
}

_KL_JournalLeave(Scope) {
	try {
		if Scope.Acquired
			Scope.Owner.Release(Scope.Token)
	} finally {
		Critical(Scope.PreviousCritical)
	}
}

_KL_JournalPortFn(Port, Name, DefaultFn) {
	if !(Port is Map) or !Port.Has(Name)
		return DefaultFn
	Candidate := Port[Name]
	if !HasMethod(Candidate, "Call")
		throw TypeError("keylogger journal port '" . Name . "' must be callable")
	return Candidate
}

_KL_JournalOpenDefault(Token, *) {
	return KL_OpenTodayFh(Token)
}

_KL_JournalEncodeDefault(Entry) {
	return KL_JsonEncode(Entry)
}

_KL_JournalRollbackAppend(Fh, Boundary, FlushFn := 0) {
	if !IsObject(Fh) || !IsInteger(Boundary) || Boundary < 0
		return false
	try {
		ResolvedFlush := HasMethod(FlushFn, "Call") ? FlushFn : KL_FlushTodayFh
		Handle := Fh.Handle
		NewPosition := 0
		if !DllCall("kernel32\SetFilePointerEx", "Ptr", Handle,
			"Int64", Boundary, "Int64*", &NewPosition, "UInt", 0, "Int")
			return false
		if (NewPosition != Boundary)
			return false
		if !DllCall("kernel32\SetEndOfFile", "Ptr", Handle, "Int")
			return false
		return ResolvedFlush.Call(Fh) == true
	} catch {
		return false
	}
}

_KL_JournalAppendDefault(Fh, Line, WriteFn := 0) {
	Boundary := Fh.Pos
	; The batch owner compensates any native prefix, including a new-file BOM.
	; AHK's text buffer cannot provide evidence that Windows accepted the bytes.
	Payload := (Boundary = 0 ? Chr(0xFEFF) : "") . Line . "`n"
	return _FSWriteUtf8Bytes(Fh, Payload, WriteFn)
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
	Fh := false
	try {
		if !FileExist(Path) {
			if Offset != 0
				throw ValueError("Journal checkpoint exceeds missing journal")
			return Map("ok", true, "offset", Offset, "entries", [], "eof", true)
		}
		Fh := FileOpen(Path, "r", "UTF-8")
		if !IsObject(Fh)
			return Map("ok", false, "offset", Offset, "entries", [], "eof", false)
		SnapshotLength := Fh.Length
		; EOF authorizes rollover cleanup. A stale checkpoint cannot prove that
		; the remaining journal was consumed, and resetting it would replay rows.
		if Offset > SnapshotLength
			throw ValueError("Journal checkpoint exceeds journal length")
		; FileOpen already consumed an optional UTF-8 BOM. Seeking back to zero
		; exposes it to the JSON decoder and silently discards the first record.
		Fh.Seek(Offset = 0 ? Fh.Pos : Offset, 0)
		SnapshotEndsWithNewline := _KL_JournalEndsWithNewline(Path, SnapshotLength)
		Entries := []
		Lines := 0
		Checkpoint := Fh.Pos
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
	if !KL_DataSqlShutdownReady()
		return false
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
_KL_JournalPendingEntries(Port := 0, Token := 0) {
	Scope := _KL_JournalEnter(Token, Port)
	if !IsObject(Scope)
		return Map("ok", false, "journaled", 0,
			"reason", _KL_JournalOwnerFor(Port).HasDebt() ? "journal_repair_pending" : "journal_busy")
	try return _KL_JournalPendingEntriesOwned(Port, Scope.Owner, Scope.Token)
	finally _KL_JournalLeave(Scope)
}

_KL_JournalPendingEntriesOwned(Port, Owner, Token) {
	OpenFn := _KL_JournalPortFn(Port, "open", _KL_JournalOpenDefault.Bind(Token))
	EncodeFn := _KL_JournalPortFn(Port, "encode", _KL_JournalEncodeDefault)
	AppendFn := _KL_JournalPortFn(Port, "append", _KL_JournalAppendDefault)
	FlushFn := _KL_JournalPortFn(Port, "flush", _KL_JournalFlushDefault)
	PositionFn := _KL_JournalPortFn(Port, "position", (Fh) => Fh.Pos)
	RollbackFn := _KL_JournalPortFn(Port, "rollback",
		(Fh, Boundary) => _KL_JournalRollbackAppend(Fh, Boundary, FlushFn))
	PreviousCritical := Critical("On")
	try {
		Snapshot := Keylogger._pending_entries
		Keylogger._pending_entries := []
	} finally {
		Critical(PreviousCritical)
	}
	if (Snapshot.Length = 0)
		return Map("ok", true, "journaled", 0)

	try {
		Fh := OpenFn.Call()
		BatchStart := PositionFn.Call(Fh)
		if Type(BatchStart) != "Integer" || BatchStart < 0
			throw ValueError("Journal position must be a nonnegative byte boundary.")
	}
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
		Repaired := Owner.Rollback(Token, Fh, BatchStart, RollbackFn)
		_KL_JournalRestoreSnapshot(Snapshot)
		try LoggerError("Keylogger",
			"Journal append failed; batch retained (rollback={1}, error_type={2}, accepted_lines={3}, queued_lines={4}, native_code={5}).",
			Repaired, Type(Err), Journaled, Snapshot.Length, Err is OSError ? Err.Number : 0)
		return Map("ok", false, "journaled", 0,
			"reason", Repaired ? "append_failed" : "journal_repair_pending")
	}

	Flushed := false
	try Flushed := FlushFn.Call(Fh) = true
	if !Flushed {
		Repaired := Owner.Rollback(Token, Fh, BatchStart, RollbackFn)
		_KL_JournalRestoreSnapshot(Snapshot)
		try LoggerError("Keylogger",
			"Journal flush failed; batch retained (rollback={1}, queued_lines={2}).",
			Repaired, Snapshot.Length)
		return Map("ok", false, "journaled", 0,
			"reason", Repaired ? "flush_failed" : "journal_repair_pending")
	}
	return Map("ok", true, "journaled", Journaled)
}
