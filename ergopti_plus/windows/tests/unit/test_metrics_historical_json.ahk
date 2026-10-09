; static/ergopti_plus/windows/tests/unit/test_metrics_historical_json.ahk

; ==============================================================================
; MODULE: Historical JSON Projection Tests
; DESCRIPTION: SQL serialization preserves historical filters, slots and counters.
; ==============================================================================

#Requires AutoHotkey v2.0

_MHJ_HistoricalProjection() {
	Db := SQLite_Open(":memory:")
	Assert(Db != 0)
	try {
		AssertTrue(KLR_LoadSchema(Db))
		Token := 'quote"slash\é'
		for _, App in ["editor.exe", "Unknown", "ignored.exe"] {
			for _, Table in KLR_NGRAM_TYPE_TABLE {
				AssertTrue(SQLite_Exec(Db, "INSERT INTO " . Table
					. " (device_id,date,app,token,c,td,cd,e,esrc_json) VALUES ('d','2026-01-01',"
					. SQLite_Q(App) . "," . SQLite_Q(Token) . ",5,12,1,1,"
					. SQLite_Q('{"hotstring":1,"llm":2,"case-transform":3,"none":7}') . ")"))
			}
			for _, Table in ["ngram_shortcuts", "ngram_shortcut_bigrams"]
				AssertTrue(SQLite_Exec(Db, "INSERT INTO " . Table
					. " (device_id,date,app,token,c) VALUES ('d','2026-01-01',"
					. SQLite_Q(App) . "," . SQLite_Q(Token) . ",5)"))
			for Table, Column in Map("ngram_keycodes", "keycode", "ngram_scancodes", "scancode")
				AssertTrue(SQLite_Exec(Db, "INSERT INTO " . Table
					. " (device_id,date,app," . Column . ",c) VALUES ('d','2026-01-01',"
					. SQLite_Q(App) . ",42,5)"))
		}
		for Apps in [["editor.exe"], []] {
			Multiplier := Apps.Length ? 2 : 1
			Actual := JsonParse(KLR_BuildNgramsJson(Db, "2026-01-01", "2026-01-01", Apps))
			AssertEqual(13, Actual.Count)
			for Code in ["c", "bg", "tg", "qg", "pg", "hx", "hp", "w", "w_bg"] {
				AssertEqual(1, Actual[Code].Count)
				Item := Actual[Code][Token]
				for Field, Value in Map("c", 5, "t", 12, "e", 1, "hs", 1, "llm", 2, "o", 3)
					AssertEqual(Value * Multiplier, Item[Field], Code . ":" . Field)
			}
			for Code in ["sc", "sc_bg", "kc", "sc_kb"] {
				Key := (Code = "kc" || Code = "sc_kb") ? "42" : Token
				AssertEqual(1, Actual[Code].Count)
				AssertEqual(5 * Multiplier, Actual[Code][Key]["c"])
				for Field in ["t", "e", "hs", "llm", "o"]
					AssertEqual(0, Actual[Code][Key][Field])
			}
			Expected := KLR_ReadNgrams(Db, "2026-01-01", "2026-01-01", Apps)
			AssertEqual(KL_JsonEncode(Expected), KL_JsonEncode(Actual))
		}
		Excluded := JsonParse(KLR_BuildNgramsJson(Db, "2026-01-02", "2026-01-02"))
		AssertEqual(13, Excluded.Count)
		for _, Bucket in Excluded
			AssertEqual(0, Bucket.Count, "date filtering must exclude every fixture row")
		Tables := []
		for _, Table in KLR_NGRAM_TYPE_TABLE
			Tables.Push(Table)
		for Table in ["ngram_shortcuts", "ngram_shortcut_bigrams", "ngram_keycodes", "ngram_scancodes"]
			Tables.Push(Table)
		Today := FormatTime(A_Now, "yyyy-MM-dd")
		for Table in Tables
			AssertTrue(SQLite_Exec(Db, "UPDATE " . Table . " SET date=" . SQLite_Q(Today)))
		Range := JsonParse(KLR_BuildRangeSplitTodayJson(Db, "", Today, ["editor.exe"], Today))
		Legacy := KLR_ReadRangeSplitToday(Db, "", Today, ["editor.exe"])
		AssertEqual(KL_JsonEncode(Legacy), KL_JsonEncode(Range),
			"complete today serialization must retain deep n-grams and auxiliaries")
		AssertEqual(5, Range["today"]["editor.exe"]["hp"][Token]["c"])
		Tomorrow := FormatTime(DateAdd(A_Now, 1, "Days"), "yyyy-MM-dd")
		Rolled := JsonParse(KLR_BuildRangeSplitTodayJson(Db, "", Tomorrow, ["editor.exe"], Tomorrow))
		AssertEqual(0, Rolled["today"].Count)
		AssertEqual(10, Rolled["historical"]["hp"][Token]["c"],
			"one captured day must move all prior-day counts into history")
	} finally SQLite_Close(Db)
}
Test("metrics JSON: historical projection retains all slots and filters (metrics-historical-json)",
	_MHJ_HistoricalProjection)

_MHJ_ProjectionLimits() {
	SavedLimit := KLReadConst.MAX_NGRAM_ROWS
	Db := SQLite_Open(":memory:")
	Assert(Db != 0)
	try {
		AssertTrue(KLR_LoadSchema(Db))
		KLReadConst.MAX_NGRAM_ROWS := 2
		Day := FormatTime(A_Now, "yyyy-MM-dd")
		for Table in ["ngram_words", "ngram_shortcuts"] {
			loop 4
				AssertTrue(SQLite_Exec(Db, "INSERT INTO " . Table
					. "(device_id,date,app,token,c) VALUES ('d'," . SQLite_Q(Day)
					. ",'editor.exe','word" . A_Index . "',1)"))
		}
		History := JsonParse(KLR_BuildNgramsJson(Db))
		AssertEqual(2, History["w"].Count, "historical text tables must retain the configured limit")
		AssertEqual(4, History["sc"].Count, "historical auxiliary tables must remain uncapped")
		Today := JsonParse(KLR_BuildTodayIdxJson(Db, ["editor.exe"], true, Day))
		AssertEqual(2, Today["editor.exe"]["w"].Count)
		AssertEqual(4, Today["editor.exe"]["sc"].Count)
		AssertEqual(KL_JsonEncode(KLR_ReadNgrams(Db)), KL_JsonEncode(History))
	} finally {
		KLReadConst.MAX_NGRAM_ROWS := SavedLimit
		SQLite_Close(Db)
	}
}
Test("metrics JSON: complete snapshots preserve text caps and uncapped auxiliaries (metrics-historical-json)",
	_MHJ_ProjectionLimits)
