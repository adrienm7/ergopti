; static/ergopti_plus/windows/tests/unit/test_keylogger_sql.ahk

; ==============================================================================
; MODULE: Keylogger SQL Builder Tests
; DESCRIPTION:
; Unit tests for KL_BuildInserts (modules/keylogger/keylogger_sql.ahk) — the
; typed dispatch that turns a decoded today.log entry into 0+ INSERT
; statements. Covers event families that used to fall through to "Unknown
; type — silently skip" and were destroyed at day rollover (F19, F21).
; ==============================================================================





; ============================================
; ============================================
; ======= 1/ llm_* -> events_llm (F19) =======
; ============================================
; ============================================

_KLSql_LlmGeneration_BuildsRealInsert() {
	Keylogger.next_event_id := 1
	entry := Map(
		"type", "llm_generation",
		"timestamp", "2026-07-02 10:00:00.000",
		"app", "TestApp",
		"context", "hello wor",
		"predictions", ["ld", "rld!"]
	)
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "llm_generation must produce exactly one INSERT row")
	AssertContains(rows[1], "INSERT OR IGNORE INTO events_llm", "llm_generation must insert into events_llm, not silently skip")
	AssertContains(rows[1], "'generation'", "llm_generation must map to kind='generation'")
}
Test("KL_BuildInserts: llm_generation reaches events_llm instead of being silently skipped (F19)", _KLSql_LlmGeneration_BuildsRealInsert)

_KLSql_LlmGeneration_PersistsUsageAccounting() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the real SQLite DLL must stay loaded for the accounting fixture lifetime")
	Keylogger.next_event_id := 1
	entry := Map(
		"type", "llm_generation", "timestamp", "2026-08-20 10:00:00.000",
		"prompt_tokens", 111, "completion_tokens", 222,
		"total_tokens", 333, "est_cost_usd", 4.56789)
	Sql := KL_BuildInserts(entry)[1]
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the accounting regression must open the real SQLite adapter")
	try {
		AssertTrue(KLR_LoadSchema(db),
			"the accounting regression must execute against the canonical production schema")
		AssertTrue(SQLite_Exec(db, Sql),
			"the production LLM INSERT must be accepted by the canonical schema")
		Rows := SQLite_Query(db,
			"SELECT prompt_tokens, completion_tokens, total_tokens, est_cost_usd "
			. "FROM events_llm WHERE device_id=" . Keylogger._device_id_lit . " AND id=1;")
		AssertEqual(1, Rows.Length,
			"durable ingestion must publish exactly one accounting row")
		AssertEqual(111, Rows[1]["prompt_tokens"], "prompt tokens must survive SQLite ingestion")
		AssertEqual(222, Rows[1]["completion_tokens"], "completion tokens must survive SQLite ingestion")
		AssertEqual(333, Rows[1]["total_tokens"], "total tokens must survive SQLite ingestion")
		AssertEqual(4.56789, Rows[1]["est_cost_usd"], "estimated cost must survive SQLite ingestion")
	} finally {
		SQLite_Close(db)
	}
}
Test("KL_BuildInserts: LLM usage and cost survive durable ingestion", _KLSql_LlmGeneration_PersistsUsageAccounting)

_KLSql_LlmSuggested_BuildsRealInsert() {
	Keylogger.next_event_id := 1
	entry := Map("type", "llm_suggested", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "count", 3)
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "llm_suggested must produce exactly one INSERT row")
	AssertContains(rows[1], "INSERT OR IGNORE INTO events_llm", "llm_suggested must insert into events_llm, not silently skip")
	AssertContains(rows[1], "'suggested'", "llm_suggested must map to kind='suggested'")
}
Test("KL_BuildInserts: llm_suggested reaches events_llm instead of being silently skipped (F19)", _KLSql_LlmSuggested_BuildsRealInsert)

_KLSql_LlmDismissed_BuildsRealInsert() {
	Keylogger.next_event_id := 1
	entry := Map("type", "llm_dismissed", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "all_predictions", ["a", "b"])
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "llm_dismissed must produce exactly one INSERT row")
	AssertContains(rows[1], "INSERT OR IGNORE INTO events_llm", "llm_dismissed must insert into events_llm, not silently skip")
}
Test("KL_BuildInserts: llm_dismissed reaches events_llm instead of being silently skipped (F19)", _KLSql_LlmDismissed_BuildsRealInsert)

_KLSql_LlmAccepted_BuildsRealInsert() {
	Keylogger.next_event_id := 1
	entry := Map("type", "llm_accepted", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "prediction", "world", "chosen_index", 1, "net_saved_chars", 5)
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "llm_accepted must produce exactly one INSERT row")
	AssertContains(rows[1], "'accepted'", "llm_accepted must map to kind='accepted'")
}
Test("KL_BuildInserts: llm_accepted reaches events_llm instead of being silently skipped (F19)", _KLSql_LlmAccepted_BuildsRealInsert)





; ===================================================================
; ===================================================================
; ======= 2/ volume/network/clipboard/roi -> new tables (F21) =======
; ===================================================================
; ===================================================================

_KLSql_VolumeChange_BuildsRealInsert() {
	Keylogger.next_event_id := 1
	entry := Map("type", "volume_change", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "volume_pct", 42, "muted", false, "change", "level")
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "volume_change must produce exactly one INSERT row")
	AssertContains(rows[1], "INSERT OR IGNORE INTO events_av", "volume_change must insert into events_av, not silently skip")
}
Test("KL_BuildInserts: volume_change reaches events_av instead of being silently skipped (F21)", _KLSql_VolumeChange_BuildsRealInsert)

_KLSql_VpnConnected_BuildsRealInsert() {
	Keylogger.next_event_id := 1
	entry := Map("type", "vpn_connected", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "adapter", "vpn")
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "vpn_connected must produce exactly one INSERT row")
	AssertContains(rows[1], "INSERT OR IGNORE INTO events_network", "vpn_connected must insert into events_network, not silently skip")
}
Test("KL_BuildInserts: vpn_connected reaches events_network instead of being silently skipped (F21)", _KLSql_VpnConnected_BuildsRealInsert)

_KLSql_ClipboardCopy_BuildsRealInsert() {
	Keylogger.next_event_id := 1
	entry := Map("type", "clipboard_copy", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "content_type", "text", "char_count", 12)
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "clipboard_copy must produce exactly one INSERT row")
	AssertContains(rows[1], "INSERT OR IGNORE INTO events_clipboard", "clipboard_copy must insert into events_clipboard, not silently skip")
}
Test("KL_BuildInserts: clipboard_copy reaches events_clipboard instead of being silently skipped (F21)", _KLSql_ClipboardCopy_BuildsRealInsert)

_KLSql_UnknownType_StillSkipped() {
	Keylogger.next_event_id := 1
	entry := Map("type", "totally_unhandled_type", "timestamp", "2026-07-02 10:00:00.000")
	rows := KL_BuildInserts(entry)
	AssertEqual(0, rows.Length, "a genuinely unhandled type must still return an empty array")
}
Test("KL_BuildInserts: genuinely unknown type still returns empty array", _KLSql_UnknownType_StillSkipped)


_KLSql_EveryEventKindReplaysWithStableIdentity() {
	EventTypes := [
		"typing", "app_switch", "window_switch", "shortcut", "system_event",
		"hotstring", "hotstring_suggested", "hotstring_dismissed",
		"hotstring_near_miss", "manual_typed_known_trigger",
		"llm_generation", "llm_generation_failed", "llm_suggested",
		"llm_dismissed", "llm_accepted", "session_start", "session_end",
		"idle_start", "idle_end", "ergo_event", "window_resize", "window_move",
		"window_state_change", "monitor_focus_change", "virtual_desktop_switch",
		"mouse_click", "mouse_drag", "mouse_scroll", "mouse_idle_park",
		"volume_change", "screen_recording_start", "screen_recording_end",
		"network_change", "internet_up", "internet_down", "vpn_connected",
		"vpn_disconnected", "clipboard_copy", "clipboard_paste", "paste_burst",
		"roi_snapshot", "new_trigger_candidate", "trigger_halflife"]
	Keylogger.next_event_id := 700
	for EventType in EventTypes {
		Entry := Map("type", EventType, "timestamp", "2026-08-27 21:30:00.000",
			"app", "AuditFixture", "events", [])
		StableId := KL_AssignStableEventId(Entry)
		DurableLine := KL_JsonEncode(Entry)
		ReplayA := KL_JsonDecode(DurableLine)
		ReplayB := KL_JsonDecode(DurableLine)
		NextBeforeReplay := Keylogger.next_event_id
		RowsA := KL_BuildInserts(ReplayA)
		RowsB := KL_BuildInserts(ReplayB)
		AssertEqual(1, RowsA.Length,
			EventType . " must remain a persistable event kind in the replay matrix")
		AssertEqual(RowsA[1], RowsB[1],
			EventType . " must replay to the same primary-key identity after a crash")
		AssertContains(RowsA[1], ", " . StableId . ",",
			EventType . " must use the id serialized before journal publication")
		AssertEqual(NextBeforeReplay, Keylogger.next_event_id,
			EventType . " replay must not allocate a fresh identifier")
	}
}
Test("keylogger SQL: every event kind replays with stable journal identity (journal-stable-event-id)",
	_KLSql_EveryEventKindReplaysWithStableIdentity)


_KLSql_SustainedTypingKeepsRamQueueBounded() {
	SavedPending := Keylogger._pending_entries
	State := Map("lines", [], "flushes", 0)
	Port := Map(
		"open", (*) => State,
		"encode", (Entry) => KL_JsonEncode(Entry),
		"append", (Sink, Line) => (Sink["lines"].Push(Line), true),
		"flush", (Sink) => (Sink["flushes"] += 1, true))
	try {
		Keylogger._pending_entries := []
		Loop 40 {
			Entry := Map("type", "shortcut", "timestamp", "2026-08-27 21:30:00.000",
				"app", "SustainedTyping", "shortcut", "Ctrl+S")
			KL_AssignStableEventId(Entry)
			Keylogger._pending_entries.Push(Entry)
			Result := _KL_JournalPendingEntries(Port)
			AssertTrue(Result["ok"],
				"each active-typing tick must complete its lightweight durable handoff")
			AssertEqual(0, Keylogger._pending_entries.Length,
				"the RAM queue must remain bounded instead of growing for the whole session")
		}
		AssertEqual(40, State["lines"].Length,
			"every sustained-input tick must leave a durable JSONL record before a crash")
		AssertEqual(40, State["flushes"],
			"each tick must cross the explicit durability boundary before returning")
	} finally {
		Keylogger._pending_entries := SavedPending
	}
}
Test("keylogger journal: sustained typing drains RAM every tick (sustained-typing-durability)",
	_KLSql_SustainedTypingKeepsRamQueueBounded)


_KLSql_JournalFailureRetainsUnprovenEntries() {
	SavedPending := Keylogger._pending_entries
	try {
		Keylogger._pending_entries := [
			Map("type", "shortcut", "_event_id", 901),
			Map("type", "shortcut", "_event_id", 902)]
		State := Map("lines", [])
		Port := Map(
			"open", (*) => State,
			"encode", (Entry) => KL_JsonEncode(Entry),
			"append", (Sink, Line) => (Sink["lines"].Push(Line), true),
			"flush", (*) => false)
		Result := _KL_JournalPendingEntries(Port)
		AssertFalse(Result["ok"],
			"an unproved flush must fail the durable handoff")
		AssertEqual(2, Keylogger._pending_entries.Length,
			"every unflushed event must return to RAM for retry")
		AssertEqual(901, Keylogger._pending_entries[1]["_event_id"],
			"retry must preserve the original event order and stable identity")
	} finally {
		Keylogger._pending_entries := SavedPending
	}
}
Test("keylogger journal: flush failure retains the batch (sustained-typing-durability)",
	_KLSql_JournalFailureRetainsUnprovenEntries)


_KLSql_ShutdownRefusesDetachedFlushDebt() {
	Saved := Keylogger._flush_in_progress
	try {
		Keylogger._flush_in_progress := true
		AssertFalse(KL_FlushShutdownReady(),
			"OnExit must refuse while a detached snapshot has only a local owner")
		Keylogger._flush_in_progress := false
		AssertTrue(KL_FlushShutdownReady(),
			"shutdown may proceed once the interrupted flush released its debt")
	} finally {
		Keylogger._flush_in_progress := Saved
	}
}
Test("keylogger shutdown: detached flush debt refuses exit (onexit-detached-flush-debt)",
	_KLSql_ShutdownRefusesDetachedFlushDebt)





; ==============================================================================
; ==============================================================================
; ======= 3/ every non-first value in a multi-value case (fallthrough-bug) ====
; ==============================================================================
; ==============================================================================

; Regression for a latent bug discovered while implementing F21: KL_BuildInserts's
; switch used to list multiple event types as consecutive EMPTY "case X:" lines
; (a C-style fall-through pattern) ending in one "case Y: return [...]". In this
; AHK v2 build an empty case body does NOT fall through to the next case — it is
; silently treated as "no match", so every type EXCEPT THE LAST in each group
; (hotstring_near_miss, window_resize/window_move/window_state_change/
; monitor_focus_change, mouse_click/mouse_drag/mouse_scroll) fell through to the
; "Unknown type — silently skip" default and was destroyed at every day rollover
; with zero trace. The fix lists every value in a single comma-separated case
; (AHK v2's actual multi-value syntax). This test exercises the FIRST value of
; every multi-value case group so a regression to the empty-case-line pattern
; fails loudly instead of silently dropping events again.
_KLSql_AssertFirstValueOfGroupNotDropped(FirstValue) {
	Keylogger.next_event_id := 1
	entry := Map("type", FirstValue, "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp")
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, FirstValue . " (first value of a multi-value case) must produce exactly one INSERT row, not fall through to the unknown-type default")
}
Test("KL_BuildInserts: 'hotstring_near_miss' (first value of its case group) is not silently dropped (switch-fallthrough-bug)",
	() => _KLSql_AssertFirstValueOfGroupNotDropped("hotstring_near_miss"))
Test("KL_BuildInserts: 'window_resize' (first value of its case group) is not silently dropped (switch-fallthrough-bug)",
	() => _KLSql_AssertFirstValueOfGroupNotDropped("window_resize"))
Test("KL_BuildInserts: 'mouse_click' (first value of its case group) is not silently dropped (switch-fallthrough-bug)",
	() => _KLSql_AssertFirstValueOfGroupNotDropped("mouse_click"))
Test("KL_BuildInserts: 'volume_change' (first value of its case group) is not silently dropped (switch-fallthrough-bug)",
	() => _KLSql_AssertFirstValueOfGroupNotDropped("volume_change"))
Test("KL_BuildInserts: 'network_change' (first value of its case group) is not silently dropped (switch-fallthrough-bug)",
	() => _KLSql_AssertFirstValueOfGroupNotDropped("network_change"))
Test("KL_BuildInserts: 'clipboard_copy' (first value of its case group) is not silently dropped (switch-fallthrough-bug)",
	() => _KLSql_AssertFirstValueOfGroupNotDropped("clipboard_copy"))
Test("KL_BuildInserts: 'roi_snapshot' (first value of its case group) is not silently dropped (switch-fallthrough-bug)",
	() => _KLSql_AssertFirstValueOfGroupNotDropped("roi_snapshot"))
