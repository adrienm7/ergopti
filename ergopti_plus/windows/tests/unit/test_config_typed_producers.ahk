; tests/unit/test_config_typed_producers.ahk

; ==============================================================================
; MODULE: Configuration Boolean Producer Tests
; DESCRIPTION:
; Exercises legacy widget and foreign-owned gesture producers through real
; temporary-file persistence, without showing windows or configuring hardware.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Widget Persistence =======
; =====================================
; =====================================

_CTP_WidgetRoundtrip() {
	global ConfigurationFile
	OldPath := ConfigurationFile
	OldWidget := [WPMWidget.visible, WPMWidget.use_colors, WPMWidget.show_graph,
		WPMWidget.pos_x, WPMWidget.pos_y]
	Path := _CTU_NewPath()
	try {
		ConfigurationFile := Path
		AssertTrue(WPMWidget_SaveVisible(true, 0, (*) => 0))
		AssertTrue(WPMWidget_SaveConfig(true, false, 1, 0, 0, (*) => 0))
		Target := ManifestBuildFeaturesMap()
		Target["metrics"][WPMWidgetConst.CFG_VISIBLE] := false
		Target["metrics"][WPMWidgetConst.CFG_COLORS] := false
		Target["metrics"][WPMWidgetConst.CFG_GRAPH] := true
		ApplyConfigToml(Target, Path)
		AssertEqual(true, Target["metrics"][WPMWidgetConst.CFG_VISIBLE])
		AssertEqual(true, Target["metrics"][WPMWidgetConst.CFG_COLORS])
		AssertEqual(false, Target["metrics"][WPMWidgetConst.CFG_GRAPH])
		Parsed := TOML_ParseFreshFile(Path)["metrics"]
		AssertTrue(Parsed[WPMWidgetConst.CFG_X] is Integer)
		AssertTrue(Parsed[WPMWidgetConst.CFG_Y] is Integer)
		AssertEqual(1, Parsed[WPMWidgetConst.CFG_X])
		AssertEqual(0, Parsed[WPMWidgetConst.CFG_Y])
	} finally {
		ConfigurationFile := OldPath
		WPMWidget.visible := OldWidget[1]
		WPMWidget.use_colors := OldWidget[2]
		WPMWidget.show_graph := OldWidget[3]
		WPMWidget.pos_x := OldWidget[4]
		WPMWidget.pos_y := OldWidget[5]
		FSDelete(Path)
	}
}
Test("config: WPM producers persist Boolean flags and numeric coordinates "
	. "(config-typed-wpm-producers)", _CTP_WidgetRoundtrip)





; ============================================
; ============================================
; ======= 2/ Foreign Gesture Ownership =======
; ============================================
; ============================================

_CTP_GestureMarker() {
	Path := _CTU_NewPath()
	Seen := []
	try {
		AssertTrue(FSWrite(Path, "[gestures]`nauto_configure_on_next_start = true`n"))
		AssertTrue(GestureConsumeAutoConfigureFlag(Path, 0, (*) => 0,
			(Callback, Delay) => Seen.Push({ content: FSRead(Path), delay: Delay })))
		AssertEqual(1, Seen.Length)
		AssertTrue(Seen[1].delay < 0)
		AssertTrue(RegExMatch(Seen[1].content, "m)^auto_configure_on_next_start = false$"),
			"the foreign-owned marker must be a durable Boolean before hardware work is scheduled")
	} finally FSDelete(Path)
}
Test("config: gesture marker consumption preserves foreign Boolean intent "
	. "(config-typed-gesture-marker)", _CTP_GestureMarker)
