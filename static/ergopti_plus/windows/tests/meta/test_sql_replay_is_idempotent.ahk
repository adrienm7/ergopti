; tests/meta/test_sql_replay_is_idempotent.ahk

; ==============================================================================
; MODULE: SQL Replay Idempotence Meta Test
; DESCRIPTION:
; When KL_SaveState fails, KL_IngestOnce rolls today_log_offset back even though
; the batch has already been appended to data.sql — so the next tick re-reads the
; same JSONL range and appends the same INSERT block again.
;
; That re-append is SAFE, but only because of an invariant held somewhere else
; entirely: every statement is INSERT OR IGNORE against a (device_id, id)
; primary key, so a duplicated block is discarded at import. The consequence
; today is redundant text in an append-only file, not corrupted data.
;
; This test exists because that reasoning is the ONLY thing standing between the
; current behaviour and real duplicate rows. The offset rollback was deliberately
; left in place — reordering the write to commit state before data.sql would
; trade this benign redundancy for a genuine crash window, where a batch is
; marked durable before it is — so the guarantee that makes it benign has to be
; pinned instead of assumed.
;
; Change any INSERT to a plain INSERT and this stops being a cosmetic issue.
;
; SCOPE: source introspection of modules/keylogger via the move-resilient helper.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ Every INSERT tolerates a replay =======
; ==================================================
; ==================================================

_SRII_EveryInsertIsIgnoreOnConflict() {
	; Comment-stripped AND case-sensitive, both deliberately. AHK's InStr is
	; case-INSENSITIVE by default, and a prose comment in keylogger_sensors.ahk
	; reads "routes it into events_system", which a naive scan counts as a bare
	; INSERT and fails against perfectly correct code — the comment-mention trap.
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")

	; Scoped to the EVENT tables specifically. The walker's agg_*/ngram_* writers
	; are a different mechanism — plain INSERT with ON CONFLICT ... DO UPDATE,
	; i.e. deliberate upserts — and they are not on the ingest re-append path, so
	; requiring OR IGNORE of them would assert something false.
	Good := 0
	Pos := 1
	while (Pos := InStr(Src, "INSERT OR IGNORE INTO events_", true, Pos)) {
		Good += 1
		Pos += 29
	}
	Bare := 0
	Pos := 1
	while (Pos := InStr(Src, "INSERT INTO events_", true, Pos)) {
		Bare += 1
		Pos += 19
	}

	Assert(Good >= 6,
		"expected several INSERT OR IGNORE statements against events_* tables (found " . Good . ") — if this collapsed, the scan is looking at the wrong source and the guard is vacuous")
	Assert(Bare == 0,
		"every keylogger INSERT must be INSERT OR IGNORE (found " . Bare . " that are not). A failed state save rolls today_log_offset back after the batch already reached data.sql, so the same block IS re-appended on the next tick; OR IGNORE against the (device_id, id) primary key is the only reason that is harmless rather than duplicate rows")
}

; The primary key is the other half of the guarantee: OR IGNORE only deduplicates
; if something makes the row a conflict.
_SRII_ReplayContractIsDocumented() {
	Src := _DriverDirConcat("modules/keylogger")
	Assert(InStr(Src, "PRIMARY KEY (device_id, id)") > 0,
		"the (device_id, id) primary key must remain documented in the keylogger module — INSERT OR IGNORE deduplicates a replayed batch only because that key makes the repeat a conflict")
}

_SRII_AppendAssignsIdentityBeforeQueuePublication() {
	Body := _DriverFuncBody("KL_AppendLog")
	AssignAt := InStr(Body, "KL_AssignStableEventId(entry)")
	PublishAt := InStr(Body, "Keylogger._pending_entries.Push(entry)")
	Assert(AssignAt > 0 and PublishAt > AssignAt,
		"KL_AppendLog must serialize one stable event id before the entry can reach today.log")
}


Test("meta keylogger: every INSERT tolerates a replayed batch",
	_SRII_EveryInsertIsIgnoreOnConflict)
Test("meta keylogger: the replay contract's primary key is documented",
	_SRII_ReplayContractIsDocumented)
Test("meta keylogger: journal identity precedes queue publication (journal-stable-event-id)",
	_SRII_AppendAssignsIdentityBeforeQueuePublication)
