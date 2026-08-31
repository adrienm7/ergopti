; static/ergopti_plus/windows/tests/unit/test_wpm_config_types.ahk

; ============================================================================
; MODULE: WPM Widget Config Type Boundary Tests
; DESCRIPTION:
; Exercises the production WPM config reader with native TOML scalar values.
; ============================================================================

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
			WPMWidgetConst.CFG_GRAPH, "1")))
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
			WPMWidgetConst.CFG_GRAPH, true)))
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
	try {
		WPMWidget.pos_x := -1
		WPMWidget.pos_y := -1
		WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, false,
			WPMWidgetConst.CFG_COLORS, false,
			WPMWidgetConst.CFG_GRAPH, false,
			WPMWidgetConst.CFG_X, 5000,
			WPMWidgetConst.CFG_Y, 100)), WorkAreas)
		AssertEqual(-1, WPMWidget.pos_x,
			"the loader must discard a disconnected-monitor X coordinate")
		AssertEqual(-1, WPMWidget.pos_y,
			"the loader must discard the off-screen position as one atomic pair")

		WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, false,
			WPMWidgetConst.CFG_COLORS, false,
			WPMWidgetConst.CFG_GRAPH, false,
			WPMWidgetConst.CFG_X, 100,
			WPMWidgetConst.CFG_Y, 1400)), WorkAreas)
		AssertEqual(100, WPMWidget.pos_x)
		AssertEqual(1400, WPMWidget.pos_y,
			"the loader must preserve a valid lower-monitor coordinate")
	} finally {
		WPMWidget.pos_x := SavedX
		WPMWidget.pos_y := SavedY
	}
}
Test("WPM config: saved surfaces remain reachable after monitor changes (AHK-104)",
	TestWPMConfigValidatesSavedPositionAgainstEveryMonitor)
