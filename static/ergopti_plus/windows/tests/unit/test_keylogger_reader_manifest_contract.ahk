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

; Synthetic callback reset cannot erase accepted session timeout authority.
_KLRManifest_AbandonmentStart(Kind, Duration := unset, Commit := 0) {
	AssertEqual("session_start", Kind)
	Commit.Call()
	return true
}

_KLRManifest_Abandonment(Scenario, Consumer := "") {
	HookSaved := Map()
	for Name in ["prev_app", "prev_title", "app_entered_at", "title_entered_at", "context_at", "suspend_tick", "last_tick"]
		HookSaved[Name] := KLHook.%Name%
	WatchSaved := Map()
	for Name in ["is_session_active", "session_started_at", "session_generation", "idle_generation", "last_authorized_tick", "is_idle", "session_close", "session_close_draining", "privacy_interrupted", "privacy_started_at"]
		WatchSaved[Name] := KLWatch.%Name%
	KeyloggerSaved := Map()
	for Name in ["initialized", "session_app", "session_title", "synth_active", "synth_type", "synth_private", "buffer_events", "buffer_text"]
		KeyloggerSaved[Name] := Keylogger.%Name%
	FocusSaved := MetricsFocusCache.state
	FilterSaved := Map()
	for Name in ["disabled_apps", "private_browsing", "secure_field", "system_auth"]
		FilterSaved[Name] := MetricsFilters.%Name%
	Db := 0
	try {
		AssertFalse(A_IsSuspended, "the recording fixture cannot inherit suspension")
		Keylogger.initialized := true
		Keylogger.synth_active := false
		Keylogger.synth_private := false
		Keylogger.buffer_events := []
		Keylogger.buffer_text := ""
		KLHook.prev_app := ""
		KLHook.prev_title := ""
		KLHook.last_tick := 0
		KLWatch.is_session_active := false
		KLWatch.is_idle := false
		KLWatch.session_close := false
		KLWatch.session_close_draining := false
		KLWatch.privacy_interrupted := false
		KLWatch.privacy_started_at := 0
		KLWatch.last_authorized_tick := 0
		MetricsFocusCache.state := {valid: true, last_at: A_TickCount, hwnd: 1,
			process_name: "owned-synthetic-editor.exe", title: "Owned synthetic fixture",
			class: "OwnedSyntheticFixture", failure_reason: "", timed_out: false}
		MetricsFilters.disabled_apps := Map()
		for Name in ["private_browsing", "secure_field", "system_auth"]
			MetricsFilters.%Name% := false
		AssertTrue(KL_Hook_RefreshContext(true), "actual cached-focus owner publishes a native nonzero origin")
		AssertTrue(KLHook.app_entered_at > 0)
		Sleep(20)
		Sample := A_TickCount
		AssertTrue(Sample > KLWatchConst.SESSION_TIMEOUT_MS + 100,
			"the passive fixture needs legal positive past native ticks")
		Accepted := (Consumer != "" && Scenario = "expired") || Scenario = "inactive-retained"
			? Sample - KLWatchConst.SESSION_TIMEOUT_MS - 100 : Sample
		if Scenario != "inactive" {
			AssertTrue(KL_Watchers_OnKeystroke(_KLRManifest_AbandonmentStart, Accepted))
			AssertTrue(KLWatch.is_session_active)
			AssertEqual(Accepted, KLWatch.last_authorized_tick)
			if Scenario = "inactive-retained"
				_KL_Watchers_CommitSessionEnd()
		}
		KLHook.last_tick := Sample
		Keylogger.synth_active := 1
		Keylogger.synth_type := "hotstring"
		KL_Hook_OnChar(0, "x")
		AssertEqual(0, KLHook.last_tick, "the actual synthetic callback clears physical timing")
		AssertEqual("x", Keylogger.buffer_text, "privacy admission must actually reach the reset")
		AssertEqual(1, Keylogger.buffer_events.Length)
		AssertEqual(1, Keylogger.buffer_events[1][3]["s"])
		AssertEqual(Scenario = "inactive" ? 0 : Accepted, KLWatch.last_authorized_tick,
			"synthetic input cannot replace accepted session timing")
		Keylogger.synth_active := false
		Today := A_YYYY . "-" . A_MM . "-" . A_DD
		Carry := 73
		if Consumer != "" {
			Db := _KLRManifest_OpenFixture()
			AssertTrue(SQLite_Exec(Db, "INSERT INTO agg_app_day (device_id,date,app,app_time_ms) VALUES ('owned-synthetic',"
				. SQLite_Q(Today) . ",'owned-synthetic-editor.exe'," . Carry . ");"))
			Before := A_TickCount
			Index := Map()
			if Consumer = "encoded"
				Manifest := JsonParse(KLR_BuildManifestJson(Db, Today, Today, &Index))
			else
				Manifest := KLR_ReadManifest(Db, Today, Today)
			After := A_TickCount
			Cell := Manifest[Today]["owned-synthetic-editor.exe"]
			if Scenario = "expired"
				AssertEqual(Carry, Cell["app_time_ms"], "abandoned foreground cannot increase actual stored carry")
			else {
				AssertTrue(Cell["app_time_ms"] >= Carry + Before - KLHook.app_entered_at)
				AssertTrue(Cell["app_time_ms"] <= Carry + After - KLHook.app_entered_at)
			}
			AssertEqual(1, Manifest.Count)
			AssertEqual(1, Manifest[Today].Count)
			if Consumer = "encoded" {
				AssertEqual(1, Index.Count)
				AssertTrue(Index[Today].Has("owned-synthetic-editor.exe"))
			}
		} else {
			Now := Accepted + KLWatchConst.SESSION_TIMEOUT_MS
			Expected := false
			switch Scenario {
				case "before":
					Now -= 1
					Expected := true
				case "after":
					Now += 1
				case "exact":
				case "inactive":
					Expected := true
				case "inactive-retained":
					Now := Sample
					AssertFalse(KLWatch.is_session_active)
					Expected := true
				case "physical-recent":
					KL_Hook_NoteActivity(false, false, Now - 10)
					AssertTrue(KLWatch.privacy_interrupted)
					Expected := true
				case "physical-expired":
					KL_Hook_NoteActivity(false, false, Accepted - 10)
				case "empty-app":
					KLHook.prev_app := ""
					Now := Sample + 1
				case "zero-origin":
					KLHook.app_entered_at := 0
					Now := Sample + 1
				default:
					throw Error("Unknown synthetic abandonment fixture: " . Scenario)
			}
			Manifest := Map()
			Cell := KLR_GetCell(Manifest, Today, "owned-synthetic-editor.exe")
			Cell["app_time_ms"] := Carry
			Physical := KLHook.last_tick
			KLR_AddLiveForegroundTime(Manifest, Today, Today, Now)
			AssertEqual(Carry + (Expected ? Now - KLHook.app_entered_at : 0), Cell["app_time_ms"],
				"only a retained live interval can increase persisted carry")
			AssertEqual(Physical, KLHook.last_tick, "projection cannot change physical timing authority")
			AssertEqual(1, Manifest.Count)
			AssertEqual(1, Manifest[Today].Count, "invalid context cannot invent another app cell")
		}
	} finally {
		if Db
			SQLite_Close(Db)
		for Name, Value in HookSaved
			KLHook.%Name% := Value
		for Name, Value in WatchSaved
			KLWatch.%Name% := Value
		for Name, Value in KeyloggerSaved
			Keylogger.%Name% := Value
		MetricsFocusCache.state := FocusSaved
		for Name, Value in FilterSaved
			MetricsFilters.%Name% := Value
	}
}
for _KLRManifest_AbandonmentScenario in ["before", "exact", "after", "inactive", "inactive-retained", "physical-recent",
	"physical-expired", "empty-app", "zero-origin"]
	Test("Keylogger synthetic abandonment: " . _KLRManifest_AbandonmentScenario . " (klr-synthetic-abandonment)",
		_KLRManifest_Abandonment.Bind(_KLRManifest_AbandonmentScenario))
for _KLRManifest_AbandonmentConsumer in ["Map", "encoded"] {
	for _KLRManifest_AbandonmentLive in ["expired", "recent"]
		Test("Keylogger synthetic abandonment: actual " . _KLRManifest_AbandonmentConsumer . " "
			. _KLRManifest_AbandonmentLive . " (klr-synthetic-abandonment)",
			_KLRManifest_Abandonment.Bind(_KLRManifest_AbandonmentLive, _KLRManifest_AbandonmentConsumer))
}

; Native origins retain their complete elapsed span and abandonment authority.
_KLRManifest_Native64(Scenario, Consumer := "projection") {
	HookSaved := Map()
	for Name in ["prev_app", "prev_title", "app_entered_at", "title_entered_at", "context_at", "suspend_tick", "last_tick"]
		HookSaved[Name] := KLHook.%Name%
	WatchSaved := Map()
	for Name in ["is_session_active", "session_started_at", "session_generation", "idle_generation", "last_authorized_tick", "is_idle", "session_close", "session_close_draining", "privacy_interrupted", "privacy_started_at"]
		WatchSaved[Name] := KLWatch.%Name%
	KeyloggerSaved := Map()
	for Name in ["initialized", "session_app", "session_title", "synth_active", "synth_type", "synth_private", "buffer_events", "buffer_text"]
		KeyloggerSaved[Name] := Keylogger.%Name%
	FocusSaved := MetricsFocusCache.state
	FilterSaved := Map()
	for Name in ["disabled_apps", "private_browsing", "secure_field", "system_auth"]
		FilterSaved[Name] := MetricsFilters.%Name%
	Db := 0
	try {
		AssertFalse(A_IsSuspended, "the passive clock fixture must not inherit suspension")
		Keylogger.initialized := true
		Keylogger.synth_active := false
		Keylogger.synth_private := false
		Keylogger.buffer_events := []
		Keylogger.buffer_text := ""
		KLHook.prev_app := ""
		KLHook.prev_title := ""
		KLHook.last_tick := 0
		KLWatch.is_session_active := false
		KLWatch.is_idle := false
		KLWatch.session_close := false
		KLWatch.session_close_draining := false
		KLWatch.privacy_interrupted := false
		KLWatch.privacy_started_at := 0
		KLWatch.last_authorized_tick := 0
		MetricsFocusCache.state := {valid: true, last_at: A_TickCount, hwnd: 1,
			process_name: "owned-native64-editor.exe", title: "Owned native64 fixture",
			class: "OwnedNative64Fixture", failure_reason: "", timed_out: false}
		MetricsFilters.disabled_apps := Map()
		for Name in ["private_browsing", "secure_field", "system_auth"]
			MetricsFilters.%Name% := false
		BeforePublish := A_TickCount
		AssertTrue(KL_Hook_RefreshContext(true), "actual cached-focus publication must establish an app origin")
		Origin := KLHook.app_entered_at
		AssertTrue(BeforePublish <= Origin && Origin <= A_TickCount && Origin > 0,
			"foreground origin is an untruncated native clock publication")
		AssertTrue(KL_Watchers_OnKeystroke(_KLRManifest_AbandonmentStart, Origin),
			"actual accepted-session append and commit must publish timing")
		AssertTrue(KLWatch.is_session_active)
		AssertEqual(Origin, KLWatch.last_authorized_tick)
		KLHook.last_tick := Origin
		Keylogger.synth_active := 1
		Keylogger.synth_type := "hotstring"
		KL_Hook_OnChar(0, "x")
		AssertEqual(0, KLHook.last_tick, "the actual synthetic reset keeps only accepted authority")
		AssertEqual("x", Keylogger.buffer_text, "the reset is reachable after actual privacy admission")
		AssertEqual(1, Keylogger.buffer_events.Length)
		AssertEqual(1, Keylogger.buffer_events[1][3]["s"])
		Keylogger.synth_active := false
		Timeout := KLWatchConst.SESSION_TIMEOUT_MS
		Offset := 0
		if InStr(Scenario, "before")
			Offset := -1
		else if InStr(Scenario, "after")
			Offset := 1
		Long := InStr(Scenario, "long") > 0
		Span := (Long ? 0x100000000 : 0) + Timeout + Offset
		ExpectedElapsed := 0
		if InStr(Scenario, "app-") {
			Span := 0x100000000 + (Scenario == "app-exact" ? 0 : 17)
			Now := Origin + Span
			; The shortcut owner already drove the watcher; this call publishes its physical tick only.
			KL_Hook_NoteActivity(true, true, Now - 10)
			ExpectedElapsed := Span
		} else {
			Now := Origin + Span
			if Scenario == "physical-recent-long" {
				KL_Hook_NoteActivity(true, true, Now - 10)
				ExpectedElapsed := Span
			} else if InStr(Scenario, "physical-") {
				KL_Hook_NoteActivity(true, true, Origin)
				if !Long && Offset == -1
					ExpectedElapsed := Span
			}
			else if Scenario == "inactive-long" {
				_KL_Watchers_CommitSessionEnd()
				ExpectedElapsed := Span
			} else if !Long && Offset == -1
				ExpectedElapsed := Span
		}
		if Scenario == "empty-app-long" {
			KLHook.prev_app := ""
			ExpectedElapsed := 0
		} else if Scenario == "zero-origin-long" {
			KLHook.app_entered_at := 0
			ExpectedElapsed := 0
		}
		AssertTrue(Now >= Origin, "all injected observations are legal nondecreasing native64 ticks")
		Today := A_YYYY . "-" . A_MM . "-" . A_DD
		Carry := 73
		Physical := KLHook.last_tick
		Accepted := KLWatch.last_authorized_tick
		if Consumer == "projection" {
			Manifest := Map()
			KLR_GetCell(Manifest, Today, "owned-native64-editor.exe")["app_time_ms"] := Carry
			KLR_AddLiveForegroundTime(Manifest, Today, Today, Now)
		} else {
			Db := _KLRManifest_OpenFixture()
			AssertTrue(SQLite_Exec(Db, "INSERT INTO agg_app_day (device_id,date,app,app_time_ms) VALUES ('owned-native64',"
				. SQLite_Q(Today) . ",'owned-native64-editor.exe'," . Carry . ");"))
			Index := Map()
			if Consumer == "encoded"
				Manifest := JsonParse(KLR_BuildManifestJson(Db, Today, Today, &Index, Now))
			else
				Manifest := KLR_ReadManifest(Db, Today, Today, Now)
			if Consumer == "encoded" {
				AssertEqual(1, Index.Count)
				AssertTrue(Index[Today].Has("owned-native64-editor.exe"))
			}
			Stored := SQLite_Query(Db, "SELECT app_time_ms FROM agg_app_day WHERE device_id='owned-native64'")
			AssertEqual(Carry, Stored[1]["app_time_ms"], "projection cannot rewrite persisted SQLite carry")
		}
		AssertEqual(Carry + ExpectedElapsed, Manifest[Today]["owned-native64-editor.exe"]["app_time_ms"],
			"the actual consumer retains full native duration and refuses every expired interval")
		AssertEqual(1, Manifest.Count)
		AssertEqual(1, Manifest[Today].Count, "only the selected date and app may receive foreground projection")
		AssertEqual(Physical, KLHook.last_tick, "projection cannot mutate physical authority")
		AssertEqual(Accepted, KLWatch.last_authorized_tick, "projection cannot mutate accepted authority")
	} finally {
		if Db
			SQLite_Close(Db)
		for Name, Value in HookSaved
			KLHook.%Name% := Value
		for Name, Value in WatchSaved
			KLWatch.%Name% := Value
		for Name, Value in KeyloggerSaved
			Keylogger.%Name% := Value
		MetricsFocusCache.state := FocusSaved
		for Name, Value in FilterSaved
			MetricsFilters.%Name% := Value
	}
}
for _KLRManifest_Native64Scenario in ["app-exact", "app-after", "accepted-before", "accepted-exact", "accepted-after",
	"accepted-before-long", "accepted-exact-long", "accepted-after-long", "physical-before", "physical-exact",
	"physical-after", "physical-before-long", "physical-exact-long", "physical-after-long", "physical-recent-long",
	"inactive-long", "empty-app-long", "zero-origin-long"]
	Test("Keylogger native64 foreground: " . _KLRManifest_Native64Scenario . " (klr-live-native64)",
		_KLRManifest_Native64.Bind(_KLRManifest_Native64Scenario))
for _KLRManifest_Native64Consumer in ["Map", "encoded"] {
	for _KLRManifest_Native64ConsumerScenario in ["app-exact", "app-after", "accepted-before-long", "physical-before-long", "accepted-before", "accepted-exact"]
		Test("Keylogger native64 actual " . _KLRManifest_Native64Consumer . ": " . _KLRManifest_Native64ConsumerScenario . " (klr-live-native64)",
			_KLRManifest_Native64.Bind(_KLRManifest_Native64ConsumerScenario, _KLRManifest_Native64Consumer))
}

; A final native clock must follow unique captures from actual executable code.
_KLRManifest_SnapshotSourceMatch(Code, Pattern, Description) {
	Count := 0
	Position := 1
	while RegExMatch(Code, Pattern, &Found, Position) {
		Count += 1
		Match := Found
		Position := Found.Pos + Found.Len
	}
	AssertEqual(1, Count, "one executable source owner is required for " . Description)
	return Match
}

_KLRManifest_AssertSnapshotOrder(Body) {
	Body := _DriverMaskNonCode(&Body)
	Assert(Trim(Body) != "", "the live foreground owner must exist for the ordering guard")
	Identifier := "([A-Za-z_][A-Za-z_0-9]*)"
	Assignment := "im)^[ \t]*" . Identifier . "[ \t]*:=[ \t]*"
	Tail := "[ \t]*$"
	App := _KLRManifest_SnapshotSourceMatch(Body, Assignment . "KLHook\.prev_app" . Tail, "application capture")
	Origin := _KLRManifest_SnapshotSourceMatch(Body, Assignment . "KLHook\.app_entered_at" . Tail, "foreground origin capture")
	Physical := _KLRManifest_SnapshotSourceMatch(Body, Assignment . "KLHook\.last_tick" . Tail, "physical activity capture")
	Accepted := _KLRManifest_SnapshotSourceMatch(Body, Assignment . "KLWatch\.last_authorized_tick" . Tail, "accepted activity capture")
	Date := _KLRManifest_SnapshotSourceMatch(Body, Assignment . "A_YYYY\b[^\r\n]*$", "date capture")
	Clock := _KLRManifest_SnapshotSourceMatch(Body, Assignment . "IsSet\(" . Identifier . "\)[ \t]*\?[ \t]*"
		. Identifier . "[ \t]*:[ \t]*A_TickCount" . Tail, "final clock observation")
	AssertEqual(StrLower(Physical[1]), StrLower(Accepted[1]), "both activity authorities resolve into the same local snapshot")
	AssertEqual(StrLower(Clock[2]), StrLower(Clock[3]), "the explicit clock parameter must be the tested value")
	for Capture in [App, Origin, Physical, Accepted, Date]
		Assert(Capture.Pos < Clock.Pos, "every publication capture must precede the final clock")
	AfterClock := SubStr(Body, Clock.Pos)
	AssertFalse(RegExMatch(AfterClock, "i)\b(?:KLHook|KLWatch)\b"),
		"post-clock projection must not read mutable hook or accepted publication")
	Elapsed := _KLRManifest_SnapshotSourceMatch(Body, Assignment . "TickElapsed64\([ \t]*" . Origin[1]
		. "[ \t]*,[ \t]*" . Clock[1] . "[ \t]*\)" . Tail, "captured foreground elapsed assignment")
	Cell := _KLRManifest_SnapshotSourceMatch(Body, Assignment . "KLR_GetCell\([ \t]*manifest[ \t]*,[ \t]*"
		. Date[1] . "[ \t]*,[ \t]*" . App[1] . "[ \t]*\)" . Tail, "captured application cell assignment")
	_KLRManifest_SnapshotSourceMatch(Body, "i)\bTickElapsed64\([ \t]*" . Physical[1] . "[ \t]*,[ \t]*"
		. Clock[1] . "[ \t]*\)", "captured abandonment duration")
	Assert(Elapsed.Pos > Clock.Pos && Cell.Pos > Elapsed.Pos,
		"elapsed and cell decisions must follow the final clock")
	Names := Map()
	for CapturedValue in [App, Origin, Physical, Date, Clock, Elapsed, Cell] {
		Name := StrLower(CapturedValue[1])
		AssertFalse(Names.Has(Name), "each captured value requires a distinct local identity")
		Names[Name] := true
		Pattern := "im)^[ \t]*" . Name . "[ \t]*:="
		Count := 0
		Position := 1
		while RegExMatch(Body, Pattern, &Found, Position) {
			Count += 1
			Position := Found.Pos + Found.Len
		}
		AssertEqual(Name == StrLower(Physical[1]) ? 2 : 1, Count,
			"captured values cannot gain another executable assignment: " . Name)
	}
}

_KLRManifest_SnapshotOrder() {
	_KLRManifest_AssertSnapshotOrder(_DriverFuncBody("KLR_AddLiveForegroundTime"))
}
Test("Keylogger native64 projection: final clock follows publication snapshot (klr-live-snapshot-order)",
	_KLRManifest_SnapshotOrder)

_KLRManifest_SnapshotOrderMutations() {
	Body := _DriverFuncBody("KLR_AddLiveForegroundTime")
	_KLRManifest_AssertSnapshotOrder(Body)
	ClockLine := "now := IsSet(Now) ? Now : A_TickCount"
	WithoutClock := StrReplace(Body, ClockLine, "", false, &ClockCount)
	AssertEqual(1, ClockCount, "the final observation has one source owner")
	AssertThrows(() => _KLRManifest_AssertSnapshotOrder(ClockLine . "`n" . WithoutClock),
		"moving the final clock before captures must fail")
	for LateRead in ["KLHook.prev_app", "KLHook.app_entered_at", "KLHook.last_tick", "KLWatch.last_authorized_tick"]
		_KLRManifest_AssertSnapshotRefusal(Body . "`nChanged := " . LateRead,
			"a later mutable publication read must fail: " . LateRead)
	for CaptureLine in ["App := KLHook.prev_app", "AppEnteredAt := KLHook.app_entered_at", "LastActivity := KLHook.last_tick",
		"LastActivity := KLWatch.last_authorized_tick", "date_str := A_YYYY", ClockLine,
		"elapsed := TickElapsed64(AppEnteredAt, now)", "cell := KLR_GetCell(manifest, date_str, App)"] {
		_KLRManifest_AssertSnapshotRefusal(Body . "`n" . CaptureLine,
			"duplicated executable source ownership must fail: " . CaptureLine)
	}
	for CaptureLine in ["App := KLHook.prev_app", "AppEnteredAt := KLHook.app_entered_at", "LastActivity := KLHook.last_tick",
		"LastActivity := KLWatch.last_authorized_tick", ClockLine,
		"elapsed := TickElapsed64(AppEnteredAt, now)", "cell := KLR_GetCell(manifest, date_str, App)"] {
		for Spoof in ["; " . CaptureLine, "Ignored := '" . CaptureLine . "'", "/*`n" . CaptureLine . "`n*/",
			"Ignored := 1 `; " . CaptureLine] {
			Spoofed := StrReplace(Body, CaptureLine, Spoof, false, &RemovedCount)
			AssertEqual(1, RemovedCount, "the spoof control must replace an existing assignment at its original position")
			AssertThrows(() => _KLRManifest_AssertSnapshotOrder(Spoofed),
				"comment or literal content cannot replace missing executable ownership")
		}
	}
	Prose := "; " . ClockLine . "`nIgnored := 'App := KLHook.prev_app'`n"
		. "/*`nLastActivity := KLWatch.last_authorized_tick`n*/`n"
	_KLRManifest_AssertSnapshotOrder(Prose . Body . " `; KLHook.app_entered_at")
	InlineProse := StrReplace(Body, ClockLine, ClockLine . " `; KLHook.app_entered_at", false)
	_KLRManifest_AssertSnapshotOrder(InlineProse)
	Renamed := RegExReplace(Body, "i)\bAppEnteredAt\b", "OwnedOrigin")
	Renamed := RegExReplace(Renamed, "i)\bApp\b", "OwnedApp")
	_KLRManifest_AssertSnapshotOrder(Renamed)
	AssertThrows(() => _KLRManifest_AssertSnapshotOrder(Body . "`nApp := 'rebound'"),
		"another assignment cannot replace captured application identity")
	AssertThrows(() => _KLRManifest_AssertSnapshotOrder(""), "an absent owner must never satisfy a negative guard")
}
Test("Keylogger native64 projection: snapshot source guards reject changed order (klr-live-snapshot-order)",
	_KLRManifest_SnapshotOrderMutations)

; Materialize loop values before checking the guard. An unset loop closure
; must never count as the expected source-policy assertion failure.
_KLRManifest_AssertSnapshotRefusal(Changed, Message) {
	Refused := false
	try _KLRManifest_AssertSnapshotOrder(Changed)
	catch as Failure {
		AssertEqual("Error", Type(Failure), "snapshot refusal must come from its source assertion")
		Refused := true
	}
	AssertTrue(Refused, Message)
}
