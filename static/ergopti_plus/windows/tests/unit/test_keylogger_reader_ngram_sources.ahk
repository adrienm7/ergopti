; tests/unit/test_keylogger_reader_ngram_sources.ahk

; ==============================================================================
; MODULE: Keylogger Reader N-gram Source Projection Tests
; DESCRIPTION:
; Exercises every Windows n-gram dashboard projection against the real SQLite
; schema. Source attribution is additive across device rows and must retain the
; same hs/llm/o counts in the full, range, fast, and live-JSON paths.
; ==============================================================================

_KLRSource_OpenFixture() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the real SQLite DLL must stay loaded for the fixture DB lifetime")

	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the n-gram source fixture must open an in-memory DB")
	AssertTrue(KLR_LoadSchema(db),
		"the n-gram source fixture must use the canonical production schema")

	today := FormatTime(A_Now, "yyyy-MM-dd")
	sql := "INSERT INTO ngram_chars "
		. "(device_id,date,app,token,c,td,cd,e,esrc_json) VALUES ("
		. SQLite_Q("device-a") . "," . SQLite_Q(today) . ","
		. SQLite_Q("editor.exe") . "," . SQLite_Q("shared-token")
		. ",2,20,1,0," . SQLite_Q('{"hotstring":2}') . ");"
		. "INSERT INTO ngram_chars "
		. "(device_id,date,app,token,c,td,cd,e,esrc_json) VALUES ("
		. SQLite_Q("device-b") . "," . SQLite_Q(today) . ","
		. SQLite_Q("editor.exe") . "," . SQLite_Q("shared-token")
		. ",4,40,1,1," . SQLite_Q('{"hotstring":3,"llm":1}') . ");"
		. "INSERT INTO ngram_chars "
		. "(device_id,date,app,token,c,td,cd,e,esrc_json) VALUES ("
		. SQLite_Q("device-a") . "," . SQLite_Q(today) . ","
		. SQLite_Q("editor.exe") . "," . SQLite_Q("other-token")
		. ",2,0,0,0," . SQLite_Q('{"case-transform":2,"none":99}') . ");"
	AssertTrue(SQLite_Exec(db, sql),
		"the fixture must contain two independently attributed shared-token rows")
	return db
}

_KLRSource_AssertShared(item, path_name) {
	AssertEqual(6, item["c"], path_name . " must retain the total token count")
	AssertEqual(60, item["t"], path_name . " must retain the total delay")
	AssertEqual(1, item["e"], path_name . " must retain the total error count")
	AssertEqual(5, item["hs"],
		path_name . " must sum hotstring attribution across both device rows")
	AssertEqual(1, item["llm"],
		path_name . " must sum LLM attribution across both device rows")
	AssertEqual(0, item["o"], path_name . " must not invent another source")
	AssertEqual(0, item["c"] - item["hs"] - item["llm"] - item["o"],
		path_name . " must expose the same manual-only filter count")
}

_KLRSource_AssertOther(item, path_name) {
	AssertEqual(0, item["hs"], path_name . " must not classify other as hotstring")
	AssertEqual(0, item["llm"], path_name . " must not classify other as LLM")
	AssertEqual(2, item["o"],
		path_name . " must sum every synthetic source outside hotstring/LLM")
	AssertEqual(0, item["c"] - item["hs"] - item["llm"] - item["o"],
		path_name . " must exclude the legacy none marker from other")
}

_KLRSource_AllDashboardPathsAgree() {
	db := _KLRSource_OpenFixture()
	try {
		today := FormatTime(A_Now, "yyyy-MM-dd")
		apps := ["editor.exe"]

		full := KLR_ReadNgrams(db, today, today, apps)
		_KLRSource_AssertShared(full["c"]["shared-token"], "full projection")
		_KLRSource_AssertOther(full["c"]["other-token"], "full projection")

		range := KLR_ReadRangeSplitToday(db, today, today, apps)
		range_chars := range["today"]["editor.exe"]["c"]
		_KLRSource_AssertShared(range_chars["shared-token"], "range projection")
		_KLRSource_AssertOther(range_chars["other-token"], "range projection")

		fast := KLR_ReadRangeSplitTodayFast(db, apps)
		fast_chars := fast["today"]["editor.exe"]["c"]
		_KLRSource_AssertShared(fast_chars["shared-token"], "fast projection")
		_KLRSource_AssertOther(fast_chars["other-token"], "fast projection")

		live := JsonParse(KLR_BuildTodayIdxJson(db, apps))
		live_chars := live["editor.exe"]["c"]
		_KLRSource_AssertShared(live_chars["shared-token"], "live JSON projection")
		_KLRSource_AssertOther(live_chars["other-token"], "live JSON projection")
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keylogger reader: every n-gram source projection sums device rows (ngram-source-projection)",
	_KLRSource_AllDashboardPathsAgree)

_KLRAppFilter_OpenFixture() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the app-filter fixture must keep the real SQLite DLL loaded")

	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the app-filter fixture must open an in-memory DB")
	AssertTrue(KLR_LoadSchema(db),
		"the app-filter fixture must use the canonical production schema")

	today := FormatTime(A_Now, "yyyy-MM-dd")
	sql := ""
	for index, app_name in ["selected.exe", "other.exe", "Unknown"] {
		token := ["selected-token", "other-token", "unknown-token"][index]
		sql .= "INSERT INTO ngram_chars "
			. "(device_id,date,app,token,c,td,cd,e,esrc_json) VALUES ("
			. SQLite_Q("device-a") . "," . SQLite_Q(today) . ","
			. SQLite_Q(app_name) . "," . SQLite_Q(token)
			. ",1,10,1,0," . SQLite_Q('{}') . ");"
		sql .= "INSERT INTO ngram_shortcuts "
			. "(device_id,date,app,token,c) VALUES ("
			. SQLite_Q("device-a") . "," . SQLite_Q(today) . ","
			. SQLite_Q(app_name) . "," . SQLite_Q(token . "-shortcut") . ",1);"
	}
	AssertTrue(SQLite_Exec(db, sql),
		"the app-filter fixture must contain selected, unselected, and Unknown rows")
	return db
}

_KLRAppFilter_AssertTodayBuckets(today_idx, path_name) {
	AssertTrue(today_idx.Has("selected.exe"),
		path_name . " must retain the selected real application")
	AssertTrue(today_idx.Has("Unknown"),
		path_name . " must retain the non-selectable Unknown bucket")
	AssertFalse(today_idx.Has("other.exe"),
		path_name . " must exclude an unselected real application")
	AssertTrue(today_idx["selected.exe"]["c"].Has("selected-token"),
		path_name . " must retain selected-app character n-grams")
	AssertTrue(today_idx["Unknown"]["sc"].Has("unknown-token-shortcut"),
		path_name . " must apply the same Unknown policy to auxiliary n-grams")
}

_KLRAppFilter_UnknownSurvivesEveryProjection() {
	db := _KLRAppFilter_OpenFixture()
	try {
		today := FormatTime(A_Now, "yyyy-MM-dd")
		apps := ["selected.exe"]

		full := KLR_ReadNgrams(db, today, today, apps)
		AssertTrue(full["c"].Has("selected-token"),
			"full projection must retain the selected app")
		AssertTrue(full["c"].Has("unknown-token"),
			"full projection must retain Unknown beside a real-app selection")
		AssertFalse(full["c"].Has("other-token"),
			"full projection must exclude an unselected real app")
		AssertTrue(full["sc"].Has("unknown-token-shortcut"),
			"full projection must retain Unknown auxiliary n-grams")

		range := KLR_ReadRangeSplitToday(db, today, today, apps)
		_KLRAppFilter_AssertTodayBuckets(range["today"], "range projection")

		fast := KLR_ReadRangeSplitTodayFast(db, apps)
		_KLRAppFilter_AssertTodayBuckets(fast["today"], "fast projection")

		live := JsonParse(KLR_BuildTodayIdxJson(db, apps))
		_KLRAppFilter_AssertTodayBuckets(live, "live JSON projection")
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keylogger reader: app filters retain Unknown in every projection (AHK-26)",
	_KLRAppFilter_UnknownSurvivesEveryProjection)

_KLRAppSelection_AssertOnlyUnknown(today_idx, path_name) {
	AssertEqual(1, today_idx.Count,
		path_name . " must not decode an explicit empty selection as every app")
	AssertTrue(today_idx.Has("Unknown"),
		path_name . " must keep the separately governed Unknown bucket")
	AssertTrue(today_idx["Unknown"]["c"].Has("unknown-token"),
		path_name . " must retain Unknown character n-grams")
	AssertTrue(today_idx["Unknown"]["sc"].Has("unknown-token-shortcut"),
		path_name . " must retain Unknown auxiliary n-grams")
}

_KLRAppSelection_AllNoneSubsetStayDistinct() {
	db := _KLRAppFilter_OpenFixture()
	try {
		today := FormatTime(A_Now, "yyyy-MM-dd")

		all_apps := ["selected.exe", "other.exe"]
		all_rows := KLR_ReadNgrams(db, today, today, all_apps)
		for token in ["selected-token", "other-token", "unknown-token"]
			AssertTrue(all_rows["c"].Has(token),
				"all-app selection must retain " . token)

		none_rows := KLR_ReadNgrams(db, today, today, [])
		AssertEqual(1, none_rows["c"].Count,
			"explicit none must exclude every named-app character row")
		AssertTrue(none_rows["c"].Has("unknown-token"),
			"explicit none must keep Unknown as a separate policy")
		AssertEqual(1, none_rows["sc"].Count,
			"explicit none must exclude named-app auxiliary rows too")

		range_none := KLR_ReadRangeSplitToday(db, today, today, [])
		_KLRAppSelection_AssertOnlyUnknown(range_none["today"], "range projection")
		fast_none := KLR_ReadRangeSplitTodayFast(db, [])
		_KLRAppSelection_AssertOnlyUnknown(fast_none["today"], "fast projection")
		live_none := JsonParse(KLR_BuildTodayIdxJson(db, []))
		_KLRAppSelection_AssertOnlyUnknown(live_none, "live JSON projection")

		subset := KLR_ReadNgrams(db, today, today, ["selected.exe"])
		AssertTrue(subset["c"].Has("selected-token"))
		AssertTrue(subset["c"].Has("unknown-token"))
		AssertFalse(subset["c"].Has("other-token"),
			"subset must not collapse into all-app selection")
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keylogger reader: all, none, and subset app selections stay distinct (AHK-27)",
	_KLRAppSelection_AllNoneSubsetStayDistinct)
