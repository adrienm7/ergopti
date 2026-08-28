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
