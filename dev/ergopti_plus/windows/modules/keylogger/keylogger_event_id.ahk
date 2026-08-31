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
