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

; A native label is explicitly inert and carries no callback or picker data.
_MWMP_InertMigrationLabels() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\metrics\migration_status_menu.json", "UTF-8"))
	for Status in Corpus["statuses"] {
		Section := Status["section"]
		Id := Status["row"]["id"]
		Calls := Map("delivery", 0)
		Commands := Map(Id, (*) => Calls["delivery"] += 1)
		Children := Map(Id, [Map("label", "unowned child")])
		Hidden := MenuRenderer_TemplateRows(Section, Commands, Map(), Children)
		AssertEqual(0, Hidden.Length, "Linux-only label stays hidden on Windows")
		Definition := _MR_GetMenuDef(Section)[1]
		Previous := Definition["platforms"]
		Target := 0
		try {
			Definition["platforms"] := ["ahk"]
			Rows := MenuRenderer_TemplateRows(Section, Commands, Map(), Children)
			AssertEqual(1, Rows.Length, "native port renders an applicable declared label")
			AssertEqual(t(Status["row"]["i18n"]), Rows[1]["label"], "caption remains shared")
			Assert(Rows[1]["disabled"], "the label primitive is always disabled")
			AssertEqual(2, Rows[1].Count, "label data contains only its caption and inert state")
			Assert(!Rows[1].Has("action") && !Rows[1].Has("items") && !Rows[1].Has("checked"),
				"callback or child payload cannot turn the label into a command")
			Target := Menu()
			AssertEqual(1, _MR_RenderRows(Target, Rows, "metrics_inert_label_test", 1), "actual Win32 renderer draws the label")
			AssertEqual(0, _MWMP_AnchorPosition(Target, Rows[1]["label"]), "real caption is drawn first")
			State := DllCall("GetMenuState", "Ptr", Target.Handle, "UInt", 0, "UInt", 0x400, "UInt")
			Assert((State & 0x3) != 0, "native label is disabled")
			AssertEqual(0, State & 0x800, "inert status is a label, not a separator")
			AssertEqual(0, Calls["delivery"], "inert construction and drawing never deliver native callbacks")
		} finally {
			Definition["platforms"] := Previous
			if Target is Menu {
				Target.Delete()
				MenuDispatcher_PruneMenu(Target)
			}
		}
	}
}
Test("metrics: native label templates preserve platform hiding and inertness (metrics-migration-label)",
	_MWMP_InertMigrationLabels)

_MWMP_InertLabelRefusals() {
	Definition := _MR_GetMenuDef("metrics_migration_unavailable_rows")[1]
	PreviousPlatforms := Definition["platforms"]
	PreviousId := Definition["id"]
	PreviousCaption := Definition["i18n"]
	try {
		Definition["platforms"] := ["ahk"]
		for Field, Value in Map("command", "unowned_command", "caption_getter", "unowned_getter",
			"checked_when", [], "disabled", false, "foreign_field", "future", "I18N", "wrong_case") {
			Definition[Field] := Value
			try AssertEqual(false, MenuRenderer_TemplateRows("metrics_migration_unavailable_rows", Map(), Map(), Map()),
				"an inert label refuses behavior or foreign field metadata: " . Field)
			finally Definition.Delete(Field)
		}
		PreviousUnavailable := Definition["unavailable"]
		Definition["unavailable"] := ""
		try AssertEqual(false, MenuRenderer_TemplateRows("metrics_migration_unavailable_rows", Map(), Map(), Map()),
			"an inert label refuses an explicitly empty unavailable policy")
		finally Definition["unavailable"] := PreviousUnavailable
		Definition["id"] := ""
		AssertEqual(false, MenuRenderer_TemplateRows("metrics_migration_unavailable_rows", Map(), Map(), Map()),
			"an inert label needs a declared identity")
		Definition["id"] := PreviousId
		Definition["i18n"] := ""
		AssertEqual(false, MenuRenderer_TemplateRows("metrics_migration_unavailable_rows", Map(), Map(), Map()),
			"an inert label needs a declared caption")
	} finally {
		Definition["platforms"] := PreviousPlatforms
		Definition["id"] := PreviousId
		Definition["i18n"] := PreviousCaption
	}
}
Test("metrics: native label templates refuse invalid declarations (metrics-migration-label)",
	_MWMP_InertLabelRefusals)
