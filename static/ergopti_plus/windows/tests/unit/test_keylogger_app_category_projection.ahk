; tests/unit/test_keylogger_app_category_projection.ahk

; ==============================================================================
; MODULE: Keylogger App Category Projection Regression Tests
; DESCRIPTION:
; Proves a category attached to a typing event survives the durable writer and
; reaches both warm incremental and cold reader aggregate projections.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ Durable category flow =======
; ========================================
; ========================================

_KLACP_Entry(Timestamp, App, Category) {
	return Map(
		"type", "typing",
		"timestamp", Timestamp,
		"app", App,
		"app_category", Category,
		"title", "Category projection fixture",
		"layout", "fr",
		"pause_before_ms", 0,
		"text", "a",
		"events", [["a", 20, Map("kc", 65, "sk", 30)]])
}

_KLACP_AssertCategory(Db, DeviceId, Date, App, Expected) {
	Raw := SQLite_Query(Db,
		"SELECT app_category FROM events_typing WHERE device_id="
		. SQLite_Q(DeviceId) . " AND app=" . SQLite_Q(App)
		. " ORDER BY id DESC LIMIT 1;")
	AssertEqual(1, Raw.Length)
	AssertEqual(Expected, Raw[1]["app_category"],
		"the durable typing row must retain its category")

	Aggregate := SQLite_Query(Db,
		"SELECT category FROM agg_app_day WHERE device_id="
		. SQLite_Q(DeviceId) . " AND date=" . SQLite_Q(Date)
		. " AND app=" . SQLite_Q(App) . ";")
	AssertEqual(1, Aggregate.Length)
	AssertEqual(Expected, Aggregate[1]["category"],
		"the reader aggregate must expose the latest durable category")

	Manifest := KLR_ReadManifest(Db, Date, Date)
	AssertEqual(Expected, Manifest[Date][App]["category"],
		"the dashboard manifest must receive the aggregate category")
}

_KLACP_WarmAndColdRebuildKeepLatestCategory() {
	global KL_ENC_Enabled
	static ModuleHandle := 0
	Root := A_Temp . "\ergopti_app_category_projection_" . A_TickCount
	DeviceId := "category-device"
	App := "category-editor.exe"
	Date := "2026-08-28"
	DeviceDir := Root . "\by_device\" . DeviceId
	LedgerPath := DeviceDir . "\data.sql"
	SavedDeviceId := Keylogger.device_id
	SavedDeviceLit := Keylogger._device_id_lit
	SavedEncryption := KL_ENC_Enabled
	try {
		if !ModuleHandle
			ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
		AssertTrue(ModuleHandle != 0)
		DirCreate(DeviceDir)
		Keylogger.device_id := DeviceId
		Keylogger._device_id_lit := KL_SqlStr(DeviceId)
		KL_Enc_SetEnabled(false)

		FirstSql := KL_BuildInsertTyping(
			_KLACP_Entry(Date . " 10:00:00.000", App, "development"), 1)
		AssertContains(FirstSql, "app_category",
			"the raw SQL writer must own the app_category column")
		FileAppend("BEGIN IMMEDIATE;" . FirstSql . "COMMIT;", LedgerPath, "UTF-8")
		KLR_ResetCache()
		WarmDb := KLR_BuildDatabase(Root . "\")
		AssertTrue(WarmDb != 0)
		_KLACP_AssertCategory(WarmDb, DeviceId, Date, App, "development")

		SecondSql := KL_BuildInsertTyping(
			_KLACP_Entry(Date . " 11:00:00.000", App, "research"), 2)
		FileAppend("BEGIN IMMEDIATE;" . SecondSql . "COMMIT;", LedgerPath, "UTF-8")
		WarmDb := KLR_BuildDatabase(Root . "\")
		AssertTrue(WarmDb != 0)
		_KLACP_AssertCategory(WarmDb, DeviceId, Date, App, "research")

		KLR_ResetCache()
		ColdDb := KLR_BuildDatabase(Root . "\")
		AssertTrue(ColdDb != 0)
		_KLACP_AssertCategory(ColdDb, DeviceId, Date, App, "research")
	} finally {
		KLR_ResetCache()
		try DirDelete(Root, true)
		Keylogger.device_id := SavedDeviceId
		Keylogger._device_id_lit := SavedDeviceLit
		KL_ENC_Enabled := SavedEncryption
	}
}

Test("Keylogger app categories: warm and cold projections keep the latest value (app-category-projection)",
	_KLACP_WarmAndColdRebuildKeepLatestCategory)
