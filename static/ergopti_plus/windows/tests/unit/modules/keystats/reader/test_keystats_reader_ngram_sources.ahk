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

; Ergopti Studio counts only the keystrokes typed on the keyboard: the shared
; fixture's shared-token (6 typed, 5 hotstring, 1 AI) and other-token (2 typed,
; 2 synthetic) contribute nothing, a manual row counts in full, and a token of
; another family never leaks in.
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
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keystats reader: Ergopti Studio reads the physical keystrokes of three families (studio-keystats-bridge)",
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
			"read_stage", FSRead)
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
		AssertEqual('keystatsNgrams {"ok":false,"code":"' . Contract["codes"]["unreadable"] . '"}', Pushed[4])
		AssertEqual(2, Requests.Length, "a changed store is read again")
		AssertTrue(LAYOUT_EDITOR_WINDOW_ACTIONS.Has("keystats_ngrams"), "the page's action is allowlisted")
	} finally {
		_LayEdWin_StudioCache := 0
		DirDelete(Dir, true)
	}
}
Test("Layout editor window: Ergopti Studio answers keystats_ngrams with the worker's read (studio-keystats-bridge)",
	_KLRSource_StudioWindowAnswers)

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

; The analysis panels mounted in the Studio read their layout_analysis.* keys
; from the strings the Windows host sends with sourceData, like the editor's.
_KLRSource_StudioSendsAnalysisStrings() {
	global _I18nCache
	_I18nEnsureLoaded()
	AssertFalse(_I18nCache.Has("layout_analysis.studio_probe"), "the probe key is the test's own")
	_I18nCache["layout_analysis.studio_probe"] := "Probe"
	try {
		Strings := LayoutManager_EditorStrings()
		AssertTrue(Strings.Has("layout_analysis.studio_probe"), "the analysis keys reach the Studio page")
		AssertTrue(Strings.Has("layout_editor.title"), "the editor keys still do")
		for Key in Strings
			Assert(SubStr(Key, 1, 14) == "layout_editor." || SubStr(Key, 1, 16) == "layout_analysis.",
				"only the editor's and the analysis panels' keys are sent: " . Key)
	} finally {
		_I18nCache.Delete("layout_analysis.studio_probe")
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

; The Windows host runs no Lua: it offers no lua_export and refuses the message.
_KLRSource_LuaExportRefused() {
	Pushed := []
	Deps := Map("push", (Name, Payload) => (Pushed.Push(Name), true))
	AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "lua_export", "request", 1, "step", "xkb",
		"input", "{}"), Deps), "the Windows host refuses lua_export")
	AssertEqual(0, Pushed.Length, "nothing is pushed for a refused export step")
}
Test("Layout editor window: the Windows host builds downloads in the page, not with lua_export (lua-export-host)",
	_KLRSource_LuaExportRefused)
