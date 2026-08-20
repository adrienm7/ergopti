; tests/unit/test_keylogger_reader_manifest_contract.ahk

; ==============================================================================
; MODULE: Keylogger Reader Manifest Contract Tests
; DESCRIPTION:
; Builds a two-device manifest with the production SQLite schema and verifies
; that every structured metric is numerically merged into the shared canonical
; payload consumed by the Typing and Apps WebViews.
; ==============================================================================

_KLRManifest_OpenFixture() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the real SQLite DLL must stay loaded for the manifest fixture lifetime")
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the manifest contract fixture must open an in-memory DB")
	AssertTrue(KLR_LoadSchema(db),
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
