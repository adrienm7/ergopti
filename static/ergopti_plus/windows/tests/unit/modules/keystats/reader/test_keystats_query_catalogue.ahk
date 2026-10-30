; tests/unit/modules/keystats/reader/test_keystats_query_catalogue.ahk

; ==============================================================================
; MODULE: Keystats Named-Query Catalogue Tests (Windows)
; DESCRIPTION:
; The manifest reader renders eleven of its statements from the shared query
; catalogue (_shared/data/db/queries.sql), compiled into
; _generated/keystats_queries.ahk: the statements macOS and Linux run too.
;
; FEATURES & RATIONALE:
; 1. Results, not text: the realistic fixture the JS catalogue test runs is
;    loaded into the real SQLite DLL, and every rendered query must return the
;    expected rows recorded in query_results.json. Rows whose text holds a NUL
;    byte are removed first, because how a binding reads such text is a
;    property of the binding, not of the query.
; 2. The renderer refuses an unknown name and a wrong parameter set.
; 3. Each reader function renders its query by name instead of retyping it.
; ==============================================================================

; The catalogue queries the Windows manifest reader renders, by reader function.
_KLQCat_ReaderQueries() {
	return Map(
		"KLR__SumAppDay", "manifest.app_day",
		"KLR__SumBuckets", "manifest.buckets",
		"KLR__SumBurst", "manifest.burst",
		"KLR__SumSession", "manifest.session",
		"KLR__SumCharsClass", "manifest.chars_class",
		"KLR__SumErrors", "manifest.errors",
		"KLR__SumLayouts", "manifest.layouts",
		"KLR__SumKcHold", "manifest.kc_hold",
		"KLR__SumTitles", "manifest.titles",
		"KLR__SumHourly", "manifest.hourly",
		"KLR__SumHourlyMin5", "manifest.hourly_min5")
}

; One comparable line per row: keys in Map order, numbers at a fixed precision
; (SQLite returns 300.0 where JSON says 300), SQL NULL and JSON null alike.
_KLQCat_Canonical(Row) {
	Text := ""
	for Key, Value in Row {
		if (Value == JSON_NULL)
			Value := ""
		Text .= Key . "=" . ((Value != "" && IsNumber(Value)) ? Format("{:.6f}", Value) : "s:" . Value) . Chr(1)
	}
	return Text
}

; InStr reads its needle as a C string, so InStr(Value, Chr(0)) is an empty
; needle that matches every row; PCRE takes the subject with its length.
_KLQCat_HasNul(Row) {
	for Key, Value in Row
		if (Value is String) && RegExMatch(Value, "\x00")
			return true
	return false
}

_KLQCat_FixtureReturnsCatalogueRows() {
	global _SharedDir
	AssertFalse(_KLQCat_HasNul(Map("app", "Code")), "a plain row is compared, not stripped as NUL-bearing")
	AssertTrue(_KLQCat_HasNul(Map("app", "Co" . Chr(0) . "de")), "an embedded NUL is detected")
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the catalogue fixture must open an in-memory DB")
	try {
		AssertTrue(KLR_LoadSchema(db), "the fixture uses the canonical production schema")
		AssertTrue(SQLite_Exec(db, FSReadStrict(_SharedDir . "\tests\corpus\keystats\query_fixture.sql")),
			"the shared fixture loads")
		Strip := ""
		for Table, Columns in Map("agg_app_day", ["app", "category"], "agg_app_day_buckets", ["app"],
				"agg_app_day_burst", ["app"], "agg_app_day_session", ["app"],
				"agg_app_day_chars_class", ["app"], "agg_app_day_errors", ["app"],
				"agg_app_day_layouts", ["app", "layout"], "agg_app_day_kc_hold", ["app"],
				"agg_app_day_titles", ["app", "title"], "agg_app_day_hourly", ["app"],
				"agg_app_day_hourly_min5", ["app"]) {
			for Column in Columns
				Strip .= "DELETE FROM " . Table . " WHERE instr(CAST(" . Column . " AS BLOB), x'00') > 0;"
		}
		AssertTrue(SQLite_Exec(db, Strip), "NUL-bearing rows are removed")
		Expected := JsonParse(FSReadStrict(_SharedDir . "\tests\corpus\keystats\query_results.json"))
		for Fn, Name in _KLQCat_ReaderQueries() {
			for Filter, Where in Expected["filters"] {
				Got := Map()
				for Row in SQLite_Query(db, KeystatsQuery(Name, Map("where", Where))) {
					Key := _KLQCat_Canonical(Row)
					Got[Key] := Got.Get(Key, 0) + 1
				}
				Want := Map()
				for Row in Expected["queries"][Name][Filter]["cli_json"] {
					if _KLQCat_HasNul(Row)
						continue
					Key := _KLQCat_Canonical(Row)
					Want[Key] := Want.Get(Key, 0) + 1
				}
				AssertTrue(Want.Count > 0, Name . " " . Filter . " must compare at least one row")
				AssertEqual(Want.Count, Got.Count, Name . " " . Filter . ": distinct rows")
				for Key, Count in Want
					AssertEqual(Count, Got.Get(Key, 0), Name . " " . Filter . ": " . StrReplace(Key, Chr(1), " "))
			}
		}
	} finally {
		SQLite_Close(db)
	}
}
Test("Keystats query catalogue: the fixture returns the expected rows (keystats-query-catalogue)",
	_KLQCat_FixtureReturnsCatalogueRows)

_KLQCat_RendererRefusals() {
	Cases := [
		["manifest.unknown", Map("where", "")],
		["manifest.app_day", Map()],
		["manifest.app_day", Map("where", 1)],
		["manifest.app_day", Map("where", "", "extra", "")]]
	for Misuse in Cases {
		Refused := false
		try KeystatsQuery(Misuse[1], Misuse[2])
		catch ValueError
			Refused := true
		AssertTrue(Refused, "KeystatsQuery must refuse case " . A_Index . " rather than render other SQL")
	}
	Sql := KeystatsQuery("manifest.titles", Map("where", " WHERE app = '%1 {{where}}'"))
	AssertTrue(InStr(Sql, " WHERE app = '%1 {{where}}' GROUP BY") > 0, "the filter is spliced verbatim")
}
Test("Keystats query catalogue: the renderer refuses misuse (keystats-query-catalogue)",
	_KLQCat_RendererRefusals)

_KLQCat_ReaderRendersByName() {
	for Fn, Name in _KLQCat_ReaderQueries() {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must be locatable")
		Assert(InStr(Body, 'KLR_ManifestSql("' . Name . '"') > 0, Fn . " must render " . Name . " by name")
		Assert(InStr(Body, "SELECT ") == 0, Fn . " must not retype the catalogue SQL")
	}
}
Test("Keystats query catalogue: the manifest reader renders by name (keystats-query-catalogue)",
	_KLQCat_ReaderRendersByName)

; The same corpus the JS reference and both Lua renderers replay: byte-exact SQL.
; JSON null is how the corpus spells a missing slot, which here is an absent key.
_KLQCat_WriteVectorsRenderExactly() {
	global _SharedDir
	Vectors := JsonParse(FSReadStrict(_SharedDir . "\tests\corpus\keystats\write_query_vectors.json"))["vectors"]
	Native := 0
	Seen := Map()
	for Vector in Vectors {
		if (Vector["dialect"] != "native")
			continue
		Values := Map()
		for Key, Value in Vector["values"]
			if (Value !== JSON_NULL)
				Values[Key] := Value
		AssertEqual(Vector["sql"], KeystatsQuery(Vector["name"], Values), Vector["name"] . " vector " . A_Index)
		Native += 1
		Seen[Vector["name"]] := true
	}
	AssertTrue(Native > 0, "the corpus must hold native vectors")
	for Name in ["meta.set", "meta.seed", "devices.upsert", "agg.app_day", "agg.burst", "agg.ngram", "agg.title_prune",
			"agg.ngram_keycode", "agg.ngram_scancode", "agg.ngram_shortcut", "agg.system_day",
			"events.app_switch", "events.session", "events.typing", "events.llm"]
		AssertTrue(Seen.Has(Name), "the replay must reach " . Name)
}
Test("Keystats query catalogue: the write vectors render to the exact SQL (keystats-query-catalogue)",
	_KLQCat_WriteVectorsRenderExactly)

_KLQCat_SlotRefusals() {
	Good := Map("key", "k", "value", "v")
	AssertEqual("INSERT OR REPLACE INTO meta (key, value) VALUES ('k', 'v');", KeystatsQuery("meta.set", Good))
	for Misuse in [Map("key", "k"), Map("key", "k", "value", 1), Map("key", "k", "value", "v", "extra", "x")] {
		Refused := false
		try KeystatsQuery("meta.set", Misuse)
		catch ValueError
			Refused := true
		AssertTrue(Refused, "meta.set must refuse text-slot misuse " . A_Index)
	}
	Values := Map("device_id", "d", "id", 7, "ts", "t", "date", "x", "app", "a", "kind", "k", "trigger", "g", "replacement", "r")
	Sql := KeystatsQuery("events.hotstring", Values)
	AssertContains(Sql, "'r', NULL, NULL);", "both absent nullable slots are NULL")
	Values["id"] := "not a number"
	AssertThrows(() => KeystatsQuery("events.hotstring", Values), "a non-number in an integer slot")
	Values["id"] := 1e308 * 10
	AssertThrows(() => KeystatsQuery("events.hotstring", Values), "an infinity in an integer slot")
	Values["id"] := "7"
	AssertContains(KeystatsQuery("events.hotstring", Values), "VALUES ('d', 7, ", "a numeric string is a number")
	Values["id"] := 7.9
	AssertContains(KeystatsQuery("events.hotstring", Values), "VALUES ('d', 7, ", "an integer slot floors")
}
Test("Keystats query catalogue: a slot refuses a missing or mistyped value (keystats-query-catalogue)",
	_KLQCat_SlotRefusals)

; The batch families the walker emits, through the real SQLite DLL. Two flushes
; must add up, and the columns the SQL rebuild owns must keep their value.
_KLQCat_WalkerFamiliesAccumulate() {
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the walker fixture must open an in-memory DB")
	try {
		AssertTrue(KLR_LoadSchema(db), "the fixture uses the canonical production schema")
		AssertTrue(SQLite_Exec(db, "INSERT INTO agg_system_day (device_id, date, wifi_changes, sleep_ms) "
			. "VALUES ('dev','2026-10-01',9,70);"), "the rebuild-owned columns are seeded")
		Loop 2 {
			KLW_ResetBatch()
			KLW.batch["kc_ngram"]["k"] := Map("date", "2026-10-01", "app", "it's", "keycode", 38, "count", 2)
			KLW.batch["sc_kb_ngram"]["s"] := Map("date", "2026-10-01", "app", "it's", "scancode", 30, "count", 3)
			KLW.batch["sc_ngram"]["ngram_shortcut_bigrams"] := Map("t", Map("date", "2026-10-01", "app", "it's",
				"token", "Ctrl+C'V", "count", 4))
			KLW.batch["system_day"]["d"] := Map("date", "2026-10-01", "space_switches", 1,
				"audio_muted_ms", 2, "passive_count", 3, "night_wake_count", 5)
			Sql := KLW_BuildBatchSql("dev")
			AssertTrue(SQLite_Exec(db, Sql), "flush " . A_Index . " must be accepted by the schema")
		}
		_KLQCat_AssertOneRow(db, "SELECT app, keycode, c FROM ngram_keycodes", Map("app", "it's", "keycode", 38, "c", 4))
		_KLQCat_AssertOneRow(db, "SELECT app, scancode, c FROM ngram_scancodes", Map("app", "it's", "scancode", 30, "c", 6))
		_KLQCat_AssertOneRow(db, "SELECT token, c FROM ngram_shortcut_bigrams", Map("token", "Ctrl+C'V", "c", 8))
		_KLQCat_AssertOneRow(db, "SELECT wifi_changes, space_switches, audio_muted_ms, locked_ms, sleep_ms, passive_count, night_wake_count FROM agg_system_day",
			Map("wifi_changes", 9, "space_switches", 2, "audio_muted_ms", 4, "locked_ms", 0, "sleep_ms", 70,
				"passive_count", 6, "night_wake_count", 10))
	} finally {
		KLW_ResetBatch()
		SQLite_Close(db)
	}
}
Test("Keystats query catalogue: the walker's key, shortcut and system families add up (keystats-write-catalogue)",
	_KLQCat_WalkerFamiliesAccumulate)

; A journal number the row cannot hold used to reach a NOT NULL column as NULL,
; and INSERT OR IGNORE then dropped the whole typing event without a word.
_KLQCat_TypingAndLlmRows() {
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the event fixture must open an in-memory DB")
	try {
		AssertTrue(KLR_LoadSchema(db), "the fixture uses the canonical production schema")
		AssertTrue(SQLite_Exec(db, KL_BuildInsertTyping(Map("timestamp", "2026-10-01 10:00:00.000", "app", "Code",
			"app_category", "editor", "text", "it's", "events", [], "mouse_clicks", "lost", "is_fullscreen", 1,
			"wpm", 61.25, "layout", ""), 1)), "the typing row must be accepted")
		_KLQCat_AssertOneRow(db, "SELECT app_category, is_fullscreen, in_meeting, mouse_clicks, pause_before_ms, "
			. "battery_level IS NULL AS no_battery, wpm, layout IS NULL AS no_layout, text FROM events_typing",
			Map("app_category", "editor", "is_fullscreen", 1, "in_meeting", 0, "mouse_clicks", 0, "pause_before_ms", 0,
				"no_battery", 1, "wpm", 61.25, "no_layout", 1, "text", "it's"))
		AssertTrue(SQLite_Exec(db, KL_BuildInsertLlm(Map("timestamp", "2026-10-01 10:00:00.000", "prediction", "x'y",
			"count", 3, "est_cost_usd", 0.00125), 2, "suggested")), "the LLM row must be accepted")
		_KLQCat_AssertOneRow(db, "SELECT app, kind, prediction, predictions_json, all_predictions_json, count, "
			. "deletes IS NULL AS no_deletes, est_cost_usd FROM events_llm",
			Map("app", "Unknown", "kind", "suggested", "prediction", "x'y", "predictions_json", "{}",
				"all_predictions_json", "{}", "count", 3, "no_deletes", 1, "est_cost_usd", 0.00125))
	} finally {
		SQLite_Close(db)
	}
}
Test("Keystats query catalogue: typing and LLM events store their rows (keystats-write-catalogue)",
	_KLQCat_TypingAndLlmRows)

; The hotstring unit declaration is the driver's metadata writer: first value kept.
_KLQCat_UnitDeclarationSeedsMeta() {
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the declaration fixture must open an in-memory DB")
	try {
		AssertTrue(KLR_LoadSchema(db), "the fixture uses the canonical production schema")
		Key := KLHotstringUnits.Prefix . "it's"
		AssertTrue(SQLite_Exec(db, "INSERT INTO meta (key, value) VALUES (" . SQLite_Q(Key) . ", 'kept');"), "an earlier value")
		AssertTrue(SQLite_Exec(db, KLHotstringUnits.DeclarationSql("it's")), "the seed must not conflict")
		_KLQCat_AssertOneRow(db, "SELECT value FROM meta WHERE key=" . SQLite_Q(Key), Map("value", "kept"))
		AssertTrue(SQLite_Exec(db, KLHotstringUnits.DeclarationSql("other")), "a second device declares its own key")
		_KLQCat_AssertOneRow(db, "SELECT value FROM meta WHERE key=" . SQLite_Q(KLHotstringUnits.Prefix . "other"),
			Map("value", KLHotstringUnits.WindowsUnit))
	} finally {
		SQLite_Close(db)
	}
}
Test("Keystats query catalogue: the hotstring unit declaration seeds metadata (keystats-write-catalogue)",
	_KLQCat_UnitDeclarationSeedsMeta)

_KLQCat_AssertOneRow(db, Sql, Expected) {
	Rows := SQLite_Query(db, Sql . ";")
	AssertEqual(1, Rows.Length, "exactly one row: " . Sql)
	for Column, Value in Expected {
		Got := Rows[1][Column]
		if IsNumber(Value)
			AssertEqual(Format("{:.6f}", Value), Format("{:.6f}", Got), Column . " of " . Sql)
		else
			AssertEqual(Value, Got, Column . " of " . Sql)
	}
}
