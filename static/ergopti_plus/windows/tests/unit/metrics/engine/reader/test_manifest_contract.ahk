; tests/unit/metrics/engine/reader/test_manifest_contract.ahk

; ==============================================================================
; MODULE: Keystats Reader Manifest Contract Tests
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
			_SharedDir . "\metrics\data\metrics_manifest_contract.json", "UTF-8"))
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
Test("Keystats reader: two devices merge the canonical manifest payload (manifest-payload-contract)",
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
	Test("Keystats reader: identical device histograms " . Kind . " (manifest-identical-histograms)",
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
	Test("Keystats live dates: " . _KLRManifest_LiveDateScenario . " (klr-live-date-bounds)",
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
	Test("Keystats live dates: actual " . (_KLRManifest_LiveDateEncoded ? "encoded" : "Map")
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
	for Name in ["prev_app", "prev_title", "app_entered_at", "title_entered_at", "context_at", "suspend_tick", "last_tick", "context_transition", "context_stop", "context_observations", "context_observation_head"]
		HookSaved[Name] := KLHook.%Name%
	WatchSaved := Map()
	for Name in ["is_session_active", "session_started_at", "session_generation", "idle_generation", "last_authorized_tick", "is_idle", "session_close", "session_close_draining", "privacy_interrupted", "privacy_started_at"]
		WatchSaved[Name] := KLWatch.%Name%
	KeystatsSaved := Map()
	for Name in ["initialized", "session_app", "session_title", "synth_active", "synth_type", "synth_private", "buffer_events", "buffer_text"]
		KeystatsSaved[Name] := Keystats.%Name%
	FocusSaved := MetricsFocusCache.state
	FilterSaved := Map()
	for Name in ["disabled_apps", "private_browsing", "secure_field", "system_auth"]
		FilterSaved[Name] := MetricsFilters.%Name%
	Db := 0
	try {
		AssertFalse(A_IsSuspended, "the recording fixture cannot inherit suspension")
		Keystats.initialized := true
		Keystats.synth_active := false
		Keystats.synth_private := false
		Keystats.buffer_events := []
		Keystats.buffer_text := ""
		KLHook.prev_app := ""
		KLHook.prev_title := ""
		KLHook.context_transition := false, KLHook.context_stop := false
		KLHook.context_observations := [], KLHook.context_observation_head := 1
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
		AssertTrue(Sample > 100, "the passive fixture needs legal positive native ticks")
		; Expiry is observed from a later clock, never from an origin placed
		; before the sample: A_TickCount is host uptime, and a hosted runner
		; younger than the session timeout has no such past tick.
		Accepted := Sample
		ExpiredNow := Sample + KLWatchConst.SESSION_TIMEOUT_MS + 100
		if Scenario != "inactive" {
			AssertTrue(KL_Watchers_OnKeystroke(_KLRManifest_AbandonmentStart, Accepted))
			AssertTrue(KLWatch.is_session_active)
			AssertEqual(Accepted, KLWatch.last_authorized_tick)
			if Scenario = "inactive-retained"
				_KL_Watchers_CommitSessionEnd()
		}
		KLHook.last_tick := Sample
		Keystats.synth_active := 1
		Keystats.synth_type := "hotstring"
		KL_Hook_OnChar(0, "x")
		AssertEqual(0, KLHook.last_tick, "the actual synthetic callback clears physical timing")
		AssertEqual("x", Keystats.buffer_text, "privacy admission must actually reach the reset")
		AssertEqual(1, Keystats.buffer_events.Length)
		AssertEqual(1, Keystats.buffer_events[1][3]["s"])
		AssertEqual(Scenario = "inactive" ? 0 : Accepted, KLWatch.last_authorized_tick,
			"synthetic input cannot replace accepted session timing")
		Keystats.synth_active := false
		Today := A_YYYY . "-" . A_MM . "-" . A_DD
		Carry := 73
		if Consumer != "" {
			Db := _KLRManifest_OpenFixture()
			AssertTrue(SQLite_Exec(Db, "INSERT INTO agg_app_day (device_id,date,app,app_time_ms) VALUES ('owned-synthetic',"
				. SQLite_Q(Today) . ",'owned-synthetic-editor.exe'," . Carry . ");"))
			Before := A_TickCount
			Index := Map()
			if Consumer = "encoded" && Scenario = "expired"
				Manifest := JsonParse(KLR_BuildManifestJson(Db, Today, Today, &Index, ExpiredNow))
			else if Consumer = "encoded"
				Manifest := JsonParse(KLR_BuildManifestJson(Db, Today, Today, &Index))
			else if Scenario = "expired"
				Manifest := KLR_ReadManifest(Db, Today, Today, ExpiredNow)
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
					Now := ExpiredNow
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
		for Name, Value in KeystatsSaved
			Keystats.%Name% := Value
		MetricsFocusCache.state := FocusSaved
		for Name, Value in FilterSaved
			MetricsFilters.%Name% := Value
	}
}
for _KLRManifest_AbandonmentScenario in ["before", "exact", "after", "inactive", "inactive-retained", "physical-recent",
	"physical-expired", "empty-app", "zero-origin"]
	Test("Keystats synthetic abandonment: " . _KLRManifest_AbandonmentScenario . " (klr-synthetic-abandonment)",
		_KLRManifest_Abandonment.Bind(_KLRManifest_AbandonmentScenario))
for _KLRManifest_AbandonmentConsumer in ["Map", "encoded"] {
	for _KLRManifest_AbandonmentLive in ["expired", "recent"]
		Test("Keystats synthetic abandonment: actual " . _KLRManifest_AbandonmentConsumer . " "
			. _KLRManifest_AbandonmentLive . " (klr-synthetic-abandonment)",
			_KLRManifest_Abandonment.Bind(_KLRManifest_AbandonmentLive, _KLRManifest_AbandonmentConsumer))
}

; Native origins retain their complete elapsed span and abandonment authority.
_KLRManifest_Native64(Scenario, Consumer := "projection") {
	HookSaved := Map()
	for Name in ["prev_app", "prev_title", "app_entered_at", "title_entered_at", "context_at", "suspend_tick", "last_tick", "context_transition", "context_stop", "context_observations", "context_observation_head"]
		HookSaved[Name] := KLHook.%Name%
	WatchSaved := Map()
	for Name in ["is_session_active", "session_started_at", "session_generation", "idle_generation", "last_authorized_tick", "is_idle", "session_close", "session_close_draining", "privacy_interrupted", "privacy_started_at"]
		WatchSaved[Name] := KLWatch.%Name%
	KeystatsSaved := Map()
	for Name in ["initialized", "session_app", "session_title", "synth_active", "synth_type", "synth_private", "buffer_events", "buffer_text"]
		KeystatsSaved[Name] := Keystats.%Name%
	FocusSaved := MetricsFocusCache.state
	FilterSaved := Map()
	for Name in ["disabled_apps", "private_browsing", "secure_field", "system_auth"]
		FilterSaved[Name] := MetricsFilters.%Name%
	Db := 0
	try {
		AssertFalse(A_IsSuspended, "the passive clock fixture must not inherit suspension")
		Keystats.initialized := true
		Keystats.synth_active := false
		Keystats.synth_private := false
		Keystats.buffer_events := []
		Keystats.buffer_text := ""
		KLHook.prev_app := ""
		KLHook.prev_title := ""
		KLHook.context_transition := false, KLHook.context_stop := false
		KLHook.context_observations := [], KLHook.context_observation_head := 1
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
		Keystats.synth_active := 1
		Keystats.synth_type := "hotstring"
		KL_Hook_OnChar(0, "x")
		AssertEqual(0, KLHook.last_tick, "the actual synthetic reset keeps only accepted authority")
		AssertEqual("x", Keystats.buffer_text, "the reset is reachable after actual privacy admission")
		AssertEqual(1, Keystats.buffer_events.Length)
		AssertEqual(1, Keystats.buffer_events[1][3]["s"])
		Keystats.synth_active := false
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
		for Name, Value in KeystatsSaved
			Keystats.%Name% := Value
		MetricsFocusCache.state := FocusSaved
		for Name, Value in FilterSaved
			MetricsFilters.%Name% := Value
	}
}
for _KLRManifest_Native64Scenario in ["app-exact", "app-after", "accepted-before", "accepted-exact", "accepted-after",
	"accepted-before-long", "accepted-exact-long", "accepted-after-long", "physical-before", "physical-exact",
	"physical-after", "physical-before-long", "physical-exact-long", "physical-after-long", "physical-recent-long",
	"inactive-long", "empty-app-long", "zero-origin-long"]
	Test("Keystats native64 foreground: " . _KLRManifest_Native64Scenario . " (klr-live-native64)",
		_KLRManifest_Native64.Bind(_KLRManifest_Native64Scenario))
for _KLRManifest_Native64Consumer in ["Map", "encoded"] {
	for _KLRManifest_Native64ConsumerScenario in ["app-exact", "app-after", "accepted-before-long", "physical-before-long", "accepted-before", "accepted-exact"]
		Test("Keystats native64 actual " . _KLRManifest_Native64Consumer . ": " . _KLRManifest_Native64ConsumerScenario . " (klr-live-native64)",
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
Test("Keystats native64 projection: final clock follows publication snapshot (klr-live-snapshot-order)",
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
Test("Keystats native64 projection: snapshot source guards reject changed order (klr-live-snapshot-order)",
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


; This fixture provisions the shared additive table independently of the loader,
; so an old reader cannot pass simply because the new production API is absent.
_KLRMedia_OpenFixture() {
	global _SharedDir
	Db := _KLRManifest_OpenFixture()
	try {
		AssertTrue(SQLite_Exec(Db, FileRead(_SharedDir . "\metrics\data\db\media_schema.sql", "UTF-8")))
		return Db
	} catch as Failure {
		SQLite_Close(Db)
		throw Failure
	}
}

_KLRMedia_ProductionSchema() {
	Db := _KLRManifest_OpenFixture()
	try {
		Rows := SQLite_Query(Db, "SELECT COUNT(*) AS n FROM sqlite_master WHERE name IN ('ngram_media_keys','agg_app_day_media_hold')")
		AssertEqual(2, Rows[1]["n"], "the production loader must apply the committed additive media schema")
		AssertEqual(2, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM agg_app_day_kc_hold")[1]["n"],
			"loading media schema cannot replace existing numeric rows")
	} finally {
		SQLite_Close(Db)
	}
}
Test("Semantic media history: production additive schema", _KLRMedia_ProductionSchema)

_KLRMedia_SeededProjection() {
	Db := _KLRMedia_OpenFixture()
	try {
		; Windows captures no media key: it reads the rows macOS and Linux synced. Its one
		; share of keystats/media_identity_vectors.json is the identities the reader
		; publishes; the HID, system and evdev columns have no owner here.
		global _SharedDir
		Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\keystats\media_identity_vectors.json", "UTF-8"))
		Ids := []
		for Vector in Corpus["positive"]
			Ids.Push(Vector["id"])
		AssertEqual(5, Ids.Length, "the shared media identities changed")
		for Id in Ids {
			AssertTrue(SQLite_Exec(Db, "INSERT INTO ngram_media_keys VALUES ('a','2025-05-01','editor.exe'," . SQLite_Q(Id) . ",2),"
				. "('b','2025-05-01','editor.exe'," . SQLite_Q(Id) . ",3);"
				. "INSERT INTO agg_app_day_media_hold VALUES ('a','2025-05-01','editor.exe'," . SQLite_Q(Id) . ",100,1,100,1,0),"
				. "('b','2025-05-01','editor.exe'," . SQLite_Q(Id) . ",300,1,300,0,1);"))
		}
		AssertTrue(SQLite_Exec(Db, "INSERT INTO ngram_media_keys VALUES ('a','2025-04-30','editor.exe','media.play_pause',17);"))
		Manifest := KLR_ReadManifestBase(Db, "2025-05-01", "2025-05-01")
		Entry := Manifest["2025-05-01"]["editor.exe"]
		AssertTrue(Entry.Has("media_keys") && Entry.Has("media_hold"), "the actual reader must publish separate media maps")
		for Id in Ids {
			AssertEqual(5, Entry["media_keys"][Id])
			Hold := Entry["media_hold"][Id]
			AssertEqual(400, Hold["s"])
			AssertEqual(2, Hold["n"])
			AssertEqual(300, Hold["m"], "device maxima are not additive")
			AssertEqual(1, Hold["tap"])
			AssertEqual(1, Hold["hold"])
		}
		AssertFalse(Manifest.Has("2025-04-30"), "the original date filter also owns media rows")
		AssertEqual(1000, Entry["kc_hold"]["16"]["s"], "numeric keyboard/volume namespaces stay unchanged")
		AssertFalse(Entry["kc_hold"].Has("media.play_pause"), "media cannot acquire a fabricated keyboard position")
		Encoded := JsonParse(KLR_BuildManifestJson(Db, "2025-05-01", "2025-05-01"))
		AssertEqual(5, Encoded["2025-05-01"]["editor.exe"]["media_keys"]["media.play_pause"],
			"the real prefetch JSON path must retain semantic media")
		AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM sqlite_temp_master WHERE name LIKE '_ergopti_media_%_projection'")[1]["n"],
			"temporary schema validation must be retired before any manifest is returned")
	} finally {
		SQLite_Close(Db)
	}
}
Test("Semantic media history: real two-device projection and JSON", _KLRMedia_SeededProjection)

_KLRMedia_RejectsUnsafeProjection() {
	for Kind in ["counter-overflow", "unknown-identity", "empty-app"] {
		Db := _KLRMedia_OpenFixture()
		try {
			if Kind = "counter-overflow" {
				AssertTrue(SQLite_Exec(Db, "INSERT INTO ngram_media_keys VALUES ('a','2025-05-01','editor.exe','media.play_pause',9007199254740991),"
					. "('b','2025-05-01','editor.exe','media.play_pause',1);"))
			} else if Kind = "unknown-identity" {
				AssertTrue(SQLite_Exec(Db, "PRAGMA ignore_check_constraints=ON;"
					. "INSERT INTO ngram_media_keys VALUES ('a','2025-05-01','editor.exe','media.unknown',1);"
					. "PRAGMA ignore_check_constraints=OFF;"))
			} else {
				AssertTrue(SQLite_Exec(Db, "INSERT INTO ngram_media_keys VALUES ('a','2025-05-01','','media.play_pause',1);"))
			}
			AssertThrows(() => KLR_ReadManifestBase(Db, "2025-05-01", "2025-05-01"),
				"the real reader must refuse " . Kind . " rather than return a plausible partial media payload")
			AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM sqlite_temp_master WHERE name LIKE '_ergopti_media_%_projection'")[1]["n"],
				"failed validation must still retire its own temporary schema")
		} finally {
		SQLite_Close(Db)
	}
	}
}
Test("Semantic media history: native shared-policy refusals", _KLRMedia_RejectsUnsafeProjection)

_KLRMedia_PreservesForeignTemporaryTable() {
	Db := _KLRMedia_OpenFixture()
	try {
		AssertTrue(SQLite_Exec(Db, "CREATE TEMP TABLE _ergopti_media_keys_projection (sentinel TEXT);"
			. "INSERT INTO _ergopti_media_keys_projection VALUES ('foreign owner');"))
		AssertThrows(() => KLR_ReadManifestBase(Db), "a prior table cannot be treated as this reader's validator")
		Rows := SQLite_Query(Db, "SELECT sentinel FROM temp._ergopti_media_keys_projection")
		AssertEqual("foreign owner", Rows[1]["sentinel"], "refusal cannot remove or replace the foreign owner")
	} finally {
		SQLite_Close(Db)
	}
}
Test("Semantic media history: foreign temporary table is preserved", _KLRMedia_PreservesForeignTemporaryTable)

_KLRMedia_RetainsCleanupRefusal() {
	Body := _DriverFuncBody("KLR__MediaProjectionRows")
	AssertTrue(Body != "", "negative controls require the actual projection owner function")
	Db := _KLRMedia_OpenFixture()
	try {
		NativeExceptDrop := (OwnedDb, Sql) => InStr(Sql, "DROP TABLE", true) ? false : SQLite_Exec(OwnedDb, Sql)
		AssertThrows(() => KLR__MediaProjectionRows(Db, "", NativeExceptDrop),
			"a refused native DROP cannot qualify successful rows")
		AssertThrows(() => KLR_ReadManifestBase(Db), "unretired validator names must block replacement")
		AssertEqual(2, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM sqlite_temp_master WHERE name LIKE '_ergopti_media_%_projection'")[1]["n"],
			"refused cleanup retains the exact temporary owners instead of hiding debt")
	} finally {
		SQLite_Close(Db)
	}
}
Test("Semantic media history: cleanup refusal is retained", _KLRMedia_RetainsCleanupRefusal)

; Optional media tables may be absent from an otherwise compatible image.
; Exercise its admitted read-only no-tail fast path and private table upgrade.
_KLRMedia_CompatibleWarmCache(KeepOriginalReader := true) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Stored := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "code.exe", ["a", "b"]))
		Before := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())
		CachePath := KLR_CachePath(_KLRDC_Root())
		KLR_ResetCache()
		Stored := SQLite_Open(CachePath)
		AssertTrue(Stored != 0)
		AssertEqual(KLR_CACHE_FORMAT_VERSION, _KLR_CacheMetaValue(Stored, "format_version"),
			"the missing-table fixture must retain admitted projection provenance")
		AssertTrue(SQLite_Exec(Stored, "DROP TABLE ngram_media_keys; DROP TABLE agg_app_day_media_hold;"))
		SQLite_Close(Stored)
		Stored := 0
		KLRCache.disposable := true
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"),
			"the compatible missing-table cache must reach production warm admission")
		OldDb := KLRCache.db
		AssertEqual(1, DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly", "Ptr", OldDb, "AStr", "main", "Int"))
		; Observe the original image independently while the candidate is upgraded.
		if KeepOriginalReader {
			Stored := SQLite_Open(CachePath, SQLiteConst.OPEN_RO)
			AssertTrue(Stored != 0)
		}
		Db := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Db != 0 && Db != OldDb, "missing tables require a private admitted successor")
		if KeepOriginalReader {
			AssertEqual(0, SQLite_Query(Stored,
				"SELECT COUNT(*) AS n FROM sqlite_master WHERE name IN ('ngram_media_keys','agg_app_day_media_hold')")[1]["n"],
				"the open read-only original must remain unchanged")
		} else {
			Stored := SQLite_Open(CachePath, SQLiteConst.OPEN_RO)
			AssertTrue(Stored != 0)
			AssertEqual(2, SQLite_Query(Stored,
				"SELECT COUNT(*) AS n FROM sqlite_master WHERE name IN ('ngram_media_keys','agg_app_day_media_hold')")[1]["n"],
				"successful upgrade must persist once so future workers retain the no-clone fast path")
		}
		AssertEqual(Before, _KLRDC_DerivedFingerprint(Db), "upgrade cannot rebuild or alter numeric projection")
		Manifest := KLR_ReadManifestBase(Db, "2026-01-01", "2026-01-01")
		AssertEqual(0, Manifest["2026-01-01"]["code.exe"]["media_keys"].Count,
			"a cache without media tables carries no fabricated semantic media credit")
		AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()), "an admitted unchanged image keeps its existing fast path")
	} finally {
		if Stored
			SQLite_Close(Stored)
		_KLRDC_Cleanup()
	}
}
Test("Semantic media history: compatible warm cache private upgrade", _KLRMedia_CompatibleWarmCache)

_KLRMedia_UpgradeRefusalPreservesPublished() {
	global _SharedDir
	AssertTrue(_DriverFuncBody("KLR_UpgradeMediaCache") != "", "the negative schedule requires the actual upgrade owner")
	KLR_ResetCache()
	Db := _KLRManifest_OpenFixture((OwnedDb) => SQLite_Exec(OwnedDb,
		FileRead(_SharedDir . "\metrics\data\db\schema.sql", "UTF-8")))
	KLRCache.db := Db
	KLRCache.last_sizes := Map("original.sql", 23)
	KLRCache.ledger_snapshots := Map("original.sql", Map("index_low", 41))
	Before := SQLite_Query(Db, "SELECT SUM(sum_ms) AS s FROM agg_app_day_kc_hold")[1]["s"]
	try {
		RefusingLoader := (Candidate) => false
		AssertThrows(() => KLR_UpgradeMediaCache(RefusingLoader),
			"schema refusal cannot publish an incomplete private copy")
		AssertEqual(Db, KLRCache.db, "the exact old published owner remains retained")
		AssertEqual(23, KLRCache.last_sizes["original.sql"])
		AssertEqual(41, KLRCache.ledger_snapshots["original.sql"]["index_low"])
		AssertEqual(0, SQLite_Query(Db,
			"SELECT COUNT(*) AS n FROM sqlite_master WHERE name IN ('ngram_media_keys','agg_app_day_media_hold')")[1]["n"])
		AssertTrue(KLR_UpgradeMediaCache(), "a fully retired failed candidate permits legitimate retry")
		AssertTrue(KLRCache.db != Db, "only the complete successor may replace the old owner")
		AssertEqual(Before, SQLite_Query(KLRCache.db, "SELECT SUM(sum_ms) AS s FROM agg_app_day_kc_hold")[1]["s"])
	} finally {
		KLR_ResetCache()
	}
}
Test("Semantic media history: failed cache upgrade retains published source", _KLRMedia_UpgradeRefusalPreservesPublished)

_KLRMedia_CheckedCloseRefusesLiveStatement() {
	AssertTrue(_DriverFuncBody("SQLite_CloseChecked") != "", "the native close control requires its real source owner")
	Db := _KLRManifest_OpenFixture()
	Statement := 0
	try {
		Sql := SQLite_StrToUtf8("SELECT * FROM agg_app_day_kc_hold", &SqlBuffer)
		AssertEqual(SQLiteConst.OK, DllCall(SQLiteConst.DLL . "\sqlite3_prepare_v2", "Ptr", Db,
			"Ptr", Sql, "Int", -1, "Ptr*", &Statement, "Ptr", 0, "Int"))
		AssertTrue(Statement != 0, "the refusal requires a genuinely live native statement")
		AssertEqual(5, SQLite_CloseChecked(Db), "sqlite3_close must return native BUSY rather than a zombie success")
		AssertEqual(2, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM agg_app_day_kc_hold")[1]["n"],
			"BUSY must retain the same usable connection until its original statement is finalized")
		AssertEqual(SQLiteConst.OK, SQLite_FinalizeStatement(Statement))
		Statement := 0
		AssertEqual(SQLiteConst.OK, SQLite_CloseChecked(Db), "the exact connection retires after its statement")
		Db := 0
	} finally {
		if Statement
			SQLite_FinalizeStatement(Statement)
		if Db
			SQLite_Close(Db)
	}
}
Test("Semantic media history: checked native close refuses live statement", _KLRMedia_CheckedCloseRefusesLiveStatement)

Test("Semantic media history: upgraded image persists for future worker", _KLRMedia_CompatibleWarmCache.Bind(false))


; Resolve the actual declaration once by authored-source identity, not a pinned path.
_KFCD_ClassOwner(ClassName) {
	global _DriverDir
	Owners := []
	for Path in _DriverProductionSourceCensus(_DriverDir).Paths {
		Text := FileRead(Path, "UTF-8")
		Mask := _DriverMaskNonCode(&Text)
		if RegExMatch(Mask, "m)^\h*class\h+" . ClassName . "\b\s*\{")
			Owners.Push(Path)
	}
	AssertEqual(1, Owners.Length, "The actual native dispatcher constants must have exactly one authored class declaration")
	return Owners[1]
}

; Actual public context and stop bodies retain canonical privacy and append.
_KFCD_ChildSource() {
	global _DriverDir
	Source := _KSD_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\switch_destination_privacy_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1))
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	Common := RTrim(FileRead(_DriverDir . "\tests\fixtures\switch_destination_privacy_owner_body.ahk", "UTF-8"), "`r`n")
	Entry := "_KSD_Main()"
	AssertEqual(Entry, SubStr(Common, StrLen(Common) - StrLen(Entry) + 1))
	Source .= SubStr(Common, 1, StrLen(Common) - StrLen(Entry)) . "`n"
	for Spec in [["KL_CommitPwCache", "KLPasswordCache"], ["", "HookDispatcherConst"]] {
		Owner := Spec[1] == "" ? _KFCD_ClassOwner(Spec[2]) : _DriverProductionFileForSymbol(Spec[1], _DriverDir)
		AssertTrue(Owner != "")
		AssertTrue(RegExMatch(FileRead(Owner, "UTF-8"), "ms)^class " . Spec[2] . " \{.*?^\}", &Definition) > 0)
		Source .= Definition[0] . "`n"
	}
	Source .= 'class HookDispatcher {`nstatic Unregister(*) {`nthrow Error("Unexpected physical hook removal.")`n}`n}`n'
	for JsonSymbol in ["JsonStringLiteral", "KL_JsonEncode"] {
		Owner := _DriverProductionFileForSymbol(JsonSymbol, _DriverDir)
		AssertTrue(Owner != "", "The actual canonical JSON graph requires its genuine owner: " . JsonSymbol)
		Source .= "#Include " . Owner . "`n"
	}
	for Symbol in ["KL_Hook_Stop", "KL_Hook_InvalidateCapture", "KL_PasswordFocusTrackingStop", "KL_FreePasswordFocusCallback"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "")
		Source .= Body . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\final_context_duration_owner_body.ahk`n"
}

_KFCD_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_final_context_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "The child must exclusively acquire its directory before writing or recursive cleanup.")
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KFCD_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact switch-destination child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# final-context-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS final-context-duration " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
	return AtDeadline.Output
}

_KFCD_DurableCase(Mode) {
	Output := _KFCD_Case(Mode)
	Rows := []
	for Line in StrSplit(Output, "`n", "`r")
		if SubStr(Line, 1, 4) == "ROW "
			Rows.Push(JsonParse(SubStr(Line, 5)))
	Db := 0
	try {
		Db := _KLRManifest_OpenFixture()
		for Row in Rows {
			Statements := KL_BuildInserts(Row)
			for Sql in Statements
				AssertTrue(SQLite_Exec(Db, Sql), "Every actual producer row must enter canonical SQLite unchanged")
		}
		AssertTrue(KLR_PrepareTypingProjection(Db), "The real rebuild requires its actual typing projection table even for no typing rows")
		AssertTrue(KLR_RebuildAggregates(Db), "The actual aggregate rebuild must accept the producer rows")
		Actual := SQLite_Query(Db, "SELECT COALESCE(SUM(app_time_ms),0) AS ms FROM agg_app_day WHERE app='fixture-final-context-a.exe'")[1]["ms"]
		_TestPrint("# final-context-durable mode=" . Mode . " app_time_ms=" . Actual . " canonical_rows=" . Rows.Length)
		AssertTrue(Actual >= 40, "A completed foreground interval must survive its public stop and a cold SQL rebuild")
	} finally {
		if Db
			SQLite_Close(Db)
	}
}
for _KFCD_Mode in ["switch-control", "terminal"]
	Test("Keystats final context: " . _KFCD_Mode . " survives cold durable aggregation (final-context-duration-owner)",
		_KFCD_DurableCase.Bind(_KFCD_Mode))

_KMD_ChildSource() {
	global _DriverDir
	Source := _KFCD_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\final_context_duration_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1))
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	; Remove only the inherited test wrapper whose empty-buffer-only contract
	; deliberately does not load the full publication graph. SUT bodies are not
	; rewritten: replace its exact alias by the genuine default public definition.
	Source := RegExReplace(Source, "ms)^KL_FlushBuffer\(.*?^\}\r?\n", "", &Removed)
	AssertEqual(1, Removed)
	Body := _DriverFuncBody("KL_FlushBuffer")
	Alias := RegExReplace(Body, "^KL_FlushBuffer", "_KSD_NativeFlush")
	Source := StrReplace(Source, Alias, "", true, &Removed)
	AssertEqual(1, Removed)
	Source .= Body . "`n"
	Source .= "#Include " . _KFCD_ClassOwner("KeystatsConst") . "`n"
	for Spec in [["KL_Mouse_ParkTick", "KLMouseConst"], ["KL_Mouse_ParkTick", "KLMouse"], ["KL_AppCat_Get", "KLAppCat"]] {
		Owner := _DriverProductionFileForSymbol(Spec[1], _DriverDir)
		AssertTrue(Owner != "")
		AssertTrue(RegExMatch(FileRead(Owner, "UTF-8"), "ms)^class " . Spec[2] . " \{.*?^\}", &Definition) > 0)
		Source .= Definition[0] . "`n"
	}
	for Symbol in ["_KL_PublishBufferSnapshot", "_KL_RestoreBufferSnapshot", "KL_AppCat_Get",
		"KL_AppCat_RequireInit", "_KL_AppCat_RecordLabel", "KL_Mouse_ParkTick", "_KL_Mouse_ProcessParkSample",
		"_KL_Mouse_ShouldFilter", "KL_BumpMouseDistance", "KL_BumpMouseClick", "KL_Hook_Tick", "KL_Hook_LivePush"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "The complete actual public distance-to-flush graph must resolve: " . Symbol)
		Source .= Body . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\mouse_distance_flush_owner_body.ahk`n"
}

_KMD_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_mouse_distance_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "The child must exclusively acquire its directory before writing or recursive cleanup.")
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KMD_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact switch-destination child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# mouse-distance-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS mouse-distance-flush " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
	return AtDeadline.Output
}

_KMD_DurableCase(Mode) {
	Output := _KMD_Case(Mode)
	Db := 0, Rows := 0
	try {
		Db := _KLRManifest_OpenFixture()
		for Line in StrSplit(Output, "`n", "`r") {
			if SubStr(Line, 1, 4) != "ROW "
				continue
			Entry := JsonParse(SubStr(Line, 5))
			for Sql in KL_BuildInserts(Entry)
				AssertTrue(SQLite_Exec(Db, Sql))
			Rows += 1
		}
		Distance := SQLite_Query(Db, "SELECT COALESCE(SUM(mouse_distance_px),0) AS n FROM events_typing WHERE app='fixture-distance-owner.exe'")[1]["n"]
		_TestPrint("# mouse-distance-durable mode=" . Mode . " rows=" . Rows . " distance_px=" . Distance)
		AssertEqual(5, Distance, "Accepted pointer movement must reach the canonical SQL distance column even without a key or click")
	} finally {
		if Db
			SQLite_Close(Db)
	}
}
for _KMD_Mode in ["with-click-control", "direct-movement-only", "periodic-movement-only"]
	Test("Keystats pointer distance: " . _KMD_Mode . " survives actual flush to canonical SQL (mouse-distance-flush-owner)",
		_KMD_DurableCase.Bind(_KMD_Mode))

_KTAC_ChildSource() {
	global _DriverDir
	Source := _KFCD_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\final_context_duration_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1))
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	; Rename only inherited TEST observation wrappers. Native producer bodies,
	; canonical append, clock samples and their accepted queue stay untouched.
	for Name in ["KL_LogAppSwitch", "KL_LogWindowSwitch"] {
		Source := RegExReplace(Source, "m)^" . Name . "\(", "_KTAC_Inherited" . Name . "(", &Changed)
		AssertEqual(1, Changed)
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\context_clock_ack_owner_body.ahk`n"
}

_KTAC_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_context_clock_ack_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "The child must exclusively acquire its directory before writing or recursive cleanup.")
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KTAC_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact switch-destination child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# context-clock-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS context-clock-ack " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
	return AtDeadline.Output
}

_KTAC_DurableCase(Mode) {
	Output := _KTAC_Case(Mode)
	Db := 0, State := 0
	try {
		Db := _KLRManifest_OpenFixture()
		for Line in StrSplit(Output, "`n", "`r") {
			if SubStr(Line, 1, 6) == "STATE " {
				State := StrSplit(SubStr(Line, 7), "|")
				continue
			}
			if SubStr(Line, 1, 4) != "ROW "
				continue
			Entry := JsonParse(SubStr(Line, 5))
			for Sql in KL_BuildInserts(Entry)
				AssertTrue(SQLite_Exec(Db, Sql))
		}
		AssertTrue(State is Array && State.Length == 6, "The exact native cutpoint must provide its independent clock bound")
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(KLR_RebuildAggregates(Db))
		AssertTrue(KLR_RebuildWalkerAggregates(Db, true) >= 0)
		AppMs := SQLite_Query(Db, "SELECT COALESCE(SUM(app_time_ms),0) AS ms FROM agg_app_day WHERE app IN ('fixture-tail-a.exe','fixture-tail-b.exe')")[1]["ms"]
		TitleMs := SQLite_Query(Db, "SELECT COALESCE(SUM(ms),0) AS ms FROM agg_app_day_titles WHERE app IN ('fixture-tail-a.exe','fixture-tail-b.exe')")[1]["ms"]
		Foreign := SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_window_switch WHERE app='fixture-tail-b.exe' AND prev_title='Fixture source title A'")[1]["n"]
		_TestPrint("# context-clock-ack-durable mode=" . Mode . " app_ms=" . AppMs . " title_ms=" . TitleMs
			. " native_bound=" . State[4] . " foreign_titles=" . Foreign . " stable=" . State[1])
		AssertTrue(AppMs <= Integer(State[4]), "Accepted app interval plus tail may not count an earlier accepted origin twice")
		AssertTrue(TitleMs <= Integer(State[4]), "Accepted title interval plus tail may not count an earlier accepted origin twice")
		AssertEqual(0, Foreign, "An app ACK cannot transfer the still-outgoing title clock to its destination")
		if Integer(State[6]) {
			AssertEqual(1, Integer(State[1]), "An interrupted context producer cannot resurrect its app/title/origins after actual Stop")
			AssertEqual(Integer(State[2]), Integer(State[3]), "An interrupted producer cannot append a new row after actual Stop")
		}
	} finally {
		if Db
			SQLite_Close(Db)
	}
}
for _KTAC_Mode in ["app-control", "title-control", "app-stop", "title-stop"]
	Test("Keystats context clock ACK: " . _KTAC_Mode . " respects accepted-row and native-stop ownership (context-clock-ack-owner)",
		_KTAC_DurableCase.Bind(_KTAC_Mode))

for _KTAC_ThirdMode in ["app-third", "title-third"]
	Test("Keystats context clock ACK: " . _KTAC_ThirdMode . " preserves third observation receipts (context-clock-ack-third)",
		_KTAC_Case.Bind(_KTAC_ThirdMode))

_KCTR_ChildSource() {
	global _DriverDir
	Source := _KFCD_ChildSource()
	Source := StrReplace(Source, "`nKL_LogWindowSwitch(Values*) {", "`n_KCTR_ObservedLogWindowSwitch(Values*) {")
	AssertTrue(InStr(Source, "`n_KCTR_ObservedLogWindowSwitch(Values*) {") > 0,
		"The observation wrapper alone is renamed; its genuine native logger and central sink remain unchanged")
	Footer := "#Include " . _DriverDir . "\tests\fixtures\final_context_duration_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1))
	return SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
		. "#Include " . _DriverDir . "\tests\fixtures\context_tail_retry_owner_body.ahk`n"
}
_KCTR_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_context_tail_retry_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "The child must exclusively acquire its directory before writing or recursive cleanup.")
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KCTR_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact switch-destination child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# context-tail-retry-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS context-tail-retry " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
	return AtDeadline.Output
}

_KCTR_DurableCase(Mode) {
	Output := _KCTR_Case(Mode)
	Db := 0
	try {
		Db := _KLRManifest_OpenFixture()
		for Line in StrSplit(Output, "`n", "`r") {
			if SubStr(Line, 1, 4) != "ROW "
				continue
			for Sql in KL_BuildInserts(JsonParse(SubStr(Line, 5)))
				AssertTrue(SQLite_Exec(Db, Sql), "Actual acknowledged tail rows must enter canonical SQLite unchanged")
		}
		AppRows := SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_app_switch WHERE prev_app='fixture-tail-retry-a.exe'")[1]["n"]
		TitleRows := SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_window_switch WHERE app='fixture-tail-retry-a.exe'")[1]["n"]
		AssertEqual(Mode == "privacy-terminal" ? 0 : 1, AppRows)
		AssertEqual(Mode == "privacy-terminal" ? 0 : 1, TitleRows)
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(KLR_RebuildAggregates(Db))
		Ms := SQLite_Query(Db, "SELECT COALESCE(SUM(app_time_ms),0) AS ms FROM agg_app_day WHERE app='fixture-tail-retry-a.exe'")[1]["ms"]
		if Mode == "privacy-terminal"
			AssertEqual(0, Ms)
		else
			AssertTrue(Ms >= 30, "The actual final interval must survive its independently acknowledged retry and cold rebuild")
	} finally {
		if Db
			SQLite_Close(Db)
	}
}
for _KCTR_Mode in ["complete-control", "partial-retry", "privacy-terminal", "transition-retry"]
	Test("Keystats context tail: " . _KCTR_Mode . " consumes only independently acknowledged intervals (context-tail-retry-owner)",
		_KCTR_DurableCase.Bind(_KCTR_Mode))


; Proposed append-only native regression for test_manifest_contract.ahk.
; This measures canonical journal reconstruction, not a native InputHook batching race.
_KTPR_CorpusCase(VectorId) {
	Corpus := _KlgAggCorpus_LoadCorpus()
	AssertTrue(Corpus is Map && Corpus.Has("vectors"), "Use the same shared golden input and expected values as the real walker contract")
	Vector := 0
	for Candidate in Corpus["vectors"]
		if Candidate["id"] == VectorId
			Vector := Candidate
	AssertTrue(Vector is Map && Vector["events"].Length == 1, "This focused case must select one genuine corpus typing row")
	Raw := Vector["events"][1]
	Events := [], Text := ""
	for Ev in Raw["events"] {
		Events.Push([Ev["char"], Ev["delay"], Ev["meta"]])
		Text .= Ev["char"]
	}
	Entry := Map("type", "typing", "_event_id", 1, "app", Raw["app"],
		"timestamp", Raw["timestamp"], "events", Events, "text", Text,
		"pause_before_ms", Events[1][2])
	Date := SubStr(Raw["timestamp"], 1, 10)
	Expected := Vector["expected"]["app_day"][Date . Chr(1) . Raw["app"]]
	Db := 0
	try {
		Db := _KLRManifest_OpenFixture()
		for Sql in KL_BuildInserts(Entry)
			AssertTrue(SQLite_Exec(Db, Sql), "The actual canonical typing builder must persist the shared input unchanged")
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(KLR_RebuildAggregates(Db))
		Cell := KLR_ReadManifest(Db, Date, Date)[Date][Raw["app"]]
		_TestPrint("# think-pause-corpus id=" . VectorId . " chars=" . Cell["chars"]
			. " pauses=" . Cell["pauses"] . " think_time=" . Cell["think_time"])
		AssertEqual(Expected["chars"], Cell["chars"])
		AssertEqual(Expected["pauses"], Cell["pauses"], "SQL-owned pause counts must retain manual pauses at every position in a canonical row")
		AssertEqual(Expected["think_time_ms"], Cell["think_time"], "The published reconstruction must honor the shared event-level thinking-time contract")
	} finally {
		if Db
			SQLite_Close(Db)
	}
}
for _KTPR_Id in ["simple_typing_3_chars", "typing_with_think_pause"]
	Test("Keystats reader shared think-pause corpus: " . _KTPR_Id . " survives canonical SQL projection (reader-think-pause-corpus)",
		_KTPR_CorpusCase.Bind(_KTPR_Id))


; Numeric migration and threshold semantics use the real reader and canonical schema.
_KLRTP_NumericMigration(Db) {
	SavedThink := KLWConst.THINK_PAUSE_MS
	try {
		KLWConst.THINK_PAUSE_MS := 100
		AssertTrue(KLR_LoadSchema(Db))
		Events := [["a",100,Map()], ["b",101,Map()], ["[BS]",201,Map()],
			["c",501,Map("s",1,"st","hotstring")], ["d",601,Map("sc","Ctrl+D")], ["e",20,Map()]]
		AssertTrue(SQLite_Exec(Db,
			"INSERT INTO events_typing(device_id,id,ts,date,app,is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json,pause_before_ms) "
			. "VALUES('pause-owner',1,'2026-01-01 10:00:00.000','2026-01-01','pause.exe',0,0,0,0,0,'ace',"
			. SQLite_Q(KL_JsonEncode(Events)) . ",9000);"
			. "CREATE TABLE klr_reader_typing_counts(device_id TEXT NOT NULL,event_id INTEGER NOT NULL,chars INTEGER NOT NULL,PRIMARY KEY(device_id,event_id)) WITHOUT ROWID;"
			. "INSERT INTO klr_reader_typing_counts VALUES('pause-owner',1,5);"
			. "CREATE TRIGGER pause_count_delete_refusal BEFORE DELETE ON klr_reader_typing_counts BEGIN SELECT RAISE(ABORT,'no count deletion');END;"))
		AssertTrue(KLR_PrepareTypingProjection(Db, 0, false), "The actual old chars-only table must migrate and compute missing event-level numbers")
		Row := SQLite_Query(Db, "SELECT chars,pauses,think_time_ms,think_pause_ms FROM klr_reader_typing_counts;")[1]
		AssertEqual(5, Row["chars"], "The pre-existing chars projection policy remains unchanged")
		AssertEqual(2, Row["pauses"], "Strict threshold excludes equality; manual Backspace counts; synthetic and shortcut entries do not")
		AssertEqual(302, Row["think_time_ms"])
		AssertEqual(100, Row["think_pause_ms"])
		AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM sqlite_schema WHERE name='pause_count_delete_refusal';")[1]["n"],
			"Migration must preserve existing refusal triggers rather than replace the numeric owner")
		AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM temp.klr_reader_typing_payload;")[1]["n"], "Counts-only preparation must not retain clear replay payloads")
		AssertTrue(KLR_RebuildAggregates(Db))
		Cell := KLR_ReadManifest(Db, "2026-01-01", "2026-01-01")["2026-01-01"]["pause.exe"]
		AssertEqual(2, Cell["pauses"])
		AssertEqual(302, Cell["think_time"], "The deliberately unrelated pause_before_ms=9000 is not the event-level source")
		KLWConst.THINK_PAUSE_MS := 200
		AssertTrue(KLR_PrepareTypingProjection(Db, ["2026-01-01"], false), "A changed real walker threshold must invalidate the numeric row even with no TEMP payload")
		Row := SQLite_Query(Db, "SELECT pauses,think_time_ms,think_pause_ms FROM klr_reader_typing_counts;")[1]
		AssertEqual(1, Row["pauses"])
		AssertEqual(201, Row["think_time_ms"])
		AssertEqual(200, Row["think_pause_ms"])
		AssertTrue(KLR_RebuildAggregates(Db))
		AssertEqual(201, KLR_ReadManifest(Db, "2026-01-01", "2026-01-01")["2026-01-01"]["pause.exe"]["think_time"])
		_SQLRD_AssertNoStatements(Db)
	} finally KLWConst.THINK_PAUSE_MS := SavedThink
}
Test("KLR thinking pauses: legacy numeric rows and changed thresholds preserve actual manual semantics (klr-thinking-pause-numeric)",
	_SQLRD_WithDatabase.Bind(_KLRTP_NumericMigration))


; These are real canonical JSON numbers through SQLite and public projection,
; not a direct call to the arithmetic helper or invented append verdicts.
_KLRTP_NumericBoundary(Spec, Db) {
	SavedThink := KLWConst.THINK_PAUSE_MS
	try {
		KLWConst.THINK_PAUSE_MS := 0
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db,
			"INSERT INTO events_typing(device_id,id,ts,date,app,is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json,pause_before_ms) "
			. "VALUES('numeric-pause',1,'2026-01-01 10:00:00.000','2026-01-01','number.exe',0,0,0,0,0,'ab',"
			. SQLite_Q(Spec[2]) . ",0);"))
		Result := KLR_PrepareTypingProjection(Db, 0, false)
		AssertEqual(Spec[3], Result, "Only a representable finite thinking-time sum may prepare its numeric projection: " . Spec[1])
		if !Spec[3] {
			AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM klr_reader_typing_counts;")[1]["n"],
				"An invalid row sum must fail before that page publishes even a wrapped numeric count")
			AssertEqual(0, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM temp.klr_reader_typing_payload;")[1]["n"])
		} else {
			Actual := SQLite_Query(Db, "SELECT think_time_ms FROM klr_reader_typing_counts;")[1]["think_time_ms"]
			AssertTrue(Actual = Spec[4], "Integer exactness and ordinary IEEE Float results must survive the actual SQL literal unchanged")
			AssertTrue(KLR_RebuildAggregates(Db))
			Cell := KLR_ReadManifest(Db, "2026-01-01", "2026-01-01")["2026-01-01"]["number.exe"]
			AssertTrue(Cell["think_time"] = Spec[4], "The actual manifest must expose the same finite native sum")
			AssertEqual(2, Cell["pauses"])
		}
		_SQLRD_AssertNoStatements(Db)
	} finally KLWConst.THINK_PAUSE_MS := SavedThink
}
for _KLRTP_Spec in [
	["int64-limit", '[["a",9223372036854775806,{}],["b",1,{}]]', true, 0x7FFFFFFFFFFFFFFF],
	["int64-overflow", '[["a",9223372036854775807,{}],["b",1,{}]]', false, 0],
	["binary-float", '[["a",1.25,{}],["b",2.5,{}]]', true, 3.75],
	["ordinary-float", '[["a",0.1,{}],["b",0.2,{}]]', true, 0.1 + 0.2],
	["float-overflow", '[["a",1e308,{}],["b",1e308,{}]]', false, 0]
]
	Test("KLR thinking pauses numeric domain: " . _KLRTP_Spec[1] . " retains finite projection semantics (klr-thinking-pause-numeric-domain)",
		_SQLRD_WithDatabase.Bind(_KLRTP_NumericBoundary.Bind(_KLRTP_Spec)))

_KLDL_Frontend(Root, Kind) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved frontend child must retain its exact owned input directory")
	Repo := FSResolveDirectoryPath(_DriverDir . "\..\..\..")
	Script := Repo . "\tools\test\support\typing-live-inventory.cjs"
	AssertTrue(FSStrictExists(Script), "The actual frontend fixture must exist")
	Directory := A_Temp . "\ergopti_live_inventory_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	AssertEqual(1, FSCreateDirectoryExclusiveStrict(Directory), "The frontend inputs require an exclusively acquired directory")
	State := {Calls: 0, Code: -1, Output: ""}, Handle := 0
	Complete(Code, Out, Err) {
		State.Calls += 1, State.Code := Code, State.Output := Out . Err
	}
	try {
		for Name in ["full.json", "live.json", "range.json"]
			FileCopy(Root . Name, Directory . "\" . Name, false)
		Handle := ShellRunner_SpawnTreeOwned("node.exe", [Script, Directory, Kind], Complete)
		AssertTrue(Handle.start(), "The real Node frontend process must start")
		Started := A_TickCount
		while State.Calls = 0 && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		for Line in StrSplit(StrReplace(State.Output, "`r`n", "`n"), "`n")
			if Trim(Line) != ""
				_TestPrint("# live-frontend " . Line)
		AssertEqual(1, State.Calls, "The exact frontend process must settle")
		AssertEqual(0, State.Code, "The actual typing frontend must retain and refresh its visible inventory")
		AssertContains(State.Output, "PASS live-inventory-composed " . Kind)
	} finally {
		Retired := !IsObject(Handle) || Handle.terminate()
		if Retired
			DirDelete(Directory, true)
		else
			RetirementDebt := {Handle: Handle, Directory: Directory}
		AssertTrue(Retired, "The exact Node process tree must retire before its separate input directory is deleted")
	}
}
_KLDL_Count(Data, Kind, Token) {
	return Data.Has(Kind) && Data[Kind] is Map && Data[Kind].Has(Token) ? Data[Kind][Token].Get("c", 0) : 0
}
_KLDL_Case(Kind) {
	global _TimingsCache
	SavedRegistry := _TimingsCache, SavedTimings := KLW_TimingValues()
	PreviousCritical := Critical("Off")
	Fields := ["MAX_KEYSTROKE_DELAY_MS", "THINK_PAUSE_MS", "BURST_GAP_MS", "SESSION_GAP_MS", "AUTO_REPEAT_MAX_DELAY_MS", "HOLD_THRESHOLD_MS"]
	try {
		TimingsLoadShared()
		KeystatsWalkerLoadTimings()
		_KLRDC_EnsureSharedDir()
		_KLRDC_Reset()
		Today := FormatTime(A_Now, "yyyy-MM-dd")
		Characters := ["a", "b", "c", "d", "e", "f", "g"]
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			Today . " 10:00:00.000", Today, "fixture.exe", Characters))
		Db := _KLRDC_BuildAsWorker()
		Full := KLPF_BuildTyping(Db, "full", true, Today, true)
		FullToday := JsonParse(Full["__klpf_prefetch_json"])["today"]["fixture.exe"]
		Seed := KLPF_CaptureHistorySeed(_KLRDC_Root(), Today)
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(2,
			Today . " 10:00:01.000", Today, "fixture.exe", Characters))
		Db := _KLRDC_BuildAsWorker()
		AssertTrue(KLPF_HistorySeedAllowsDelta(Seed, KLPF_CaptureHistorySeed(_KLRDC_Root(), Today)),
			"The actual durable same-day append must be admitted to the production live mode")
		Live := KLPF_BuildTyping(Db, "live", false, Today, true)
		for Spec in [["pg", "ngram_pentagrams", "abcde"], ["hx", "ngram_hexagrams", "abcdef"], ["hp", "ngram_heptagrams", "abcdefg"]] {
			Raw := SQLite_Query(Db, "SELECT SUM(c) AS c FROM " . Spec[2]
				. " WHERE app='fixture.exe' AND token=" . SQLite_Q(Spec[3]) . ";")[1]["c"]
			_TestPrint("# LIVE_DEPTH kind=" . Spec[1] . " initial_full=" . _KLDL_Count(FullToday, Spec[1], Spec[3])
				. " rebuilt_raw=" . Raw . " live=" . _KLDL_Count(JsonParse(Live["__klpf_today_json"])["fixture.exe"], Spec[1], Spec[3]))
			AssertEqual(1, _KLDL_Count(FullToday, Spec[1], Spec[3]))
			AssertEqual(2, Raw, "The genuine source contains both occurrences before frontend delivery")
		}
		Root := _KLRDC_Root()
		AssertTrue(FSWriteCreateDurable(Root . "full.json", KLPF_SerializeBlob(Full)))
		AssertTrue(FSWriteCreateDurable(Root . "live.json", KLPF_SerializeBlob(Live)))
		AssertTrue(FSWriteCreateDurable(Root . "range.json", KLR_BuildRangeSplitTodayJson(Db, Today, Today, ["fixture.exe"], Today)))
		_KLDL_Frontend(Root, Kind)
	} finally {
		try _KLRDC_Cleanup()
		finally {
			Critical("On")
			try {
				_TimingsCache := SavedRegistry
				for Index, Field in Fields
					KLWConst.%Field% := SavedTimings[Index]
			} finally Critical(PreviousCritical)
		}
	}
}
for _KLDL_Kind in ["chars", "deep"]
	Test("Keystats live projection: " . _KLDL_Kind . " retains visible same-day typing inventory through the genuine frontend (klr-live-deep-inventory)",
		_KLRDC_CheckTeardown.Bind(_KLDL_Case.Bind(_KLDL_Kind)))

_KLRManifest_DetachedForeground(Mode) {
	Saved := KLRForegroundProjection.worker_snapshot
	HookBefore := [KLHook.prev_app, KLHook.app_entered_at, KLHook.last_tick, KLWatch.last_authorized_tick]
	Day := "2026-11-05", App := "owned-detached-editor.exe"
	Wire := Map("app", App, "origin", 0x100000000 + 50, "now", 0x100000000 + 150,
		"activity", 0x100000000 + 100, "day", Day, "timeout", 1000)
	if Mode == "expired"
		Wire["now"] := Wire["activity"] + Wire["timeout"]
	Manifest := Map(), Cell := KLR_GetCell(Manifest, Day, App)
	Cell["app_time_ms"] := 17
	try {
		KLRForegroundProjection.worker_snapshot := Wire
		KLR_AddLiveForegroundTime(Manifest, Mode == "bounds" ? "2026-11-06" : Day, Day)
		AssertEqual(Mode == "live" ? 117 : 17, Cell["app_time_ms"],
			"a detached projection must use the captured native64 clock, exact date bounds and captured abandonment authority")
		AssertEqual(1, Manifest.Count)
		AssertEqual(1, Manifest[Day].Count)
		for Index, Actual in [KLHook.prev_app, KLHook.app_entered_at, KLHook.last_tick, KLWatch.last_authorized_tick]
			AssertEqual(HookBefore[Index], Actual, "projecting transported context cannot fabricate or advance resident hook/session state")
	} finally KLRForegroundProjection.worker_snapshot := Saved
}
for _KLRManifest_DetachedMode in ["live", "expired", "bounds"]
	Test("Keystats detached foreground: " . _KLRManifest_DetachedMode . " preserves pure projection (klr-detached-foreground)",
		_KLRManifest_DetachedForeground.Bind(_KLRManifest_DetachedMode))
