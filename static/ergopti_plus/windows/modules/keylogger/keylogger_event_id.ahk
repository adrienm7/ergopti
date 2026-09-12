; modules/keylogger/keylogger_event_id.ahk

; ==============================================================================
; MODULE: Keylogger Event-ID Recovery
; DESCRIPTION:
; Resolves the next append-only keylogger event identifier from the persisted
; state and the retained tail of data.sql.
;
; FEATURES & RATIONALE:
; 1. Pure tail parser — keeps recovery behavior directly testable without
;    loading the OS-hooking keylogger entry module.
; 2. Monotonic resolver — prevents a stale state.json value from reissuing an
;    identifier that SQLite would silently discard through INSERT OR IGNORE.
; ==============================================================================

#Requires AutoHotkey v2.0+





; ====================================
; ====================================
; ======= 1/ Event-ID recovery =======
; ====================================
; ====================================

; Scans a data.sql text body for the highest event id already persisted for
; the given device-id SQL literal (e.g. "'uuid'"). Every INSERT row has the
; shape `... VALUES (<device_id_lit>, <id>, ...)`. Rows can be appended out of
; identifier order when a detached flush commits after concurrent ingest, so
; recovery must inspect every matching row. Returns 0 when no row matches.
KL_ScanMaxEventId(sql_text, device_id_lit) {
	prefix := "VALUES (" . device_id_lit . ","
	prefix_len := StrLen(prefix)
	search_pos := 1
	max_id := 0
	while (match_pos := InStr(sql_text, prefix, false, search_pos)) {
		id_pos := match_pos + prefix_len
		if RegExMatch(SubStr(sql_text, id_pos), "^\s*(\d+)", &match)
			max_id := Max(max_id, Integer(match[1]))
		search_pos := id_pos
	}
	return max_id
}

; Normalize a split decimal ID without allowing an unbounded leading-zero run.
_KL_RecoveryDecimalId(Digits) {
	Digits := LTrim(Digits, "0")
	if Digits = ""
		return 0
	Limit := String(0x7FFFFFFFFFFFFFFF)
	if StrLen(Digits) > StrLen(Limit)
			|| (StrLen(Digits) = StrLen(Limit) && StrCompare(Digits, Limit) > 0)
		throw ValueError("SQL identity exceeds the integer range")
	return Integer(Digits)
}

; Consume one recovery chunk without retaining a long SQL statement or payload.
; Carry contains only an unfinished marker, whitespace position, or numeric ID.
_KL_ScanEventIdChunk(Text, DeviceLiteral, &Carry, Final := false) {
	Prefix := "VALUES (" . DeviceLiteral . ","
	Text := Carry . Text
	Carry := ""
	Position := 1
	Maximum := 0
	while Found := InStr(Text, Prefix, false, Position) {
		Position := Found + StrLen(Prefix)
		Rest := SubStr(Text, Position)
		if RegExMatch(Rest, "^\s*(\d+)", &Id) {
			if !Final && Position + Id.Len[0] > StrLen(Text) {
				; Validate now so corrupt numeric runs cannot grow the carry forever.
				Carry := Prefix . _KL_RecoveryDecimalId(Id[1])
				return Maximum
			}
			Maximum := Max(Maximum, _KL_RecoveryDecimalId(Id[1]))
		} else if !Final && RegExMatch(Rest, "^\s*$") {
			Carry := Prefix
			return Maximum
		}
	}
	if !Final {
		Length := Min(StrLen(Text), StrLen(Prefix) - 1)
		while Length > 0 {
			if SubStr(Text, -Length) = SubStr(Prefix, 1, Length) {
				Carry := SubStr(Text, -Length)
				break
			}
			Length -= 1
		}
	}
	return Maximum
}

; Missing state cannot bound historical IDs by physical append order. Stream
; the exceptional recovery pass while excluding source writers/replacements.
KL_RecoverSqlEventId(Path, DeviceLiteral, ChunkChars := unset) {
	if !IsSet(ChunkChars)
		ChunkChars := KeylogConst.DATA_SQL_SCAN_TAIL_BYTES
	if !(ChunkChars is Integer) || ChunkChars <= 0
		throw ValueError("SQL identity recovery requires a positive chunk size")
	if !FileExist(Path)
		return 0
	Reader := FileOpen(Path, "r-wd", "UTF-8")
	try {
		Length := Reader.Length
		Maximum := 0
		Carry := ""
		loop {
			Before := Reader.Pos
			Text := Reader.Read(ChunkChars)
			if Reader.Length != Length || (Reader.Pos <= Before && Reader.Pos < Length)
				throw Error("SQL identity recovery source was not completely read")
			; Preserve later markers after native NUL holes, as the tail path does.
			Text := RegExReplace(Text, "\x00", " ")
			Final := Reader.Pos = Length
			Maximum := Max(Maximum, _KL_ScanEventIdChunk(Text, DeviceLiteral, &Carry, Final))
			if Final
				return Maximum
		}
	} finally Reader.Close()
}

; Scans the uncommitted JSONL tail for stable ids already published before a
; crash. Decoding each complete line avoids treating an `_event_id` substring
; inside captured text or nested metadata as the record's durable identity.
KL_ScanMaxJournalEventId(journal_text) {
	max_id := 0
	for line in StrSplit(journal_text, "`n", "`r") {
		if (line = "")
			continue
		entry := KL_JsonDecode(line)
		if (entry is Map && entry.Has("_event_id")
				&& entry["_event_id"] is Integer && entry["_event_id"] > 0)
			max_id := Max(max_id, entry["_event_id"])
	}
	return max_id
}

; Selects the larger of the persisted identifier and one past the highest
; identifier already stored for this device.
KL_ResolveStartId(persisted_next_id, max_id_in_sql) {
	candidate := max_id_in_sql + 1
	return (persisted_next_id > candidate) ? persisted_next_id : candidate
}

; Recovery must distinguish a missing source from an unreadable existing one.
; Preserve bounded SQL-tail reads and close the handle on every failure path.
_KL_ReadRecoveryText(Path, Offset := 0, TailBytes := 0) {
	if !FileExist(Path)
		return ""
	Fh := FileOpen(Path, "r", "UTF-8")
	try {
		Length := Fh.Length
		Position := TailBytes ? Max(Fh.Pos, Length - TailBytes) : Min(Max(Fh.Pos, Offset), Length)
		Fh.Seek(Position, 0)
		if Fh.Pos != Position
			throw Error("Cannot seek to event identity recovery boundary")
		Remaining := Length - Position
		Bytes := Buffer(Remaining + 1, 0)
		if Fh.RawRead(Bytes, Remaining) != Remaining || Fh.Pos != Length || Fh.Length != Length
			throw Error("Event identity recovery source was not completely read")
		; SQL replay already tolerates NUL holes between appended statements.
		; Replace only the scan copy's NUL bytes so StrGet cannot hide later IDs.
		Cursor := Bytes.Ptr
		End := Cursor + Remaining
		while Cursor < End {
			Hole := DllCall("msvcrt\memchr", "Ptr", Cursor, "Int", 0,
				"UPtr", End - Cursor, "CDecl Ptr")
			if !Hole
				break
			NumPut("UChar", 32, Hole)
			Cursor := Hole + 1
		}
		return Remaining ? StrGet(Bytes, Remaining, "UTF-8") : ""
	} finally {
		Fh.Close()
	}
}

; Recover through the same byte-framed JSONL reader as ingestion. A NUL in one
; malformed record must not truncate all later durable identities at startup.
_KL_RecoverJournalEventId(Path, Offset) {
	MaxId := 0
	loop {
		Read := _KL_JournalReadLines(Path, Offset, KeylogConst.INGEST_BATCH_LINES, KL_JsonDecode)
		if !Read["ok"]
			throw Error("Cannot read journal event identities")
		for Entry in Read["entries"] {
			if Entry.Has("_event_id") && Entry["_event_id"] is Integer && Entry["_event_id"] > 0
				MaxId := Max(MaxId, Entry["_event_id"])
		}
		if Read["eof"] || Read["offset"] = Offset
			return MaxId
		Offset := Read["offset"]
	}
}
