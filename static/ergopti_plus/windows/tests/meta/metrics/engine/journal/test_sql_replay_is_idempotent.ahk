; tests/meta/metrics/engine/journal/test_sql_replay_is_idempotent.ahk

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
; SCOPE: source introspection of metrics/engine via the move-resilient helper.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ Every INSERT tolerates a replay =======
; ==================================================
; ==================================================

; Case-sensitive occurrences of a pattern.
_SRII_Count(Src, Pattern) {
	Count := 0
	Pos := 1
	while (Found := RegExMatch(Src, Pattern, &Match, Pos)) {
		Count += 1
		Pos := Found + Match.Len
	}
	return Count
}

_SRII_EveryInsertIsIgnoreOnConflict() {
	; Comment-stripped AND case-sensitive, both deliberately. AHK's InStr is
	; case-INSENSITIVE by default, and a prose comment in keystats_sensors.ahk
	; reads "routes it into events_system", which a naive scan counts as a bare
	; INSERT and fails against perfectly correct code — the comment-mention trap.
	global _DriverDir
	; The rendered catalogue statements (_shared/metrics/data/db/queries.sql) are
	; generated, so the authored-source census leaves them out; they are half of
	; the event writers and are read here explicitly.
	Src := _DriverSourceNoComments() . "`n"
		. _StripFullLineComments(FSReadStrict(_DriverDir . "\_generated\keystats_queries.ahk"))
	Assert(Src != "", "the driver source must be readable")

	; Scoped to the EVENT tables specifically. The walker's agg_*/ngram_* writers
	; are a different mechanism — plain INSERT with ON CONFLICT ... DO UPDATE,
	; i.e. deliberate upserts — and they are not on the ingest re-append path, so
	; requiring OR IGNORE of them would assert something false. A shared builder
	; (KL_BuildInsertKindRow) names its events_* table through a Format
	; placeholder, so "INTO {1}" counts as an event INSERT too.
	Good := _SRII_Count(Src, "INSERT OR IGNORE INTO (?:events_|\{\d+\})")
	Bare := _SRII_Count(Src, "INSERT INTO (?:events_|\{\d+\})")

	Assert(Good >= 6,
		"expected several INSERT OR IGNORE statements against events_* tables (found " . Good . ") — if this collapsed, the scan is looking at the wrong source and the guard is vacuous")
	Assert(Bare == 0,
		"every keystats INSERT must be INSERT OR IGNORE (found " . Bare . " that are not). A failed state save rolls today_log_offset back after the batch already reached data.sql, so the same block IS re-appended on the next tick; OR IGNORE against the (device_id, id) primary key is the only reason that is harmless rather than duplicate rows")
}

; The patterns read a shared builder's templated table as an event INSERT, so
; dropping its OR IGNORE is caught as surely as on a literal events_* table.
_SRII_TemplatedTableIsAnEventInsert() {
	AssertEqual(1, _SRII_Count('Format("INSERT INTO {1} (device_id, id) VALUES ({2}, {3});"', "INSERT INTO (?:events_|\{\d+\})"))
	AssertEqual(1, _SRII_Count('Format("INSERT OR IGNORE INTO {1} (device_id, id)"', "INSERT OR IGNORE INTO (?:events_|\{\d+\})"))
	AssertEqual(0, _SRII_Count('"INSERT INTO agg_app_day (device_id) "', "INSERT INTO (?:events_|\{\d+\})"),
		"an aggregate upsert is not on the replay path")
}

; The primary key is the other half of the guarantee: OR IGNORE only deduplicates
; if something makes the row a conflict.
_SRII_ReplayContractIsDocumented() {
	Src := _DriverDirConcat("metrics/engine")
	Assert(InStr(Src, "PRIMARY KEY (device_id, id)") > 0,
		"the (device_id, id) primary key must remain documented in the keystats module — INSERT OR IGNORE deduplicates a replayed batch only because that key makes the repeat a conflict")
}

_SRII_AppendAssignsIdentityBeforeQueuePublication() {
	Body := _DriverFuncBody("KL_AppendLog")
	AssignAt := InStr(Body, "KL_AssignStableEventId(entry)")
	PublishAt := InStr(Body, "Keystats._pending_entries.Push(entry)")
	Assert(AssignAt > 0 and PublishAt > AssignAt,
		"KL_AppendLog must serialize one stable event id before the entry can reach today.log")
}


Test("meta keystats: every INSERT tolerates a replayed batch",
	_SRII_EveryInsertIsIgnoreOnConflict)
Test("meta keystats: a templated event table counts as an event INSERT",
	_SRII_TemplatedTableIsAnEventInsert)
Test("meta keystats: the replay contract's primary key is documented",
	_SRII_ReplayContractIsDocumented)
Test("meta keystats: journal identity precedes queue publication (journal-stable-event-id)",
	_SRII_AppendAssignsIdentityBeforeQueuePublication)
