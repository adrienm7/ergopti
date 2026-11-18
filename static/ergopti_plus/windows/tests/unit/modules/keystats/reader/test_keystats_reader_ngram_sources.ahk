; tests/unit/modules/keystats/reader/test_keystats_reader_ngram_sources.ahk

; ==============================================================================
; MODULE: Keystats Reader N-gram Source Projection Tests
; DESCRIPTION:
; Exercises every Windows n-gram dashboard projection against the real SQLite
; schema. Source attribution is additive across device rows and must retain the
; same hs/llm/o counts in the full, range, fast, and live-JSON paths.
; ==============================================================================

_KLRSource_OpenFixture(LoadSchema := unset) {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the real SQLite DLL must stay loaded for the fixture DB lifetime")

	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the n-gram source fixture must open an in-memory DB")
	try {
		Loader := IsSet(LoadSchema) ? LoadSchema : KLR_LoadSchema
		AssertTrue(Loader.Call(db),
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
	} catch as Failure {
		SQLite_Close(db)
		throw Failure
	}
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
Test("Keystats reader: every n-gram source projection sums device rows (ngram-source-projection)",
	_KLRSource_AllDashboardPathsAgree)

_KLRSource_FutureRangeAfterClockRollback() {
	db := _KLRSource_OpenFixture()
	try {
		for date, count in Map("2026-10-24", 2, "2026-10-25", 5, "2026-10-26", 3) {
			sql := "INSERT INTO ngram_chars (device_id,date,app,token,c,td,cd,e,esrc_json) VALUES ("
				. SQLite_Q("device-a") . "," . SQLite_Q(date) . "," . SQLite_Q("editor.exe") . ","
				. SQLite_Q("rollback-only") . "," . count . ",0,0,0," . SQLite_Q('{}') . ");"
			AssertTrue(SQLite_Exec(db, sql), "the fixture must persist all three day buckets")
		}
		apps := ["editor.exe"]
		split := KLR_ReadRangeSplitToday(db, "2026-10-24", "2026-10-26", apps, "2026-10-25")
		AssertEqual(5, split["historical"]["c"]["rollback-only"]["c"], "past and explicitly requested future days must be combined")
		AssertEqual(5, split["today"]["editor.exe"]["c"]["rollback-only"]["c"], "the snapshot day must appear only in today")
		encoded := JsonParse(KLR_BuildRangeSplitTodayJson(db, "2026-10-24", "2026-10-26", apps, "2026-10-25"))
		AssertEqual(5, encoded["historical"]["c"]["rollback-only"]["c"], "JSON range must preserve both non-today dates")
		AssertEqual(5, encoded["today"]["editor.exe"]["c"]["rollback-only"]["c"], "JSON range must not double-count the snapshot day")
		future := JsonParse(KLR_BuildRangeSplitTodayJson(db, "2026-10-26", "2026-10-26", apps, "2026-10-25"))
		AssertEqual(3, future["historical"]["c"]["rollback-only"]["c"], "a future-only selection must not include the past")
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keystats reader: range preserves a future-dated bucket after clock rollback", _KLRSource_FutureRangeAfterClockRollback)

_KLRAppFilter_OpenFixture(LoadSchema := unset) {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the app-filter fixture must keep the real SQLite DLL loaded")

	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the app-filter fixture must open an in-memory DB")
	try {
		Loader := IsSet(LoadSchema) ? LoadSchema : KLR_LoadSchema
		AssertTrue(Loader.Call(db),
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
	} catch as Failure {
		SQLite_Close(db)
		throw Failure
	}
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
Test("Keystats reader: app filters retain Unknown in every projection (AHK-26)",
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
Test("Keystats reader: all, none, and subset app selections stay distinct (AHK-27)",
	_KLRAppSelection_AllNoneSubsetStayDistinct)

; The vendored SQLite cuts a json_group_object key at an embedded NUL, so the
; token "a\u0000b" came back as a second "a" key beside the real one and the
; page kept whichever arrived last. Every SQL-built reader object is checked:
; the historical index and the complete and live today indexes.
_KLRNul_Keys(Db, Json, Path) {
	Rows := SQLite_Query(Db, "SELECT json_valid(" . SQLite_Q(Json) . ") AS valid,"
		. " (SELECT group_concat(h, ',') FROM (SELECT hex(key) || '|' || json_extract(value, '$.c') AS h"
		. " FROM json_each(" . SQLite_Q(Json) . ", " . SQLite_Q(Path) . ") ORDER BY hex(key))) AS keys")
	AssertEqual(1, Rows[1]["valid"], "the reader must emit valid JSON")
	return Rows[1]["keys"]
}

_KLRNul_TokenKeysStayDistinct() {
	db := _KLRSource_OpenFixture()
	try {
		today := FormatTime(A_Now, "yyyy-MM-dd")
		yesterday := KLR_PrevDay(today)
		Sql := ""
		for Day in [today, yesterday]
			for Spec in [["ngram_chars", "a" . Chr(0) . "b", 1], ["ngram_chars", "a", 10],
					["ngram_shortcuts", "x" . Chr(0) . "y", 2], ["ngram_shortcuts", "x", 20]]
				Sql .= "INSERT INTO " . Spec[1] . " (device_id,date,app,token,c) VALUES ('nul',"
					. SQLite_Q(Day) . ",'nul.exe'," . SQLite_Q(Spec[2]) . "," . Spec[3] . ");"
		AssertTrue(SQLite_Exec(db, Sql), "the NUL-key fixture must load")
		Expected := Map("c", "61|10,610062|1", "sc", "78|20,780079|2")
		History := KLR_BuildNgramsJson(db, yesterday, yesterday, ["nul.exe"])
		for Code, Keys in Expected
			AssertEqual(Keys, _KLRNul_Keys(db, History, "$." . Code),
				"historical " . Code . ": a NUL token must stay beside its prefix")
		for Complete in [true, false] {
			TodayJson := KLR_BuildTodayIdxJson(db, ["nul.exe"], Complete, today)
			for Code, Keys in Expected
				AssertEqual(Keys, _KLRNul_Keys(db, TodayJson, '$."nul.exe".' . Code),
					"today " . Code . " (complete=" . Complete . "): a NUL token must stay beside its prefix")
		}
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keystats reader: a NUL token stays a distinct JSON key (windows-reader-nul-json-keys)",
	_KLRNul_TokenKeysStayDistinct)

; Ergopti Studio's keys typed count only the keystrokes typed on the keyboard:
; the shared fixture's shared-token (6 typed, 5 hotstring, 1 AI) and
; other-token (2 typed, 2 synthetic) contribute nothing, a manual row counts in
; full, and a token of another family never leaks in. Its final text (schema 2)
; counts every source.
_KLRSource_StudioCountsPhysicalKeystrokes() {
	db := _KLRSource_OpenFixture()
	try {
		today := FormatTime(A_Now, "yyyy-MM-dd")
		AssertTrue(SQLite_Exec(db, "INSERT INTO ngram_chars (device_id,date,app,token,c,esrc_json) VALUES ("
			. SQLite_Q("device-a") . "," . SQLite_Q(today) . "," . SQLite_Q("other.exe") . ","
			. SQLite_Q("e") . ",7," . SQLite_Q("{}") . ");"
			. "INSERT INTO ngram_bigrams (device_id,date,app,token,c,esrc_json) VALUES ("
			. SQLite_Q("device-b") . "," . SQLite_Q(today) . "," . SQLite_Q("other.exe") . ","
			. SQLite_Q("es") . ",3," . SQLite_Q('{"llm":1}') . ");"
			. "INSERT INTO ngram_words (device_id,date,app,token,c,esrc_json) VALUES ("
			. SQLite_Q("device-a") . "," . SQLite_Q(today) . "," . SQLite_Q("other.exe") . ","
			. SQLite_Q("est") . ",4," . SQLite_Q("{}") . ");"))
		Contract := KLR_StudioContract()
		Json := KLR_BuildStudioNgramsJson(db, Contract)
		Payload := JsonParse(Json)
		AssertEqual(Contract["schema"], Payload["schema"])
		AssertEqual("keystats", Payload["source"])
		AssertEqual(1, Payload["chars"].Count, "synthetic-only tokens are not keystrokes: " . Json)
		AssertEqual(7, Payload["chars"]["e"])
		AssertEqual(2, Payload["bigrams"]["es"], "the AI share of a bigram is subtracted")
		AssertEqual(0, Payload["trigrams"].Count, "a word is not a trigram")
		AssertEqual(7, Payload["total"])
		; The final text (schema 2): every source counted, the same families.
		Final := Payload[Contract["final_field"]]
		AssertEqual(3, Final["chars"].Count, "the final text keeps the synthetic tokens: " . Json)
		AssertEqual(6, Final["chars"]["shared-token"], "a hotstring and AI token counts in full")
		AssertEqual(2, Final["chars"]["other-token"])
		AssertEqual(7, Final["chars"]["e"])
		AssertEqual(3, Final["bigrams"]["es"], "the AI share of a bigram is kept")
		AssertEqual(0, Final["trigrams"].Count, "a word is not a trigram in the final text either")
		AssertEqual(15, Final["total"])
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keystats reader: Ergopti Studio reads the keys typed and the final text of three families (studio-keystats-bridge)",
	_KLRSource_StudioCountsPhysicalKeystrokes)

; The Ergopti Studio window answers keystats_ngrams: an absent keystats folder
; and a failed worker read are refusals, a finished read pushes the staged JSON
; as is, and the worker is the only reader of the store.
_KLRSource_StudioWindowAnswers() {
	global _LayEdWin_StudioCache
	_LayEdWin_StudioCache := 0
	Contract := KLR_StudioContract()
	Pushed := []
	Requests := []
	Dir := A_Temp . "\ergopti_studio_test_" . A_TickCount
	DirCreate(Dir)
	try {
		Outcome := Map("status", "ok", "stage", Dir . "\stage.json")
		FileAppend('{"schema":1,"chars":{"e":7}}', Outcome["stage"], "UTF-8-RAW")
		Stamp := Map("value", "rev-1")
		Deps := Map(
			"metrics_dir", Dir . "\absent",
			"stamp", (MetricsDir) => Stamp["value"],
			"request_studio", (MetricsDir, OnTerminal) => (Requests.Push(MetricsDir),
				OnTerminal.Call(Outcome["status"], Outcome["stage"]), true),
			"push_raw", (Name, Json) => (Pushed.Push(Name . " " . Json), true),
			"read_stage", FSRead,
			"read_snapshot", KLR_StudioSnapshotRead,
			"write_snapshot", KLR_StudioSnapshotWrite,
			"purge_generation", () => 0)
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "keystats_ngrams"), Deps))
		AssertEqual('keystatsNgrams {"ok":false,"code":"' . Contract["codes"]["absent"] . '"}', Pushed[1])
		AssertEqual(0, Requests.Length, "an absent store starts no worker")
		Deps["metrics_dir"] := Dir
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "keystats_ngrams"), Deps))
		AssertEqual('keystatsNgrams {"ok":true,"ngrams":{"schema":1,"chars":{"e":7}}}', Pushed[2])
		AssertEqual(Dir, Requests[1])
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "keystats_ngrams"), Deps))
		AssertEqual(Pushed[2], Pushed[3], "an unchanged store answers from the cached projection")
		AssertEqual(1, Requests.Length, "an unchanged store starts no second worker")
		Stamp["value"] := "rev-2"
		Outcome["status"] := "failed", Outcome["stage"] := ""
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "keystats_ngrams"), Deps))
		AssertEqual(Pushed[2], Pushed[4], "a changed store shows the saved read first")
		AssertEqual('keystatsNgrams {"ok":false,"code":"' . Contract["codes"]["unreadable"] . '"}', Pushed[5])
		AssertEqual(2, Requests.Length, "a changed store is read again")
		AssertTrue(LAYOUT_EDITOR_WINDOW_ACTIONS.Has("keystats_ngrams"), "the page's action is allowlisted")
	} finally {
		_LayEdWin_StudioCache := 0
		DirDelete(Dir, true)
	}
}
Test("Layout editor window: Ergopti Studio answers keystats_ngrams with the worker's read (studio-keystats-bridge)",
	_KLRSource_StudioWindowAnswers)

; A Studio window ports around a real keystats folder; the worker's terminal is
; held in Terminals until the test ends the read.
_KLRSource_StudioSnapshotDeps(Dir, Stamp, Pushed, Terminals, Generation) {
	return Map(
		"metrics_dir", Dir,
		"stamp", (MetricsDir) => Stamp["value"],
		"request_studio", (MetricsDir, OnTerminal) => (Terminals.Push(OnTerminal), true),
		"push_raw", (Name, Json) => (Pushed.Push(Name . " " . Json), true),
		"read_stage", FSRead,
		"read_snapshot", KLR_StudioSnapshotRead,
		"write_snapshot", KLR_StudioSnapshotWrite,
		"purge_generation", () => Generation["value"])
}

; (studio-saved-read-first) After a restart the resident has no projection in
; memory: the read saved by the last window is pushed at once, before the
; worker starts, then the worker's fresh read replaces it and is saved in turn.
_KLRSource_StudioSavedReadFirst() {
	global _LayEdWin_StudioCache
	_LayEdWin_StudioCache := 0
	Dir := A_Temp . "\ergopti_studio_saved_" . A_TickCount
	DirCreate(Dir . "\by_device\pc")
	try {
		FileAppend("-- ledger", Dir . "\by_device\pc\data.sql", "UTF-8-RAW")
		AssertTrue(KLR_StudioSnapshotWrite(Dir, "rev-old", '{"schema":1,"chars":{"a":1}}'))
		Stamp := Map("value", "rev-new")
		Pushed := [], Terminals := []
		Deps := _KLRSource_StudioSnapshotDeps(Dir, Stamp, Pushed, Terminals, Map("value", 0))
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "keystats_ngrams"), Deps))
		AssertEqual(1, Pushed.Length, "the saved read is pushed before the worker ends")
		AssertEqual('keystatsNgrams {"ok":true,"ngrams":{"schema":1,"chars":{"a":1}}}', Pushed[1])
		AssertEqual(1, Terminals.Length, "a changed store still starts the worker")
		FileAppend('{"schema":1,"chars":{"a":2}}', Dir . "\stage.json", "UTF-8-RAW")
		Terminals[1].Call("ok", Dir . "\stage.json")
		AssertEqual('keystatsNgrams {"ok":true,"ngrams":{"schema":1,"chars":{"a":2}}}', Pushed[2],
			"the fresh read follows")
		Saved := KLR_StudioSnapshotRead(Dir)
		AssertEqual("rev-new", Saved["stamp"], "the fresh read is saved with its stamp")
		AssertEqual('{"schema":1,"chars":{"a":2}}', Saved["json"])
		; A restart on the unchanged store: the saved read is the answer, no worker.
		_LayEdWin_StudioCache := 0
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "keystats_ngrams"), Deps))
		AssertEqual(Pushed[2], Pushed[3])
		AssertEqual(3, Pushed.Length)
		AssertEqual(1, Terminals.Length, "a saved read of the unchanged store starts no worker")
	} finally {
		_LayEdWin_StudioCache := 0
		DirDelete(Dir, true)
	}
}
Test("Layout editor window: Ergopti Studio shows its saved read at once, then the fresh one (studio-saved-read-first)",
	_KLRSource_StudioSavedReadFirst)

; The saved read's file and header come from the shared contract (snapshot),
; not from a name this driver types.
_KLRSource_StudioSavedReadFollowsContract() {
	Snapshot := KLR_StudioContract()["snapshot"]
	Dir := A_Temp . "\ergopti_studio_contract_" . A_TickCount
	DirCreate(Dir . "\cache")
	try {
		Path := KLR_StudioSnapshotPath(Dir)
		AssertEqual(Snapshot["file"], SubStr(Path, StrLen(Path) - StrLen(Snapshot["file"]) + 1),
			"the saved read is the file the contract names")
		AssertTrue(KLR_StudioSnapshotWrite(Dir, "rev-9", '{"schema":1}'))
		Text := FileRead(Path, "UTF-8")
		AssertEqual(Snapshot["format"] . " rev-9`n", SubStr(Text, 1, InStr(Text, "`n")),
			"its header line is the contract's format, then the store stamp")
	} finally {
		DirDelete(Dir, true)
	}
}
Test("keystats ngrams: the saved Studio read follows the shared contract", _KLRSource_StudioSavedReadFollowsContract)

; A saved read that is not in its format is logged and ignored: the worker reads
; the store, and its read replaces the file.
_KLRSource_StudioBrokenSavedRead() {
	global _LayEdWin_StudioCache
	_LayEdWin_StudioCache := 0
	Dir := A_Temp . "\ergopti_studio_broken_" . A_TickCount
	DirCreate(Dir . "\cache")
	try {
		FileAppend('{"schema":1}', KLR_StudioSnapshotPath(Dir), "UTF-8-RAW")
		AssertThrows(() => KLR_StudioSnapshotRead(Dir), "a file without its header is refused")
		Pushed := [], Terminals := []
		Deps := _KLRSource_StudioSnapshotDeps(Dir, Map("value", "rev-1"), Pushed, Terminals, Map("value", 0))
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "keystats_ngrams"), Deps))
		AssertEqual(0, Pushed.Length, "a broken saved read is not shown")
		AssertEqual(1, Terminals.Length)
		FileAppend('{"schema":1,"chars":{"b":3}}', Dir . "\stage.json", "UTF-8-RAW")
		Terminals[1].Call("ok", Dir . "\stage.json")
		AssertEqual('{"schema":1,"chars":{"b":3}}', KLR_StudioSnapshotRead(Dir)["json"])
		AssertTrue(KLR_StudioSnapshotRetire(Dir), "the saved read can be retired")
		AssertEqual(0, KLR_StudioSnapshotRead(Dir), "no saved read is left")
		AssertTrue(KLR_StudioSnapshotRetire(Dir), "retiring an absent read succeeds")
	} finally {
		_LayEdWin_StudioCache := 0
		DirDelete(Dir, true)
	}
}
Test("Keystats reader: a saved Ergopti Studio read out of its format is ignored and replaced (studio-saved-read-first)",
	_KLRSource_StudioBrokenSavedRead)

; (studio-saved-read-purge) A metrics purge that overlapped the worker's read:
; that read may hold what the purge deleted, so it is neither pushed nor saved,
; and the store is read again.
_KLRSource_StudioPurgeOverlap() {
	global _LayEdWin_StudioCache
	_LayEdWin_StudioCache := 0
	Dir := A_Temp . "\ergopti_studio_purge_" . A_TickCount
	DirCreate(Dir . "\by_device\pc")
	try {
		FileAppend("-- ledger", Dir . "\by_device\pc\data.sql", "UTF-8-RAW")
		Generation := Map("value", 4)
		Pushed := [], Terminals := []
		Deps := _KLRSource_StudioSnapshotDeps(Dir, Map("value", "rev-1"), Pushed, Terminals, Generation)
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "keystats_ngrams"), Deps))
		FileAppend('{"schema":1,"chars":{"p":9}}', Dir . "\stage.json", "UTF-8-RAW")
		Generation["value"] := 6
		Terminals[1].Call("ok", Dir . "\stage.json")
		AssertEqual(0, Pushed.Length, "the overlapped read is not shown")
		AssertEqual(0, KLR_StudioSnapshotRead(Dir), "nor saved")
		AssertEqual(2, Terminals.Length, "the store is read again")
		Terminals[2].Call("ok", Dir . "\stage.json")
		AssertEqual(1, Pushed.Length, "a read after the purge is shown")
		AssertEqual("rev-1", KLR_StudioSnapshotRead(Dir)["stamp"], "and saved")
	} finally {
		_LayEdWin_StudioCache := 0
		DirDelete(Dir, true)
	}
}
Test("Layout editor window: a Studio read that overlapped a metrics purge is read again (studio-saved-read-purge)",
	_KLRSource_StudioPurgeOverlap)

; The purge and the dashboard's cache reset retire the saved Studio read, and
; the purge bumps its generation on both ends (KL_RunMetricsMaintenance needs
; the live writer, so its order is pinned on the source).
_KLRSource_StudioPurgeRetiresSavedRead() {
	Body := _DriverFuncBody("KL_RunMetricsMaintenance")
	Assert(Body != "", "KL_RunMetricsMaintenance must be found")
	Tombstone := InStr(Body, "the tombstone is not in the replayed ledger")
	Retire := InStr(Body, "KLR_StudioSnapshotRetire(MetricsDir)")
	Assert(Tombstone > 0 && Retire > Tombstone, "the purge retires the saved read once its tombstone is replayed")
	First := InStr(Body, "KLMaintenance.purge_generation += 1")
	Assert(First > 0 && First < Tombstone, "the purge bumps the generation before its tombstone")
	Assert(InStr(Body, "KLMaintenance.purge_generation += 1", , First + 1) > Retire,
		"and again when it ends")
	Reset := _DriverFuncBody("KLWV_OnWebMessage")
	Assert(Reset != "", "KLWV_OnWebMessage must be found")
	Assert(InStr(Reset, 'KLR_StudioSnapshotRetire(entry["metrics_dir"])') > InStr(Reset, 'KLR_CacheRetire(entry["metrics_dir"])'),
		"the dashboard's cache reset retires the saved read with the reader image")
}
Test("Keystats maintenance: a purge and a cache reset retire the saved Studio read (studio-saved-read-purge)",
	_KLRSource_StudioPurgeRetiresSavedRead)

; The Studio stamp changes when a keystats file grows and stays put otherwise.
_KLRSource_StudioStampFollowsTheStore() {
	Dir := A_Temp . "\ergopti_studio_stamp_" . A_TickCount
	DirCreate(Dir . "\device")
	try {
		AssertEqual("", KLR_StudioStoreStamp(Dir), "an empty folder has no stamp")
		FileAppend("a", Dir . "\device\data.sql", "UTF-8-RAW")
		First := KLR_StudioStoreStamp(Dir)
		Assert(First != "", "a folder with a journal has a stamp")
		AssertEqual(First, KLR_StudioStoreStamp(Dir), "an unchanged folder keeps its stamp")
		; The cache folder holds derived projections only: the worker's reader
		; image and the saved Studio read must not make the read look stale.
		DirCreate(Dir . "\cache")
		FileAppend("image", Dir . "\cache\reader.sqlite", "UTF-8-RAW")
		AssertTrue(KLR_StudioSnapshotWrite(Dir, First, '{"schema":1}'))
		AssertEqual(First, KLR_StudioStoreStamp(Dir), "the cache folder is not part of the stamp")
		; Loop Files normalizes a full path (8.3 names such as a CI runner's
		; RUNNER~1, separators): the cache stays out however the folder is spelled.
		Spelled := StrReplace(Dir, "\", "/")
		AssertEqual(KLR_StudioStoreStamp(Spelled), KLR_StudioStoreStamp(Spelled . "/"),
			"the stamp does not depend on a trailing separator")
		Bare := KLR_StudioStoreStamp(Spelled)
		FileAppend("more", Dir . "\cache\reader.sqlite", "UTF-8-RAW")
		AssertEqual(Bare, KLR_StudioStoreStamp(Spelled),
			"the cache folder is not part of the stamp of a folder spelled otherwise")
		FileAppend("b", Dir . "\device\data.sql", "UTF-8-RAW")
		Assert(KLR_StudioStoreStamp(Dir) != First, "a grown journal changes the stamp")
	} finally {
		DirDelete(Dir, true)
	}
}
Test("Keystats reader: the Ergopti Studio stamp follows the keystats files (studio-keystats-bridge)",
	_KLRSource_StudioStampFollowsTheStore)

; The Studio window opens its analysis panels' « i » links in the system
; browser, and only an https URL.
_KLRSource_StudioOpensHttpsLinks() {
	Opened := []
	Deps := Map("open_url", (Url) => (Opened.Push(Url), true))
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "open_link", "url", "https://ergopti.fr/studio"), Deps))
	AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "open_link", "url", "http://example.org"), Deps))
	AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "open_link", "url", "https://a b"), Deps))
	AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "open_link"), Deps))
	AssertEqual(1, Opened.Length, "only the https link is opened")
	AssertEqual("https://ergopti.fr/studio", Opened[1])
}
Test("Layout editor window: Ergopti Studio opens only https links (studio-open-link)",
	_KLRSource_StudioOpensHttpsLinks)

; The analysis panels mounted in the Studio read their layout_analysis.* keys,
; and its optimizer tab its layout_optimizer.* keys, from the strings the
; Windows host sends with sourceData, like the editor's.
_KLRSource_StudioSendsAnalysisStrings() {
	global _I18nCache
	_I18nEnsureLoaded()
	AssertFalse(_I18nCache.Has("layout_analysis.studio_probe"), "the probe key is the test's own")
	AssertFalse(_I18nCache.Has("layout_optimizer.studio_probe"), "the optimizer probe is the test's own")
	_I18nCache["layout_analysis.studio_probe"] := "Probe"
	_I18nCache["layout_optimizer.studio_probe"] := "Probe"
	try {
		Strings := LayoutManager_EditorStrings()
		AssertTrue(Strings.Has("layout_analysis.studio_probe"), "the analysis keys reach the Studio page")
		AssertTrue(Strings.Has("layout_optimizer.studio_probe"), "the optimizer keys reach the Studio page")
		AssertTrue(Strings.Has("layout_editor.title"), "the editor keys still do")
		for Key in Strings
			Assert(SubStr(Key, 1, 14) == "layout_editor." || SubStr(Key, 1, 16) == "layout_analysis."
				|| SubStr(Key, 1, 17) == "layout_optimizer.",
				"only the editor's, the analysis panels' and the optimizer's keys are sent: " . Key)
	} finally {
		_I18nCache.Delete("layout_analysis.studio_probe")
		_I18nCache.Delete("layout_optimizer.studio_probe")
	}
}
Test("Layout editor window: the Studio page receives the analysis panels' strings (studio-analysis-strings)",
	_KLRSource_StudioSendsAnalysisStrings)

; The Studio window answers the Comparer's store with the page's request numbers.
_KLRSource_StudioLayoutMessages() {
	Files := Map()
	Pushed := []
	Deps := Map("config_dir", "C:\cfg\",
		"studio_ports", Map("exists", (Path) => Files.Has(Path),
			"read", (Path, MaxBytes) => Files.Has(Path) ? Files[Path] : false,
			"write", (Path, Text) => (Files[Path] := Text, true)),
		"push", (Name, Payload) => (Pushed.Push(Name . " " . _LayMgrWeb_Json(Payload)), true))
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_layout_save", "request", 3,
		"id", "user_a", "text", '{"id":"user_a"}'), Deps))
	AssertContains(Pushed[1], 'studioLayoutResult {')
	AssertContains(Pushed[1], '"request":3')
	AssertContains(Pushed[1], '"ok":true')
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_layouts", "request", 4), Deps))
	AssertContains(Pushed[2], 'studioLayouts {')
	AssertContains(Pushed[2], '"layouts":["{\"id\":\"user_a\"}"]')
	AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "studio_layouts"), Deps), "a request number is required")
}
Test("Layout editor window: Ergopti Studio keeps the Comparer's personal layouts (studio-layout-store)",
	_KLRSource_StudioLayoutMessages)

; The Studio window runs the chosen corpus's generated tables, then answers.
_KLRSource_StudioCorpusMessages() {
	Script := 'var LAYOUT_ANALYSIS_CORPORA = {};'
	Files := Map("C:\shared\ui\layout_analysis\_generated\corpus_fr_swann.js", Script)
	Events := []
	Deps := Map("shared_dir", "C:\shared",
		"studio_ports", Map("exists", (Path) => Files.Has(Path),
			"read", (Path, MaxBytes) => Files.Has(Path) ? Files[Path] : false),
		"run_script", (Text) => (Events.Push("run " . Text), true),
		"push", (Name, Payload) => (Events.Push(Name . " " . _LayMgrWeb_Json(Payload)), true))
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_corpus", "request", 5, "id", "fr_swann"), Deps))
	AssertEqual(2, Events.Length)
	AssertEqual("run " . Script, Events[1], "the tables run as shipped, before the answer")
	AssertContains(Events[2], 'studioCorpus {')
	AssertContains(Events[2], '"request":5')
	AssertContains(Events[2], '"ok":true')
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_corpus", "request", 6, "id", "../x"), Deps))
	AssertEqual(3, Events.Length, "a refused id runs nothing")
	AssertContains(Events[3], '"ok":false')
	AssertContains(Events[3], '"code":"studio_corpus_unavailable"')
	AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "studio_corpus", "id", "fr_swann"), Deps),
		"a request number is required")
}
Test("Layout editor window: Ergopti Studio runs a built-in corpus's tables on request (studio-corpus-tables)",
	_KLRSource_StudioCorpusMessages)

; The Studio window keeps the Comparer's fingering profile with the page's request numbers.
_KLRSource_StudioProfileMessages() {
	Files := Map()
	Pushed := []
	Deps := Map("config_dir", "C:\cfg\",
		"studio_ports", Map("exists", (Path) => Files.Has(Path),
			"read", (Path, MaxBytes) => Files.Has(Path) ? Files[Path] : false,
			"write", (Path, Text) => (Files[Path] := Text, true)),
		"push", (Name, Payload) => (Pushed.Push(Name . " " . _LayMgrWeb_Json(Payload)), true))
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_profile_save", "request", 2,
		"text", '{"id":"mine"}'), Deps))
	AssertContains(Pushed[1], 'studioProfileResult {')
	AssertContains(Pushed[1], '"ok":true')
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_profile_load", "request", 3), Deps))
	AssertContains(Pushed[2], 'studioProfile {')
	AssertContains(Pushed[2], '"profile":"{\"id\":\"mine\"}"')
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_profile_save", "request", 4, "reset", true), Deps))
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_profile_load", "request", 5), Deps))
	AssertFalse(InStr(Pushed[4], '"profile"'), "reset restores the defaults")
	AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "studio_profile_load"), Deps), "a request number is required")
}
Test("Layout editor window: Ergopti Studio keeps the Comparer's fingering profile (studio-fingering-profile)",
	_KLRSource_StudioProfileMessages)

; The Studio window keeps the editor's workspace (its tabs) with the page's request numbers.
_KLRSource_StudioWorkspaceMessages() {
	Files := Map()
	Pushed := []
	Deps := Map("config_dir", "C:\cfg\",
		"studio_ports", Map("exists", (Path) => Files.Has(Path),
			"read", (Path, MaxBytes) => Files.Has(Path) ? Files[Path] : false,
			"write", (Path, Text) => (Files[Path] := Text, true)),
		"push", (Name, Payload) => (Pushed.Push(Name . " " . _LayMgrWeb_Json(Payload)), true))
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_workspace_load", "request", 2), Deps))
	AssertContains(Pushed[1], 'studioWorkspace {')
	AssertFalse(InStr(Pushed[1], '"workspace"'), "nothing saved yet is an empty workspace")
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_workspace_save", "request", 3,
		"text", '{"tabs":[]}'), Deps))
	AssertContains(Pushed[2], 'studioWorkspaceResult {')
	AssertContains(Pushed[2], '"ok":true')
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_workspace_load", "request", 4), Deps))
	AssertContains(Pushed[3], '"workspace":"{\"tabs\":[]}"')
	AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "studio_workspace_save", "request", 5,
		"reset", true), Deps))
	AssertContains(Pushed[4], '"code":"studio_invalid_layout"', "the page never clears the workspace")
	AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "studio_workspace_load"), Deps), "a request number is required")
}
Test("Layout editor window: Ergopti Studio keeps the editor's tabs (studio-editor-workspace)",
	_KLRSource_StudioWorkspaceMessages)

; The export step host's ports, with every effect recorded: the staged input,
; the spawned command, the timer and the pushed answers.
_KLRSource_LuaExportDeps(VendorDir, Log) {
	Log["pushed"] := [], Log["inputs"] := Map(), Log["removed"] := [], Log["spawned"] := 0, Log["timer"] := 0
	Log["terminated"] := false, Log["start_ok"] := true
	WriteInput(Text) {
		Path := VendorDir . "\input_" . (Log["inputs"].Count + 1) . ".json"
		Log["inputs"][Path] := Text
		return Path
	}
	Spawn(Exe, Args, OnDone) {
		Log["spawned"] := Map("exe", Exe, "args", Args, "done", OnDone)
		Handle := {}
		Handle.start := (*) => Log["start_ok"]
		Handle.terminate := (*) => (Log["terminated"] := true)
		return Handle
	}
	return Map(
		"push", (Name, Payload) => (Log["pushed"].Push(Name . " " . _LayMgrWeb_Json(Payload)), true),
		"vendor_dir", VendorDir,
		"shared_dir", "C:\shared",
		"export_settings", () => Map("timeout_ms", 30000, "failure", "target_export_refused"),
		"write_input", WriteInput,
		"remove_input", (Path) => Log["removed"].Push(Path),
		"spawn", Spawn,
		"after", (Ms, Fn) => (Log["timer"] := Map("ms", Ms, "fn", Fn)))
}

; Writes a stand-in host executable and the identity naming its digest.
_KLRSource_LuaExportVendor(Dir, Digest := "") {
	FileAppend("MZ stand-in host", Dir . "\ergopti_lua_export.exe", "UTF-8-RAW")
	if (Digest == "")
		Digest := CryptoSha256Bytes(FSReadBytesStrict(Dir . "\ergopti_lua_export.exe"))
	FileAppend('{"schema_version":1,"exe_sha256":"' . Digest . '"}', Dir . "\ergopti_lua_export.json", "UTF-8-RAW")
}

; Without its identity, or with an executable that does not match it, the
; host is not offered and refuses lua_export without running anything.
_KLRSource_LuaExportRefused() {
	Dir := A_Temp . "\ergopti_lua_export_test_" . A_TickCount
	DirCreate(Dir)
	try {
		Log := Map()
		Deps := _KLRSource_LuaExportDeps(Dir, Log)
		Message := Map("action", "lua_export", "request", 1, "step", "xkb", "input", "{}")
		AssertFalse(LayoutEditorWindow_LuaExportHost(Dir) is Map, "no identity: no host")
		AssertFalse(LayoutEditorWindow_HandleMessage(Message, Deps), "no identity: lua_export is refused")
		_KLRSource_LuaExportVendor(Dir, Format("{:064}", 0))
		AssertContains(LayoutEditorWindow_LuaExportHost(Dir), "does not match its identity")
		AssertFalse(LayoutEditorWindow_HandleMessage(Message, Deps), "a mismatched executable is refused")
		AssertEqual(0, Log["pushed"].Length, "nothing is pushed for a refused export step")
		AssertEqual(0, Log["spawned"], "nothing is run for a refused export step")
		AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "lua_export", "step", "xkb", "input", "{}"), Deps),
			"a request number is required")
	} finally {
		DirDelete(Dir, true)
	}
}
Test("Layout editor window: without a matching export step host, lua_export is refused (lua-export-host)",
	_KLRSource_LuaExportRefused)

; A matching host runs the step on a staged input and answers luaExportResult:
; its output, its refusal line, a timeout, or a host that does not start.
_KLRSource_LuaExportRuns() {
	Dir := A_Temp . "\ergopti_lua_export_run_" . A_TickCount
	DirCreate(Dir)
	try {
		_KLRSource_LuaExportVendor(Dir)
		AssertTrue(LayoutEditorWindow_LuaExportHost(Dir) is Map, "a matching executable is offered")
		Log := Map()
		Deps := _KLRSource_LuaExportDeps(Dir, Log)
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "lua_export", "request", 7, "step", "xkb",
			"input", '{"a":1}'), Deps))
		Spawned := Log["spawned"]
		AssertEqual(Dir . "\ergopti_lua_export.exe", Spawned["exe"])
		AssertEqual("C:\shared", Spawned["args"][1])
		AssertEqual("xkb", Spawned["args"][2])
		AssertEqual('{"a":1}', Log["inputs"][Spawned["args"][3]], "the input is staged as given")
		AssertEqual(30000, Log["timer"]["ms"], "the step is bounded by the defaults' timeout")
		Spawned["done"].Call(0, '{"symbols":"x"}', "")
		AssertEqual(1, Log["pushed"].Length)
		AssertContains(Log["pushed"][1], 'luaExportResult {')
		AssertContains(Log["pushed"][1], '"ok":true')
		AssertContains(Log["pushed"][1], '"request":7')
		AssertContains(Log["pushed"][1], '"output":"{\"symbols\":\"x\"}"')
		AssertEqual(Spawned["args"][3], Log["removed"][1], "the staged input is removed")
		Log["timer"]["fn"].Call()
		AssertEqual(1, Log["pushed"].Length, "a step that ended answers once")

		; The host's refusal line names its code and detail.
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "lua_export", "request", 8, "step", "read",
			"input", "[1]"), Deps))
		Log["spawned"]["done"].Call(1, "target_export_refused`tthe export step's input is not a JSON object`n", "")
		AssertContains(Log["pushed"][2], '"ok":false')
		AssertContains(Log["pushed"][2], '"code":"target_export_refused"')
		AssertContains(Log["pushed"][2], "is not a JSON object")

		; A step past its timeout is stopped and refused once.
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "lua_export", "request", 9, "step", "xkb",
			"input", "{}"), Deps))
		Log["timer"]["fn"].Call()
		AssertTrue(Log["terminated"], "the late host is stopped")
		AssertContains(Log["pushed"][3], '"code":"target_export_refused"')
		AssertContains(Log["pushed"][3], "did not end in time")
		Log["spawned"]["done"].Call(0, "{}", "")
		AssertEqual(3, Log["pushed"].Length, "a stopped step answers once")

		; A host that does not start is refused at once, its input removed.
		Log["start_ok"] := false
		Removed := Log["removed"].Length
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "lua_export", "request", 10, "step", "xkb",
			"input", "{}"), Deps))
		AssertContains(Log["pushed"][4], "could not be started")
		AssertEqual(Removed + 1, Log["removed"].Length)
	} finally {
		DirDelete(Dir, true)
	}
}
Test("Layout editor window: a matching export step host runs lua_export, bounded (lua-export-run)",
	_KLRSource_LuaExportRuns)
