; tests/unit/test_metrics_widget_menu_parity.ahk

; ==============================================================================
; MODULE: Native Metrics Widget Menu Parity (Windows)
; DESCRIPTION:
; Reads the same exhaustive state vectors as both Lua suites and inspects the
; actual Win32 menu labels, checkmarks and enabled states. Only the native
; widget state is replaced; no window is opened or manually clicked.
; ==============================================================================

#Requires AutoHotkey v2.0

_MWMP_AnchorPosition(Target, Label) {
	Count := DllCall("GetMenuItemCount", "Ptr", Target.Handle, "Int")
	Found := -1
	Loop Count {
		Position := A_Index - 1
		Length := DllCall("GetMenuStringW", "Ptr", Target.Handle, "UInt", Position,
			"Ptr", 0, "Int", 0, "UInt", 0x400, "Int")
		Text := Buffer((Max(Length, 0) + 1) * 2, 0)
		DllCall("GetMenuStringW", "Ptr", Target.Handle, "UInt", Position,
			"Ptr", Text, "Int", Max(Length, 0) + 1, "UInt", 0x400, "Int")
		if StrGet(Text, "UTF-16") == Label {
			AssertEqual(-1, Found, "the floating widget group is drawn only once")
			Found := Position
		}
	}
	Assert(Found >= 0, "the floating widget group must be reachable")
	return Found
}

_MWMP_RenderVector(Vector, Fields, Specs) {
	global MetricsShortcuts
	Saved := Map("enabled", MetricsShortcuts.enabled, "visible", WPMWidget.visible,
		"colors", WPMWidget.use_colors, "graph", WPMWidget.show_graph)
	Values := Map()
	for Index, Key in Fields
		Values[Key] := Vector["state"][Index]
	Target := 0
	try {
		MetricsShortcuts.enabled := Values["keylogger_enabled"]
		WPMWidget.visible := Values["wpm_widget_visible"]
		WPMWidget.use_colors := Values["metrics_widget_colors"]
		WPMWidget.show_graph := Values["metrics_widget_graph"]
		Target := BuildMetricsMenu()
		Start := _MWMP_AnchorPosition(Target, t(Specs[1]["i18n"]))
		for Index, Spec in Specs {
			Position := Start + Index - 1
			Label := t(Spec["i18n"])
			AssertEqual(Position, _MWMP_AnchorPosition(Target, Label), Spec["id"] . " follows the declared group order")
			State := DllCall("GetMenuState", "Ptr", Target.Handle, "UInt", Position, "UInt", 0x400, "UInt")
			AssertEqual(Vector["checked"][Index], (State & 0x8) != 0, Spec["id"] . " retains its stored check")
			AssertEqual(Vector["disabled"][Index], (State & 0x3) != 0, Spec["id"] . " follows the shared gate")
			AssertEqual(0, State & 0x800, Spec["id"] . " is a real row, never a separator")
		}
	} finally {
		if Target is Menu
			Target.Delete()
		MetricsShortcuts.enabled := Saved["enabled"]
		WPMWidget.visible := Saved["visible"]
		WPMWidget.use_colors := Saved["colors"]
		WPMWidget.show_graph := Saved["graph"]
	}
}

_MWMP_DeclaredChecks(Specs) {
	Rows := _MR_GetMenuDef("metrics_menu")
	for Spec in Specs {
		Found := false
		for Row in Rows {
			if _MR_Get(Row, "id", "") == Spec["id"] {
				AssertEqual("check", _MR_Get(Row, "type", ""), Spec["id"] . " belongs to the shared renderer")
				Found := true
			}
		}
		AssertTrue(Found, Spec["id"] . " belongs to the shared declaration")
	}
}

_MWMP_Register() {
	global _SharedDir
	Fixture := JsonParse(FileRead(_SharedDir . "\tests\corpus\metrics\widget_menu_vectors.json", "UTF-8"))
	Test("metrics-widget-parity declared checks", _MWMP_DeclaredChecks.Bind(Fixture["rows"]))
	for Vector in Fixture["cases"]
		Test("metrics-widget-parity " . Vector["id"],
			_MWMP_RenderVector.Bind(Vector, Fixture["fields"], Fixture["rows"]))
}
_MWMP_Register()
