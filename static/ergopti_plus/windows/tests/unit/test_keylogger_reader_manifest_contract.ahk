; tests/unit/test_keylogger_reader_manifest_contract.ahk

; ==============================================================================
; MODULE: Keylogger Reader Manifest Contract Tests
; DESCRIPTION:
; Builds a two-device manifest with the production SQLite schema and verifies
; that every structured metric is numerically merged into the shared canonical
; payload consumed by the Typing and Apps WebViews.
; ==============================================================================

_KLRManifest_OpenFixture(LoadSchema := unset) {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the real SQLite DLL must stay loaded for the manifest fixture lifetime")
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the manifest contract fixture must open an in-memory DB")
	try {
		Loader := IsSet(LoadSchema) ? LoadSchema : KLR_LoadSchema
		AssertTrue(Loader.Call(db),
			"the manifest contract fixture must use the canonical production schema")

		date := "2025-05-01"
		app := "editor.exe"
		sql := "INSERT INTO agg_app_day_burst VALUES ("
			. SQLite_Q("device-a") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. ",2,100,10," . SQLite_Q('{"short":2,"medium":1}') . ",4,100,3000);"
			. "INSERT INTO agg_app_day_burst VALUES ("
			. SQLite_Q("device-b") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. ",3,200,8," . SQLite_Q('{"short":1,"long":4}') . ",6,200,6000);"
			. "INSERT INTO agg_app_day_session VALUES ("
			. SQLite_Q("device-a") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. ",2,1000,10,1500," . SQLite_Q('[500,1000]') . ");"
			. "INSERT INTO agg_app_day_session VALUES ("
			. SQLite_Q("device-b") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. ",2,2000,20,2500," . SQLite_Q('[750,2000]') . ");"
			. "INSERT INTO agg_app_day_kc_hold VALUES ("
			. SQLite_Q("device-a") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. ",16,300,2,200,1,1);"
			. "INSERT INTO agg_app_day_kc_hold VALUES ("
			. SQLite_Q("device-b") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. ",16,700,3,400,2,1);"
			. "INSERT INTO agg_app_day_hourly VALUES ("
			. SQLite_Q("device-a") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. "," . SQLite_Q("09") . ",10,2,1,1," . SQLite_Q('{"250":1,"500":2}') . ");"
			. "INSERT INTO agg_app_day_hourly VALUES ("
			. SQLite_Q("device-b") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. "," . SQLite_Q("09") . ",20,3,2,1," . SQLite_Q('{"250":3,"1000":4}') . ");"
			. "INSERT INTO agg_app_day_hourly_min5 VALUES ("
			. SQLite_Q("device-a") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. "," . SQLite_Q("09:00") . ",6,1,1," . SQLite_Q('{"250":1}') . ");"
			. "INSERT INTO agg_app_day_hourly_min5 VALUES ("
			. SQLite_Q("device-b") . "," . SQLite_Q(date) . "," . SQLite_Q(app)
			. "," . SQLite_Q("09:00") . ",9,2,1," . SQLite_Q('{"250":2,"500":3}') . ");"
		AssertTrue(SQLite_Exec(db, sql),
			"the manifest fixture must persist complementary rows for both devices")
		return db
	} catch as Failure {
		SQLite_Close(db)
		throw Failure
	}
}

_KLRManifest_AssertContractKeys(app_entry, contract) {
	app_contract := contract["app_entry"]
	for field_name in ["burst_length_buckets", "session_durations", "hourly",
		"hourly_min5", "kc_hold"]
		AssertTrue(app_entry.Has(field_name),
			"the reader must publish canonical field " . field_name)

	hold := app_entry["kc_hold"]["16"]
	for field_name, _ in app_contract["kc_hold"]["item_fields"]
		AssertTrue(hold.Has(field_name),
			"modifier hold rows must publish canonical field " . field_name)

	for _, forbidden in contract["forbidden_transport_fields"] {
		AssertFalse(app_entry.Has(forbidden),
			"transport-only field must not escape the reader: " . forbidden)
		AssertFalse(app_entry["hourly"]["09"].Has(forbidden),
			"hour rows must not escape transport-only field: " . forbidden)
		AssertFalse(app_entry["hourly_min5"]["09:00"].Has(forbidden),
			"five-minute rows must not escape transport-only field: " . forbidden)
	}
}

_KLRManifest_TwoDevicesMergeCanonicalPayload() {
	global _SharedDir
	db := _KLRManifest_OpenFixture()
	try {
		manifest := KLR_ReadManifest(db, "2025-05-01", "2025-05-01")
		app := manifest["2025-05-01"]["editor.exe"]
		contract := JsonParse(FileRead(
			_SharedDir . "\data\metrics_manifest_contract.json", "UTF-8"))
		_KLRManifest_AssertContractKeys(app, contract)

		AssertEqual(5, app["burst_count_total"])
		AssertEqual(200, app["burst_max_cpm"])
		AssertEqual(10, app["burst_max_chars"])
		AssertEqual(10, app["burst_inter_delay_count"])
		AssertEqual(300, app["burst_inter_delay_sum"])
		AssertEqual(9000, app["burst_inter_delay_sumsq"])
		AssertEqual(3, app["burst_length_buckets"]["short"])
		AssertEqual(1, app["burst_length_buckets"]["medium"])
		AssertEqual(4, app["burst_length_buckets"]["long"])

		AssertEqual(4, app["session_count_total"])
		AssertEqual(2000, app["session_longest_ms"])
		AssertEqual(20, app["session_longest_chars"])
		AssertEqual(4000, app["session_total_active_ms"])
		AssertEqual(4, app["session_durations"].Length)
		duration_counts := Map()
		for _, duration in app["session_durations"]
			KLR_BumpMap(duration_counts, String(duration), 1)
		for duration in [500, 750, 1000, 2000]
			AssertEqual(1, duration_counts[String(duration)],
				"every device's session duration must reach the canonical array")

		hold := app["kc_hold"]["16"]
		AssertEqual(1000, hold["s"])
		AssertEqual(5, hold["n"])
		AssertEqual(400, hold["m"])
		AssertEqual(3, hold["tap"])
		AssertEqual(2, hold["hold"])

		hour := app["hourly"]["09"]
		AssertEqual(30, hour["c"])
		AssertEqual(5, hour["e"])
		AssertEqual(3, hour["em"])
		AssertEqual(2, hour["es"])
		AssertEqual(4, hour["e_buckets"]["250"])
		AssertEqual(2, hour["e_buckets"]["500"])
		AssertEqual(4, hour["e_buckets"]["1000"])

		minute := app["hourly_min5"]["09:00"]
		AssertEqual(15, minute["c"])
		AssertEqual(3, minute["e"])
		AssertEqual(2, minute["es"])
		AssertEqual(3, minute["e_buckets"]["250"])
		AssertEqual(3, minute["e_buckets"]["500"])
	} finally {
		try SQLite_Close(db)
	}
}
Test("Keylogger reader: two devices merge the canonical manifest payload (manifest-payload-contract)",
	_KLRManifest_TwoDevicesMergeCanonicalPayload)

_KLRManifest_IdenticalDeviceHistograms(Kind) {
	db := _KLRManifest_OpenFixture()
	try {
		Tables := Map("burst", ["agg_app_day_burst", "length_buckets_json"],
			"hourly", ["agg_app_day_hourly", "e_buckets_json"],
			"minute", ["agg_app_day_hourly_min5", "e_buckets_json"])
		Spec := Tables[Kind]
		AssertTrue(SQLite_Exec(db, "UPDATE " . Spec[1] . " SET " . Spec[2]
			. "=(SELECT " . Spec[2] . " FROM " . Spec[1] . " WHERE device_id='device-a')"
			. " WHERE device_id='device-b';"))
		App := KLR_ReadManifest(db, "2025-05-01", "2025-05-01")["2025-05-01"]["editor.exe"]
		if Kind = "burst" {
			AssertEqual(5, App["burst_count_total"], "scalar totals must still sum both devices")
			AssertEqual(4, App["burst_length_buckets"]["short"], "identical histograms still represent two devices")
			AssertEqual(2, App["burst_length_buckets"]["medium"])
		} else if Kind = "hourly" {
			AssertEqual(30, App["hourly"]["09"]["c"])
			AssertEqual(2, App["hourly"]["09"]["e_buckets"]["250"], "identical hourly buckets must retain multiplicity")
			AssertEqual(4, App["hourly"]["09"]["e_buckets"]["500"])
		} else {
			AssertEqual(15, App["hourly_min5"]["09:00"]["c"])
			AssertEqual(2, App["hourly_min5"]["09:00"]["e_buckets"]["250"], "identical five-minute buckets must retain multiplicity")
		}
	} finally {
		SQLite_Close(db)
	}
}
for Kind in ["burst", "hourly", "minute"]
	Test("Keylogger reader: identical device histograms " . Kind . " (manifest-identical-histograms)",
		_KLRManifest_IdenticalDeviceHistograms.Bind(Kind))

_KLRManifest_LiveDateBounds(Scenario) {
	SavedApp := KLHook.prev_app
	SavedEntered := KLHook.app_entered_at
	SavedTick := KLHook.last_tick
	try {
		Today := A_YYYY . "-" . A_MM . "-" . A_DD
		Before := A_TickCount
		AssertTrue(Before > 75, "the passive date fixture needs a nonzero context origin")
		KLHook.prev_app := "owned-date-editor.exe"
		KLHook.app_entered_at := Before - 75
		KLHook.last_tick := Before
		Manifest := Map()
		Cell := KLR_GetCell(Manifest, Today, KLHook.prev_app)
		Carry := 41
		Cell["app_time_ms"] := Carry
		Start := Scenario = "before" ? "9999-12-31" : (Scenario = "after" ? "" : Today)
		End := Scenario = "after" ? "0001-01-01" : (Scenario = "before" ? "" : Today)
		KLR_AddLiveForegroundTime(Manifest, Start, End)
		After := A_TickCount
		if Scenario = "inclusive" {
			AssertTrue(Cell["app_time_ms"] >= Carry + 75, "inclusive dates retain the observed foreground interval")
			AssertTrue(Cell["app_time_ms"] <= Carry + After - KLHook.app_entered_at)
		} else {
			AssertEqual(Carry, Cell["app_time_ms"], "a date outside the selected range must preserve stored carry")
		}
		AssertEqual(1, Manifest.Count)
		AssertEqual(1, Manifest[Today].Count)
	} finally {
		KLHook.prev_app := SavedApp
		KLHook.app_entered_at := SavedEntered
		KLHook.last_tick := SavedTick
	}
}
for _KLRManifest_LiveDateScenario in ["before", "after", "inclusive"]
	Test("Keylogger live dates: " . _KLRManifest_LiveDateScenario . " (klr-live-date-bounds)",
		_KLRManifest_LiveDateBounds.Bind(_KLRManifest_LiveDateScenario))

_KLRManifest_LiveDateConsumer(Encoded) {
	SavedApp := KLHook.prev_app
	SavedEntered := KLHook.app_entered_at
	SavedTick := KLHook.last_tick
	Db := 0
	try {
		Db := _KLRManifest_OpenFixture()
		Today := A_YYYY . "-" . A_MM . "-" . A_DD
		Carry := 73
		AssertTrue(SQLite_Exec(Db, "INSERT INTO agg_app_day (device_id,date,app,app_time_ms) VALUES ('owned-live',"
			. SQLite_Q(Today) . ",'owned-date-editor.exe'," . Carry . ");"))
		Before := A_TickCount
		AssertTrue(Before > 75, "the passive consumer fixture needs a nonzero context origin")
		KLHook.prev_app := "owned-date-editor.exe"
		KLHook.app_entered_at := Before - 75
		KLHook.last_tick := Before
		Index := Map()
		if Encoded
			Manifest := JsonParse(KLR_BuildManifestJson(Db, Today, Today, &Index))
		else
			Manifest := KLR_ReadManifest(Db, Today, Today)
		After := A_TickCount
		Cell := Manifest[Today]["owned-date-editor.exe"]
		AssertTrue(Cell["app_time_ms"] >= Carry + 75, "the actual filtered consumer retains persisted carry and live time")
		AssertTrue(Cell["app_time_ms"] <= Carry + After - KLHook.app_entered_at)
		AssertEqual(1, Manifest.Count, "the selected date excludes historical fixture rows")
		AssertEqual(1, Manifest[Today].Count, "the live foreground remains attributed to its app")
		if Encoded {
			AssertEqual(1, Index.Count)
			AssertTrue(Index[Today].Has("owned-date-editor.exe"))
		}
	} finally {
		if Db
			SQLite_Close(Db)
		KLHook.prev_app := SavedApp
		KLHook.app_entered_at := SavedEntered
		KLHook.last_tick := SavedTick
	}
}
for _KLRManifest_LiveDateEncoded in [false, true]
	Test("Keylogger live dates: actual " . (_KLRManifest_LiveDateEncoded ? "encoded" : "Map")
		. " consumer keeps carry (klr-live-date-bounds)",
		_KLRManifest_LiveDateConsumer.Bind(_KLRManifest_LiveDateEncoded))
