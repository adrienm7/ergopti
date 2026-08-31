; tests/unit/test_keylogger_llm_accepted_metrics.ahk
;
; ==============================================================================
; MODULE: Accepted LLM Output Replay and Journal Tests
; DESCRIPTION:
; New SendInput/clipboard completions are hook-invisible and therefore carry an
; explicit events_llm:v1 marker. Only marked rows are virtualised through the
; existing walker; legacy SendEvent rows stay owned by events_typing.
; ==============================================================================

_KLRLlmAccepted_OpenFixture() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the real SQLite DLL must stay loaded for the LLM replay fixture lifetime")
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the LLM replay fixture must open an in-memory DB")
	AssertTrue(KLR_LoadSchema(db),
		"the LLM replay fixture must use the canonical production schema")
	return db
}

_KLRLlmAccepted_InsertTyping(db, Id, App, Events) {
	Timestamp := Format("2026-08-13 10:00:{:02d}.000", Id)
	Sql := "INSERT INTO events_typing "
		. "(device_id,id,ts,date,app,title,url,field_role,layout,document_path,"
		. "is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,"
		. "pause_before_ms,battery_level,audio_volume,wpm,text,rich_text,events_json) VALUES ("
		. "'device-a'," . Id . "," . SQLite_Q(Timestamp)
		. ",'2026-08-13'," . SQLite_Q(App)
		. ",'fixture','','','fr','',0,0,0,0,0,0,NULL,NULL,0,'','',"
		. SQLite_Q(KL_JsonEncode(Events)) . ");"
	AssertTrue(SQLite_Exec(db, Sql), "typing fixture row must be inserted")
}

_KLRLlmAccepted_InsertAccepted(db, Id, App, Prediction, Deletes := 0,
		Marked := true) {
	Timestamp := Format("2026-08-13 10:00:{:02d}.500", Id)
	ContextSql := Marked ? SQLite_Q(KLWConst.LLM_ACCEPTED_METRICS_SOURCE) : "NULL"
	Sql := "INSERT INTO events_llm "
		. "(device_id,id,ts,date,app,kind,context,prediction,deletes,net_saved_chars) VALUES ("
		. "'device-a'," . Id . "," . SQLite_Q(Timestamp)
		. ",'2026-08-13'," . SQLite_Q(App) . ",'accepted',"
		. ContextSql . "," . SQLite_Q(Prediction) . "," . Deletes . ",0);"
	AssertTrue(SQLite_Exec(db, Sql), "accepted fixture row must be inserted")
}

_KLRLlmAccepted_ReadAppDay(db, App) {
	Rows := SQLite_Query(db,
		"SELECT llm_chars,llm_triggers,llm_input_chars FROM agg_app_day "
		. "WHERE device_id='device-a' AND date='2026-08-13' AND app="
		. SQLite_Q(App) . ";")
	AssertEqual(1, Rows.Length, "the walker must publish one app-day row for " . App)
	return Rows[1]
}

_KLRLlmAccepted_ReplaysMarkerWithoutDoubleCountingLegacy() {
	db := _KLRLlmAccepted_OpenFixture()
	try {
		LegacyEvents := []
		for _, Character in ["o", "l", "d"]
			LegacyEvents.Push([Character, 0, Map("s", 1, "st", "llm")])
		_KLRLlmAccepted_InsertTyping(db, 1, "editor.exe", LegacyEvents)
		; This is the old dual-write companion of the typing row above. It must
		; remain ignored or the historical completion is counted twice.
		_KLRLlmAccepted_InsertAccepted(db, 2, "editor.exe", "old", 0, false)
		Emoji := Chr(0x1F600)
		_KLRLlmAccepted_InsertAccepted(db, 3, "editor.exe", "A" . Emoji . "B")

		AssertEqual(2, KLR_RebuildWalkerAggregates(db),
			"cold replay must walk one legacy typing row and one marked accepted row")
		Row := _KLRLlmAccepted_ReadAppDay(db, "editor.exe")
		AssertEqual(6, Row["llm_chars"],
			"old + A-emoji-B are six logical output characters, not seven UTF-16 units")
		AssertEqual(2, Row["llm_triggers"],
			"the legacy dual-write companion must not create a third trigger")
		AssertEqual(0, Row["llm_input_chars"])

		EmojiRows := SQLite_Query(db,
			"SELECT c, json_extract(esrc_json,'$.llm') AS llm FROM ngram_chars "
			. "WHERE device_id='device-a' AND app='editor.exe' AND token="
			. SQLite_Q(Emoji) . ";")
		AssertEqual(1, EmojiRows.Length,
			"an astral character must survive replay as one n-gram token")
		AssertEqual(1, EmojiRows[1]["c"])
		AssertEqual(1, EmojiRows[1]["llm"])
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keylogger reader: marked accepted rows replay once beside legacy dual-write (llm-accepted-metrics)",
	_KLRLlmAccepted_ReplaysMarkerWithoutDoubleCountingLegacy)

_KLRLlmAccepted_PreservesDeletesAndCrossBoundaryOrder() {
	db := _KLRLlmAccepted_OpenFixture()
	try {
		_KLRLlmAccepted_InsertTyping(db, 10, "order.exe", [["x", 10, Map()]])
		_KLRLlmAccepted_InsertAccepted(db, 11, "order.exe", "y")
		_KLRLlmAccepted_InsertTyping(db, 12, "order.exe", [["z", 10, Map()]])

		Manual := []
		for _, Character in ["a", "b", "c"]
			Manual.Push([Character, 10, Map()])
		_KLRLlmAccepted_InsertTyping(db, 20, "delete.exe", Manual)
		_KLRLlmAccepted_InsertAccepted(db, 21, "delete.exe", "XYZ", 2)

		AssertEqual(5, KLR_RebuildWalkerAggregates(db),
			"all logical rows must replay in reserved-id order")
		for _, Token in ["xy", "yz"] {
			Rows := SQLite_Query(db,
				"SELECT c FROM ngram_bigrams WHERE device_id='device-a' "
				. "AND app='order.exe' AND token=" . SQLite_Q(Token) . ";")
			AssertEqual(1, Rows.Length,
				"cross-boundary n-gram must preserve prefix -> completion -> following input: " . Token)
		}
		Row := _KLRLlmAccepted_ReadAppDay(db, "delete.exe")
		AssertEqual(3, Row["llm_chars"], "LLM output remains gross")
		AssertEqual(2, Row["llm_input_chars"], "deleted input is counted separately")
		AssertEqual(1, Row["llm_triggers"])
		AssertEqual(1, Row["llm_chars"] - Row["llm_input_chars"],
			"the dashboard gain subtracts deleted input exactly once")
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keylogger reader: accepted replay preserves deletes and cross-boundary order (llm-accepted-metrics)",
	_KLRLlmAccepted_PreservesDeletesAndCrossBoundaryOrder)

_KLRLlmAccepted_CommitRejectsChangedPrivacyEpoch() {
	SavedInitialized := Keylogger.initialized
	SavedShuttingDown := Keylogger._shutting_down
	SavedLifecycle := Keylogger.lifecycle_generation
	SavedPending := Keylogger._pending_entries
	SavedNextId := Keylogger.next_event_id
	SavedFocus := MetricsFocusCache.state
	SavedFocusGeneration := MetricsFocusCache.generation
	SavedDisabled := MetricsFilters.disabled_apps
	SavedPrivate := MetricsFilters.private_browsing
	SavedSecure := MetricsFilters.secure_field
	SavedSystemAuth := MetricsFilters.system_auth
	SavedPasswordGeneration := KLPasswordCache.generation
	try {
		Keylogger.initialized := true
		Keylogger._shutting_down := false
		Keylogger.lifecycle_generation := 41
		Keylogger._pending_entries := []
		Keylogger.next_event_id := 700
		MetricsFocusCache.state := {
			valid: true, last_at: 1, hwnd: 123, process_name: "editor.exe",
			title: "safe", class: "Edit", failure_reason: "", timed_out: false
		}
		MetricsFocusCache.generation := 12
		MetricsFilters.disabled_apps := Map()
		MetricsFilters.private_browsing := true
		MetricsFilters.secure_field := true
		MetricsFilters.system_auth := true
		KLPasswordCache.generation := 9
		Entry := Map("type", "llm_accepted", "timestamp", "2026-08-13 10:00:00.000")
		Token := Map(
			"entries", [Entry],
			"lifecycle_generation", Keylogger.lifecycle_generation,
			"privacy", _KL_CaptureLlmJournalPrivacy()
		)

		; Same values, different publication: the focus/privacy epoch changed in
		; the open-thread gap and must invalidate telemetry fail-closed.
		MetricsFocusCache.state := {
			valid: true, last_at: 2, hwnd: 123, process_name: "editor.exe",
			title: "safe", class: "Edit", failure_reason: "", timed_out: false
		}
		MetricsFocusCache.generation += 1
		PreviousCritical := Critical("On")
		try Result := KL_CommitPreparedLlmOutputJournal(Token)
		finally Critical(PreviousCritical)
		AssertFalse(Result, "a changed focus publication must invalidate the journal")
		AssertEqual(0, Keylogger._pending_entries.Length,
			"invalidated private telemetry must never enter the canonical RAM queue")
		AssertEqual(700, Keylogger.next_event_id,
			"an invalid journal must not consume an event id")

		Token["privacy"] := _KL_CaptureLlmJournalPrivacy()
		PreviousCritical := Critical("On")
		try Result := KL_CommitPreparedLlmOutputJournal(Token)
		finally Critical(PreviousCritical)
		AssertTrue(Result)
		AssertEqual(1, Keylogger._pending_entries.Length)
		AssertEqual(700, Entry["_event_id"],
			"the output boundary must reserve the accepted row's durable order id")
	} finally {
		Keylogger.initialized := SavedInitialized
		Keylogger._shutting_down := SavedShuttingDown
		Keylogger.lifecycle_generation := SavedLifecycle
		Keylogger._pending_entries := SavedPending
		Keylogger.next_event_id := SavedNextId
		MetricsFocusCache.state := SavedFocus
		MetricsFocusCache.generation := SavedFocusGeneration
		MetricsFilters.disabled_apps := SavedDisabled
		MetricsFilters.private_browsing := SavedPrivate
		MetricsFilters.secure_field := SavedSecure
		MetricsFilters.system_auth := SavedSystemAuth
		KLPasswordCache.generation := SavedPasswordGeneration
	}
}
Test("Keylogger journal: privacy epoch changes fail closed before RAM publication (llm-accepted-metrics)",
	_KLRLlmAccepted_CommitRejectsChangedPrivacyEpoch)

_KLRLlmAccepted_SourceOwnsReservedIdOrdering() {
	FlushBody := _DriverFuncBody("KL_FlushBuffer")
	BuilderBody := _DriverFuncBody("KL_BuildInserts")
	IdentityBody := _DriverFuncBody("KL_AssignStableEventId")
	ReplayBody := _DriverFuncBody("KLR_RebuildWalkerAggregates")
	Assert(InStr(FlushBody, "EventId: KL_AllocEventId()") > 0,
		"typing must reserve its id when the mutable buffer is detached")
	Assert(InStr(BuilderBody, "KL_AssignStableEventId(entry)") > 0
		and InStr(IdentityBody, 'entry.Has("_event_id")') > 0,
		"ingest must preserve every already-reserved screen-order id through the shared identity owner")
	Assert(InStr(ReplayBody, "ORDER BY id;") > 0,
		"cold replay must order logical typing and accepted output by the reserved id")
}
Test("Keylogger journal: reserved ids single-source logical replay order (llm-accepted-metrics)",
	_KLRLlmAccepted_SourceOwnsReservedIdOrdering)

_KLRLlmAccepted_RetrySnapshotNeverMergesIntoLiveInput() {
	RestoreBody := _DriverFuncBody("_KL_RestoreBufferSnapshot")
	FlushBody := _DriverFuncBody("KL_FlushBuffer")
	Assert(InStr(RestoreBody, "Keylogger._retry_snapshots.InsertAt") > 0,
		"an invalidated detached snapshot must return to its own ordered retry queue")
	Assert(InStr(RestoreBody, "Keylogger.buffer_events") = 0,
		"an old snapshot must never merge into newer live events")
	Assert(InStr(RestoreBody, "Keylogger.buffer_text") = 0,
		"an old snapshot must never merge into newer live text")
	Assert(InStr(FlushBody, "Keylogger._retry_snapshots.RemoveAt(1)") > 0,
		"flush must drain the oldest reserved-id snapshot first")
	Assert(InStr(FlushBody, "return KL_FlushBuffer(PublishGuard?)") > 0,
		"a successful retry must drain later live input in the same flush request")
}
Test("Keylogger journal: invalidated snapshots stay separate from newer input (llm-accepted-metrics)",
	_KLRLlmAccepted_RetrySnapshotNeverMergesIntoLiveInput)
