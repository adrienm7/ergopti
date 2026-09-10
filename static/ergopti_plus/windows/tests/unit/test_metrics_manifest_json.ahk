; tests/unit/test_metrics_manifest_json.ahk

; ==============================================================================
; MODULE: Encoded Manifest Regression Tests
; DESCRIPTION: Compare SQL-backed JSON with real-schema manifest semantics.
; ==============================================================================

#Requires AutoHotkey v2.0

_MMJ_Canonical(Value) {
	if Value is Map {
		Entries := ""
		for Key, Item in Value
			Entries .= KL_JsonEncode(String(Key)) . ":" . _MMJ_Canonical(Item) . "`n"
		return "{" . StrReplace(RTrim(Sort(Entries, "C"), "`n"), "`n", ",") . "}"
	}
	if Value is Array {
		Entries := ""
		for Item in Value
			Entries .= (Entries = "" ? "" : ",") . _MMJ_Canonical(Item)
		return "[" . Entries . "]"
	}
	return KL_JsonEncode(Value)
}

_MMJ_AssertIndex(Manifest, Index) {
	AssertTrue(Index is Map, "the membership index must be a Map")
	AssertEqual(Manifest.Count, Index.Count, "index dates must match the complete manifest")
	for Day, Apps in Manifest {
		AssertTrue(Index.Has(Day), "the index must contain every manifest date")
		AssertTrue(Index[Day] is Map, "each date must own an application membership Map")
		AssertEqual(Apps.Count, Index[Day].Count, "index apps must match the complete manifest")
		for App in Apps {
			AssertTrue(Index[Day].Has(App), "the index must contain every manifest app")
			AssertEqual("Integer", Type(Index[Day][App]), "membership must never expose partial metric cells")
			AssertEqual(true, Index[Day][App], "application membership must be exactly true")
		}
	}
}

_MMJ_Compare(Db, ExpectedErrors, StartDate := "", EndDate := "") {
	global _LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED
	SavedSink := _LOGGER_TEST_SINK
	SavedErrors := _LOGGER_ERROR_ENABLED
	Messages := []
	try {
		_LOGGER_ERROR_ENABLED := true
		LoggerSetTestSink((Line) => InStr(Line, "[ERROR] [KLReader] Invalid ") ? Messages.Push(Line) : 0)
		Expected := KLR_ReadManifest(Db, StartDate, EndDate)
		AssertEqual(ExpectedErrors, Messages.Length, "baseline malformed histogram diagnostics")
		Messages.Length := 0
		Actual := JsonParse(KLR_BuildManifestJson(Db, StartDate, EndDate, &Index))
		AssertEqual(ExpectedErrors, Messages.Length, "encoded projection must preserve malformed histogram diagnostics")
		AssertEqual(_MMJ_Canonical(Expected), _MMJ_Canonical(Actual),
			"complete metrics must equal the established reader independently of JSON property order")
		_MMJ_AssertIndex(Actual, Index)
		return Actual
	} finally {
		LoggerSetTestSink(SavedSink)
		_LOGGER_ERROR_ENABLED := SavedErrors
	}
}

_MMJ_RealSchema(Scenario) {
	SavedApp := KLHook.prev_app
	Db := 0
	try {
		; Sequential comparisons must not accrue real foreground time between readers.
		KLHook.prev_app := ""
		_KLRDC_EnsureSharedDir()
		if Scenario = "zero" {
			AssertEqual(0, _MMJ_Compare(0, 0).Count)
			return
		}
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0, "the fixture must open the real SQLite database")
		AssertTrue(KLR_LoadSchema(Db), "the fixture must load the production schema")
		if Scenario = "empty" {
			AssertEqual(0, _MMJ_Compare(Db, 0).Count)
			return
		}
		App := 'app"name'
		for Device, Histogram in ['{"5":2}', '{"5":2}', '{"5":"0x10","7":"bad","8":1.5}',
			'broken', '7', '{}', '', '{"5":-1,"9":true,"10":null}'] {
			for Spec in [["agg_app_day_hourly", "hour"], ["agg_app_day_hourly_min5", "slot"]] {
				Sql := "INSERT INTO " . Spec[1] . "(device_id,date,app," . Spec[2]
					. ",c,e,es,e_buckets_json) VALUES (" . SQLite_Q("device" . Device)
					. ",'2026-01-02'," . SQLite_Q(App) . ",3,2,1,1," . SQLite_Q(Histogram) . ")"
				AssertTrue(SQLite_Exec(Db, Sql), "every synthetic device row must be inserted")
			}
		}
		if Scenario = "excluded" {
			AssertEqual(0, _MMJ_Compare(Db, 0, "2026-01-03", "2026-01-03").Count)
			return
		}
		Manifest := Scenario = "selected" ? _MMJ_Compare(Db, 4, "2026-01-02", "2026-01-02")
			: _MMJ_Compare(Db, 4)
		AssertEqual(1, Manifest.Count, "series-only rows must create their missing day cell")
		AssertEqual(1, Manifest["2026-01-02"].Count, "escaped app names must remain one app")
		for Field in ["hourly", "hourly_min5"] {
			Item := Manifest["2026-01-02"][App][Field]["3"]
			AssertEqual(16, Item["c"], "all eight device rows contribute character counts")
			AssertEqual(8, Item["e"], "all eight device rows contribute errors")
			AssertEqual(19, Item["e_buckets"]["5"], "duplicate histograms and hexadecimal counts retain multiplicity")
			AssertEqual(0, Item["e_buckets"]["7"], "nonnumeric bucket counts remain zero")
			AssertEqual(1.5, Item["e_buckets"]["8"], "fractional bucket counts remain fractional")
		}
		if Scenario = "cache"
			_MMJ_CacheIsolation(Db, Manifest)
	} finally {
		KLHook.prev_app := SavedApp
		if Db
			SQLite_Close(Db)
	}
}

_MMJ_CacheIsolation(Db, Expected) {
	global KLPF_MANIFEST_CACHE, Features
	HadCache := IsSet(KLPF_MANIFEST_CACHE)
	SavedCache := HadCache ? KLPF_MANIFEST_CACHE : 0
	SavedFeatures := Features
	try {
		Features := Map("layout", Map("ergopti_base", false))
		Legacy := KLPF_BuildTyping(Db, "full")
		Cache := KLPF_MANIFEST_CACHE
		Before := _MMJ_Canonical(Cache)
		AssertEqual(_MMJ_Canonical(Expected), Before, "legacy projection establishes complete cached cells")
		AssertTrue(Legacy["metrics_manifest"] == Cache, "the baseline owns the complete manifest cache")
		AppsLegacy := KLPF_BuildApps(Db)
		AssertEqual(Before, _MMJ_Canonical(AppsLegacy["metrics_manifest"]), "ordinary Apps API keeps complete Maps")
		AppsEncoded := KLPF_BuildApps(Db, true)
		AssertFalse(AppsEncoded.Has("metrics_manifest"), "encoded Apps must not expose partial manifest cells")
		AssertEqual(Before, _MMJ_Canonical(JsonParse(AppsEncoded["__klpf_manifest_json"])))
		AssertEqual(0, AppsEncoded["app_icons"].Count)
		AssertTrue(KLPF_MANIFEST_CACHE == Cache, "Apps encoding must preserve the complete typing cache object")
		AssertEqual(Before, _MMJ_Canonical(Cache), "Apps encoding must not mutate the typing cache")
		for Mode in ["manifest", "live", "full"] {
			Blob := KLPF_BuildTyping(Db, Mode, false, "2026-01-02", true)
			AssertFalse(Blob.Has("metrics_manifest"), "encoded mode must not expose the membership index as metrics")
			AssertTrue(Blob.Has("__klpf_manifest_json"), "encoded mode must carry the complete raw manifest")
			AssertEqual(_MMJ_Canonical(Expected), _MMJ_Canonical(JsonParse(Blob["__klpf_manifest_json"])))
			AssertTrue(KLPF_MANIFEST_CACHE == Cache, "encoded mode must retain the complete cache object")
			AssertEqual(Before, _MMJ_Canonical(KLPF_MANIFEST_CACHE), "encoded mode must not mutate cached metric cells")
		}
	} finally {
		Features := SavedFeatures
		KLPF_MANIFEST_CACHE := HadCache ? SavedCache : unset
	}
}

Test("manifest JSON: zero handle remains empty (metrics-manifest-json)", _MMJ_RealSchema.Bind("zero"))
Test("manifest JSON: empty real schema remains empty (metrics-manifest-json)", _MMJ_RealSchema.Bind("empty"))
Test("manifest JSON: series-only devices and histogram coercion (metrics-manifest-json)", _MMJ_RealSchema.Bind("full"))
Test("manifest JSON: inclusive date selection retains diagnostics (metrics-manifest-json)", _MMJ_RealSchema.Bind("selected"))
Test("manifest JSON: excluded dates omit cells and diagnostics (metrics-manifest-json)", _MMJ_RealSchema.Bind("excluded"))
Test("manifest JSON: encoded typing modes preserve complete cache ownership (metrics-manifest-json)", _MMJ_RealSchema.Bind("cache"))

_MMJ_AppsPublication() {
	global KLPF_LAST_JSON
	Producer := _DriverFuncBody("KLPF_BuildAndWriteToPath")
	AssertTrue(Producer != "", "the publication entry must resolve")
	AssertTrue(RegExMatch(Producer, "KLPF_BuildApps\(\s*db\s*,\s*true\s*\)") > 0,
		"the production Apps path must retain the measured encoded-manifest optimization")
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	SavedBatch := KLW.batch
	SavedApp := KLHook.prev_app
	try {
		_KLRDC_EnsureSharedDir()
		_KLRDC_Reset()
		Root := _KLRDC_Root()
		App := '__klpf_manifest_json"fixture.exe'
		FileAppend(_KLRDC_TypingBatch(1, "2026-01-02 10:00:00.000", "2026-01-02", App, ["a", "b"]),
			Root . "by_device\dev-one\data.sql", "UTF-8-RAW")
		Db := _KLRDC_BuildAsWorker()
		KLHook.prev_app := ""
		Expected := _MMJ_Canonical(KLPF_BuildApps(Db))
		KLPF_LAST_JSON := Map()
		for Mode in ["full", "live", "manifest"] {
			Path := Root . "apps-" . Mode . ".json"
			AssertTrue(KLPF_BuildAndWriteToPath("apps", Root, Path, Root . "debug.log", Mode))
			Raw := FileRead(Path, "UTF-8")
			Actual := JsonParse(Raw)
			AssertEqual(Expected, _MMJ_Canonical(Actual), "Apps publication must preserve every metric in " . Mode)
			AssertFalse(Actual.Has("__klpf_manifest_json"), "internal transport fields cannot reach the page")
			AssertEqual(2, Actual["metrics_manifest"]["2026-01-02"][App]["chars"])
			AssertEqual(Raw, KLPF_LAST_JSON[KLPF_PrefetchPath("apps", Root)], "memory follows the published Apps bytes")
		}
	} finally {
		_KLRDC_Cleanup()
		KLW.batch := SavedBatch
		KLHook.prev_app := SavedApp
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
	}
}
Test("manifest JSON: Apps publication preserves payload and cache bytes (metrics-apps-encoded-manifest)",
	_KLRDC_CheckTeardown.Bind(_MMJ_AppsPublication))

_MMJ_CountNormalization(Calls, Target, Raw, Label, Multiplicity := 1) {
	Calls[Raw] := Calls.Get(Raw, 0) + 1
	return KLR_MergeJsonNumberMap(Target, Raw, Label, Multiplicity)
}

_MMJ_HistogramReuse(FiveMinute) {
	global _LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	SavedSink := _LOGGER_TEST_SINK
	SavedErrors := _LOGGER_ERROR_ENABLED
	SavedDedup := [_LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime]
	Db := _WJFM_OpenMemory()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		Table := FiveMinute ? "agg_app_day_hourly_min5" : "agg_app_day_hourly"
		Key := FiveMinute ? "slot" : "hour"
		Valid := '{"100":"3","bad":null}'
		for Bin in [1, 2, 3] {
			loop Bin + 1 {
				Sql := "INSERT INTO " . Table . " (device_id,date,app," . Key . ",e_buckets_json) VALUES ("
					. SQLite_Q("device-" . A_Index) . ",'2026-01-02','fixture.exe',"
					. SQLite_Q(String(Bin)) . "," . SQLite_Q(Valid) . ");"
				AssertTrue(SQLite_Exec(Db, Sql))
			}
		}
		for Raw in ["[]", "{broken"] {
			loop 2
				AssertTrue(SQLite_Exec(Db, "INSERT INTO " . Table
					. " (device_id,date,app," . Key . ",e_buckets_json) VALUES ('invalid','2026-01-02',"
					. SQLite_Q("invalid-" . Raw) . "," . SQLite_Q(String(A_Index)) . "," . SQLite_Q(Raw) . ");"))
		}
		Calls := Map()
		Messages := []
		_LOGGER_ERROR_ENABLED := true
		_LOGGER_DEDUP_KEY := ""
		_LOGGER_DEDUP_COUNT := 0
		LoggerSetTestSink((Line) => InStr(Line, "[ERROR] [KLReader] Invalid ") ? Messages.Push(Line) : 0)
		loop 2 {
			Result := KLR_EncodedTimeSeries(Db, FiveMinute, "", _MMJ_CountNormalization.Bind(Calls))
			Bins := JsonParse(Result["2026-01-02"]["fixture.exe"])
			for Bin in [1, 2, 3] {
				AssertEqual((Bin + 1) * 3, Bins[String(Bin)]["e_buckets"]["100"], "each bin applies its own device multiplicity")
				AssertEqual(0, Bins[String(Bin)]["e_buckets"]["bad"], "null histogram counts remain zero")
			}
			AssertEqual(A_Index * 2, Messages.Length, "the logger still emits each diagnostic kind and deduplicates its adjacent repeat")
			AssertEqual(A_Index * 2, Calls["[]"], "invalid shapes cannot be memoized")
			AssertEqual(A_Index * 2, Calls["{broken"], "malformed JSON cannot be memoized")
			AssertEqual(A_Index, Calls[Valid], "valid histogram normalization occurs once per invocation, never once per bin")
		}
	} finally {
		LoggerSetTestSink(SavedSink)
		_LOGGER_ERROR_ENABLED := SavedErrors
		_LOGGER_DEDUP_KEY := SavedDedup[1]
		_LOGGER_DEDUP_LEVEL := SavedDedup[2]
		_LOGGER_DEDUP_COUNT := SavedDedup[3]
		_LastErrTime := SavedDedup[4]
		SQLite_Close(Db)
	}
}
for FiveMinute in [false, true]
	Test("manifest JSON: histogram reuse preserves lifetime and multiplicity five-minute=" . FiveMinute
		. " (metrics-histogram-reuse)", _MMJ_HistogramReuse.Bind(FiveMinute))
