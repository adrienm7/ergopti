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
	Keylogger.next_event_id := 1
	entry := Map(
		"type", "llm_generation", "timestamp", "2026-08-20 10:00:00.000",
		"prompt_tokens", 111, "completion_tokens", 222,
		"total_tokens", 333, "est_cost_usd", 4.56789)
	Sql := KL_BuildInserts(entry)[1]
	for Column in ["prompt_tokens", "completion_tokens", "total_tokens", "est_cost_usd"]
		AssertContains(Sql, Column, "events_llm must retain " . Column)
	for Sentinel in ["111", "222", "333", "4.56789"]
		AssertContains(Sql, Sentinel, "usage accounting value must reach the SQL row: " . Sentinel)
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
