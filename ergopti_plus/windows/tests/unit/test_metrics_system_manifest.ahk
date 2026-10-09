; tests/unit/test_metrics_system_manifest.ahk

; ==============================================================================
; MODULE: System Metrics Manifest Tests
; DESCRIPTION: Deliver cross-device system totals through normal, encoded and live manifests.
; ==============================================================================

#Requires AutoHotkey v2.0

_MMS_Check(Manifest) {
	AssertTrue(Manifest.Has("2026-01-01") && Manifest["2026-01-01"].Has("_system"),
		"the dashboard must receive system counters alongside application cells")
	System := Manifest["2026-01-01"]["_system"]
	for Field, Expected in Map("wifi_changes", 11, "space_switches", 22,
		"battery_sum", 180, "battery_count", 4, "battery_min", 0, "battery_max", 80,
		"audio_muted_ms", 33, "locked_ms", 44, "sleep_ms", 55, "awake_ms", 66,
		"passive_count", 77, "night_wake_count", 88)
		AssertEqual(Expected, System[Field], "cross-device system field " . Field)
	AssertFalse(System.Has("chars"), "system totals are not typing application metrics")
	AssertFalse(System.Has("hourly"), "system counters do not carry typing time series")
	AssertTrue(Manifest.Has("2026-01-02"), "a system-only day must not disappear")
	EmptyBattery := Manifest["2026-01-02"]["_system"]
	AssertEqual(0, EmptyBattery["battery_count"])
	AssertFalse(EmptyBattery.Has("battery_min"), "absent battery samples are not zero-percent readings")
	AssertFalse(EmptyBattery.Has("battery_max"))
}

_MMS_Projection(Db, Mode) {
	global Features, KLPF_MANIFEST_CACHE
	SavedApp := KLHook.prev_app
	SavedFeatures := Features
	HadCache := IsSet(KLPF_MANIFEST_CACHE)
	SavedCache := HadCache ? KLPF_MANIFEST_CACHE : 0
	try {
		KLHook.prev_app := ""
		Features := Map("layout", Map("ergopti_base", false))
		KLPF_MANIFEST_CACHE := unset
		_KLRDC_EnsureSharedDir()
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, "INSERT INTO agg_system_day(device_id,date,wifi_changes,space_switches,"
			. "battery_sum,battery_count,battery_min,battery_max,audio_muted_ms,locked_ms,sleep_ms,awake_ms,"
			. "passive_count,night_wake_count) VALUES"
			. "('one','2026-01-01',1,2,100,2,40,60,3,4,5,6,7,8),"
			. "('two','2026-01-01',10,20,80,1,80,80,30,40,50,60,70,80);"
			. "INSERT INTO agg_system_day(device_id,date,battery_sum,battery_count,battery_min,battery_max)"
			. " VALUES('zero','2026-01-01',0,1,0,0),('one','2026-01-02',NULL,0,9,99);"
			. "INSERT INTO agg_app_day(device_id,date,app,chars) VALUES('one','2026-01-01','editor.exe',3);"))
		if Mode = "normal" {
			Manifest := KLR_ReadManifest(Db)
			_MMS_Check(Manifest)
			Selected := KLR_ReadManifest(Db, "2026-01-02", "2026-01-02")
			AssertEqual(1, Selected.Count)
			AssertTrue(Selected["2026-01-02"].Has("_system"))
			AssertEqual(0, KLR_ReadManifest(Db, "2026-01-03").Count)
		} else if Mode = "encoded" {
			Manifest := _MMJ_Compare(Db, 0)
			_MMS_Check(Manifest)
			Selected := _MMJ_Compare(Db, 0, "2026-01-02", "2026-01-02")
			AssertEqual(1, Selected.Count)
			AssertTrue(Selected["2026-01-02"].Has("_system"))
		} else {
			Blob := KLPF_BuildTyping(Db, "full")
			_MMS_Check(Blob["metrics_manifest"])
			Apps := KLPF_UniqueAppsFromManifest(Blob["metrics_manifest"])
			AssertEqual(1, Apps.Length, "system pseudo-apps must not enter n-gram filters")
			AssertEqual("editor.exe", Apps[1])
			_MMJ_CacheIsolation(Db, Blob["metrics_manifest"])
			AssertTrue(SQLite_Exec(Db, "UPDATE agg_system_day SET sleep_ms=9 WHERE date='2026-01-02';"))
			Live := KLPF_BuildTyping(Db, "live", false, "2026-01-02")
			AssertEqual(9, Live["metrics_manifest"]["2026-01-02"]["_system"]["sleep_ms"])
			_MMS_Check(Live["metrics_manifest"])
			for Encode in [false, true] {
				Full := KLPF_BuildTyping(Db, "full", true, "2026-01-02", Encode)
				Manifest := Encode ? JsonParse(Full["__klpf_manifest_json"]) : Full["metrics_manifest"]
				_MMS_Check(Manifest)
				AssertEqual(9, Manifest["2026-01-02"]["_system"]["sleep_ms"])
			}
		}
	} finally {
		KLHook.prev_app := SavedApp
		Features := SavedFeatures
		KLPF_MANIFEST_CACHE := HadCache ? SavedCache : unset
	}
}

for Mode in ["normal", "encoded", "publication"]
	Test("system manifest: " . Mode . " preserves daily system totals (metrics-system-manifest)",
		_SQLRD_WithDatabase.Bind(_MMS_Projection.Bind(, Mode)))
