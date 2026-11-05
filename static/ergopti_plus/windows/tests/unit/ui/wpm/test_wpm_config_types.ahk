; static/ergopti_plus/windows/tests/unit/ui/wpm/test_wpm_config_types.ahk

; ============================================================================
; MODULE: WPM Widget Config Type Boundary Tests
; DESCRIPTION:
; Exercises the production WPM config reader with native TOML scalar values.
; ============================================================================

_TWCT_Areas := [{ Left: 0, Top: 0, Right: 1920, Bottom: 1080 }]

; The Storage port holds no position: the anchor stays at its default.
_TWCT_NoStoredPosition(Key) => "_"

; A Storage port double holding one saved anchor.
_TWCT_StoredPosition(X, Y, Key) => Key == WPMWidgetConst.STORE_X ? X : Y

TestWPMConfigRejectsStringEncodedBooleans() {
	SavedVisible := WPMWidget.visible
	SavedColors := WPMWidget.use_colors
	SavedGraph := WPMWidget.show_graph
	try {
		WPMWidget.visible := false
		WPMWidget.use_colors := false
		WPMWidget.show_graph := false
		Thrown := false
		try WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, "1",
			WPMWidgetConst.CFG_COLORS, "1",
			WPMWidgetConst.CFG_GRAPH, "1")), _TWCT_Areas, _TWCT_NoStoredPosition)
		catch
			Thrown := true
		AssertTrue(Thrown,
			"string-encoded booleans must fail before WPM state publication")
		AssertFalse(WPMWidget.visible)
		AssertFalse(WPMWidget.use_colors)
		AssertFalse(WPMWidget.show_graph)

		WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, true,
			WPMWidgetConst.CFG_COLORS, true,
			WPMWidgetConst.CFG_GRAPH, true)), _TWCT_Areas, _TWCT_NoStoredPosition)
		AssertTrue(WPMWidget.visible)
		AssertTrue(WPMWidget.use_colors)
		AssertTrue(WPMWidget.show_graph)
	} finally {
		WPMWidget.visible := SavedVisible
		WPMWidget.use_colors := SavedColors
		WPMWidget.show_graph := SavedGraph
	}
}
Test("WPM config: boolean fields preserve TOML types (AHK-101)",
	TestWPMConfigRejectsStringEncodedBooleans)

; An absent key used to read as false whatever the manifest shipped, and
; SaveFullConfig then wrote that false back (decision of 2026-11-03: the graph
; and colours ship on).
TestWPMConfigAbsentKeysTakeManifestDefaults() {
	SavedVisible := WPMWidget.visible
	SavedColors := WPMWidget.use_colors
	SavedGraph := WPMWidget.show_graph
	try {
		WPMWidget.visible := !ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_VISIBLE)
		WPMWidget.use_colors := !ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_COLORS)
		WPMWidget.show_graph := !ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_GRAPH)
		WPMWidget_LoadConfig(Map("metrics", Map()), _TWCT_Areas, _TWCT_NoStoredPosition)
		AssertEqual(ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_VISIBLE), WPMWidget.visible)
		AssertEqual(ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_COLORS), WPMWidget.use_colors)
		AssertEqual(ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_GRAPH), WPMWidget.show_graph)
		AssertTrue(WPMWidget.use_colors && WPMWidget.show_graph && !WPMWidget.visible,
			"an empty configuration shows colours and graph, the pill itself stays hidden")
	} finally {
		WPMWidget.visible := SavedVisible
		WPMWidget.use_colors := SavedColors
		WPMWidget.show_graph := SavedGraph
	}
}
Test("WPM config: absent widget booleans take the manifest default",
	TestWPMConfigAbsentKeysTakeManifestDefaults)

TestWPMConfigValidatesSavedPositionAgainstEveryMonitor() {
	WorkAreas := [
		{ Left: 0, Top: 0, Right: 1920, Bottom: 1080 },
		{ Left: 0, Top: 1080, Right: 1920, Bottom: 2160 }
	]
	AssertTrue(_WPMWidget_RectCenterIsOnScreen(100, 100, 80, 68,
		WorkAreas), "a position on the primary monitor must remain valid")
	AssertTrue(_WPMWidget_RectCenterIsOnScreen(100, 1400, 80, 68,
		WorkAreas), "a position on a lower secondary monitor must remain valid")
	AssertFalse(_WPMWidget_RectCenterIsOnScreen(5000, 100, 80, 68,
		WorkAreas), "a position on a disconnected monitor must be rejected")
	AssertFalse(_WPMWidget_RectCenterIsOnScreen(-5000, -5000, 80, 68,
		WorkAreas), "a wholly off-screen negative position must be rejected")

	SavedX := WPMWidget.pos_x
	SavedY := WPMWidget.pos_y
	SavedStoreX := WPMWidgetConst.STORE_X
	SavedStoreY := WPMWidgetConst.STORE_Y
	try {
		WPMWidgetConst.STORE_X := "test.pos_x"
		WPMWidgetConst.STORE_Y := "test.pos_y"
		WPMWidget.pos_x := -1
		WPMWidget.pos_y := -1
		WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, false,
			WPMWidgetConst.CFG_COLORS, false,
			WPMWidgetConst.CFG_GRAPH, false)), WorkAreas,
			_TWCT_StoredPosition.Bind(5000, 100))
		AssertEqual(-1, WPMWidget.pos_x,
			"the loader must discard a disconnected-monitor X coordinate")
		AssertEqual(-1, WPMWidget.pos_y,
			"the loader must discard the off-screen position as one atomic pair")

		WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, false,
			WPMWidgetConst.CFG_COLORS, false,
			WPMWidgetConst.CFG_GRAPH, false)), WorkAreas,
			_TWCT_StoredPosition.Bind(100, 1400))
		AssertEqual(100, WPMWidget.pos_x)
		AssertEqual(1400, WPMWidget.pos_y,
			"the loader must preserve a valid lower-monitor coordinate")
	} finally {
		WPMWidget.pos_x := SavedX
		WPMWidget.pos_y := SavedY
		WPMWidgetConst.STORE_X := SavedStoreX
		WPMWidgetConst.STORE_Y := SavedStoreY
	}
}
Test("WPM config: saved surfaces remain reachable after monitor changes (AHK-104)",
	TestWPMConfigValidatesSavedPositionAgainstEveryMonitor)

; A single negative-one coordinate is a real screen position, not the sentinel.
TestWPMAutoPositionRequiresBothCoordinates() {
	AssertTrue(_WPMWidget_IsAutoPosition(-1, -1), "the legacy sentinel selects the default")
	AssertFalse(_WPMWidget_IsAutoPosition(-1, 100), "a left-edge position must survive")
	AssertFalse(_WPMWidget_IsAutoPosition(100, -1), "a top-edge position must survive")
	AssertFalse(_WPMWidget_IsAutoPosition(100, 100), "a saved position must survive")
	SavedX := WPMWidget.pos_x, SavedY := WPMWidget.pos_y
	SavedVisible := WPMWidget.visible, SavedColors := WPMWidget.use_colors, SavedGraph := WPMWidget.show_graph
	SavedStoreX := WPMWidgetConst.STORE_X, SavedStoreY := WPMWidgetConst.STORE_Y
	try {
		WPMWidgetConst.STORE_X := "test.pos_x", WPMWidgetConst.STORE_Y := "test.pos_y"
		for Pair in [[-1, 100], [100, -1]] {
			WPMWidget_LoadConfig(Map("metrics", Map(WPMWidgetConst.CFG_GRAPH, false)),
				_TWCT_Areas, _TWCT_StoredPosition.Bind(Pair[1], Pair[2]))
			AssertEqual(Pair[1], WPMWidget.pos_x, "the saved X reaches the surface anchor")
			AssertEqual(Pair[2], WPMWidget.pos_y, "the saved Y reaches the surface anchor")
			AssertFalse(_WPMWidget_IsAutoPosition(WPMWidget.pos_x, WPMWidget.pos_y))
		}
	} finally {
		WPMWidget.pos_x := SavedX, WPMWidget.pos_y := SavedY
		WPMWidget.visible := SavedVisible, WPMWidget.use_colors := SavedColors, WPMWidget.show_graph := SavedGraph
		WPMWidgetConst.STORE_X := SavedStoreX, WPMWidgetConst.STORE_Y := SavedStoreY
	}
}
Test("WPM config: one negative-one coordinate is a position (wpm-anchor-sentinel)",
	TestWPMAutoPositionRequiresBothCoordinates)

_WPMCO_RefusedConfig(Kind, Successor) {
	global ConfigurationFile, STORAGE_REG_BASE, _SharedDir
	Saved := {path: ConfigurationFile, store: STORAGE_REG_BASE, x: WPMWidget.pos_x,
		y: WPMWidget.pos_y, graph: WPMWidget.show_graph, colors: WPMWidget.use_colors,
		keyX: WPMWidgetConst.STORE_X, keyY: WPMWidgetConst.STORE_Y}
	Nonce := A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Subkey := "Software\Ergopti_WpmCompensationAudit_" . Nonce
	RegistryPath := "HKCU\" . Subkey
	Root := A_Temp . "\ergopti_wpm_compensation_" . Nonce
	Path := Root . "\config.toml"
	Handle := 0, OwnedKey := false, CreatedRoot := false, Lease := 0
	State := {notices: 0, bCalls: 0, bAck: false, bX: "unset", bY: "unset"}
	Notify(Message, Options) {
		State.notices += 1
		if Successor {
			State.bCalls += 1
			State.bAck := WPMWidget_SavePosition(700, 800, 0, (*) => 0)
			State.bX := ST_Get(WPMWidgetConst.STORE_X, "missing")
			State.bY := ST_Get(WPMWidgetConst.STORE_Y, "missing")
		}
	}
	try {
		AssertFalse(A_IsSuspended)
		Disposition := 0
		Status := DllCall("Advapi32\RegCreateKeyExW", "Ptr", -2147483647,
			"Str", Subkey, "UInt", 0, "Ptr", 0, "UInt", 0, "UInt", 3,
			"Ptr", 0, "Ptr*", &Handle, "UInt*", &Disposition, "UInt")
		OwnedKey := Status == 0 && Disposition == 1
		AssertTrue(OwnedKey, "acquire a genuinely new private storage key before any value write")
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		CreatedRoot := (Creation is Integer) && Creation == 1
		AssertTrue(CreatedRoot)
		Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[metrics]`nwpm_widget_graph = false`n"
		AssertTrue(FSWriteCreateDurable(Path, Source))
		ConfigurationFile := Path
		Boot := ConfigMigrateBoot(Path)
		AssertEqual("current", Boot["status"])
		STORAGE_REG_BASE := RegistryPath
		Canon := ParseTomlFile(_SharedDir . "\modules\wpm_widget\constants.toml")
		WPMWidgetConst.STORE_X := Canon["position"]["storage_x"]
		WPMWidgetConst.STORE_Y := Canon["position"]["storage_y"]
		AssertTrue(WPMWidgetConst.STORE_X != WPMWidgetConst.STORE_Y)
		WPMWidget.show_graph := false, WPMWidget.use_colors := false
		AssertTrue(WPMWidget_SavePosition(10, 20, 0, (*) => 0))
		AssertEqual(10, ST_Get(WPMWidgetConst.STORE_X, "missing"))
		AssertEqual(20, ST_Get(WPMWidgetConst.STORE_Y, "missing"))
		Lease := _ConfigWriteLeaseTryAcquire(Path, "wpm-native-compensation-proof")
		AssertTrue(Lease is Object, "the real competing configuration owner must be acquired")
		if Kind == "graph-toggle"
			Result := WPMWidget_ToggleGraphConfig(0, Notify)
		else
			Result := WPMWidget_SaveConfig(false, true, 30, 40, 0, Notify)
		ActualX := ST_Get(WPMWidgetConst.STORE_X, "missing")
		ActualY := ST_Get(WPMWidgetConst.STORE_Y, "missing")
		_TestPrint("# wpm-compensation kind=" . Kind . " successor=" . Successor
			. " notices=" . State.notices . " b_calls=" . State.bCalls . " b_ack=" . State.bAck
			. " b_stored_x=" . State.bX . " b_stored_y=" . State.bY
			. " a_result=" . Result . " ram_x=" . WPMWidget.pos_x . " ram_y=" . WPMWidget.pos_y
			. " final_stored_x=" . ActualX . " final_stored_y=" . ActualY)
		AssertFalse(Result, "the actual config lease refuses A's configuration mutation")
		AssertTrue(_ConfigWriteLeaseOwns(Lease, Path))
		AssertEqual(1, State.notices, "the real failure-notification boundary must run once")
		AssertEqual(Successor ? 1 : 0, State.bCalls)
		if Successor {
			AssertTrue(State.bAck, "the independent public B position change must genuinely acknowledge native storage")
			AssertEqual(700, State.bX)
			AssertEqual(800, State.bY)
		}
		ExpectedX := Successor ? 700 : 10, ExpectedY := Successor ? 800 : 20
		AssertEqual(ExpectedX, ActualX, "refused A cannot compensate over an acknowledged successor's durable X position")
		AssertEqual(ExpectedY, ActualY)
		AssertEqual(ExpectedX, WPMWidget.pos_x)
		AssertEqual(ExpectedY, WPMWidget.pos_y)
		AssertFalse(WPMWidget.show_graph, "A's refused graph change stays unpublished")
		AssertEqual(Source, FSReadUtf8Exact(Path), "the competing config lease leaves the real source unchanged")
	} finally {
		try {
			if Lease is Object
				_ConfigWriteLeaseRelease(Lease)
			ConfigurationFile := Saved.path, STORAGE_REG_BASE := Saved.store
			WPMWidget.pos_x := Saved.x, WPMWidget.pos_y := Saved.y
			WPMWidget.show_graph := Saved.graph, WPMWidget.use_colors := Saved.colors
			WPMWidgetConst.STORE_X := Saved.keyX, WPMWidgetConst.STORE_Y := Saved.keyY
			if CreatedRoot {
				try _TOML_InvalidateParseCache(Path)
				finally DirDelete(Root, true)
			}
		} finally {
			if Handle
				DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
			if OwnedKey
				AssertEqual(0, DllCall("Advapi32\RegDeleteKeyW", "Ptr", -2147483647,
					"Str", Subkey, "UInt"), "delete only this exclusively created storage key")
		}
	}
}
for _WPMCO_Kind in ["save-config", "graph-toggle"] {
	Test("WPM compensation ownership: " . _WPMCO_Kind . " successor", _WPMCO_RefusedConfig.Bind(_WPMCO_Kind, true))
	Test("WPM compensation ownership: " . _WPMCO_Kind . " ordinary-refusal-control", _WPMCO_RefusedConfig.Bind(_WPMCO_Kind, false))
}
