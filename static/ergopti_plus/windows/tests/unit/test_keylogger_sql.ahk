; static/ergopti_plus/windows/tests/unit/test_keylogger_sql.ahk

; ==============================================================================
; MODULE: Keylogger SQL Builder Tests
; DESCRIPTION:
; Unit tests for KL_BuildInserts (modules/keylogger/keylogger_sql.ahk) — the
; typed dispatch that turns a decoded today.log entry into 0+ INSERT
; statements. Covers event families that used to fall through to "Unknown
; type — silently skip" and were destroyed at day rollover (F19, F21).
; ==============================================================================





; =============================================
; ============================================
; ======= 1/ llm_* -> events_llm (F19) =======
; ============================================
; =============================================

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
