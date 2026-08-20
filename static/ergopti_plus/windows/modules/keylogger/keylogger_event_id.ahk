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
; shape `... VALUES (<device_id_lit>, <id>, ...)`, so the last literal locates
; the append-only tail. Returns 0 when no row matches.
KL_ScanMaxEventId(sql_text, device_id_lit) {
	prefix := "VALUES (" . device_id_lit . ","
	pos := InStr(sql_text, prefix, false, -1)
	if (!pos)
		return 0

	pos += StrLen(prefix)
	tail := SubStr(sql_text, pos)
	if (RegExMatch(tail, "^\s*(\d+)", &m))
		return Integer(m[1])

	return 0
}

; Selects the larger of the persisted identifier and one past the highest
; identifier already stored for this device.
KL_ResolveStartId(persisted_next_id, max_id_in_sql) {
	candidate := max_id_in_sql + 1
	return (persisted_next_id > candidate) ? persisted_next_id : candidate
}
