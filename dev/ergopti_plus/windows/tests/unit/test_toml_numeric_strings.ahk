; tests/unit/test_toml_numeric_strings.ahk

; ==============================================================================
; MODULE: TOML Numeric-Looking String Tests
; DESCRIPTION:
; Text retains its type through rendering and unrelated whole-file updates.
; Native numbers remain numbers; numeric widget producers must own that intent.
; ==============================================================================

#Requires AutoHotkey v2.0

_TNS_Render(Value) {
	AssertEqual(TOML_RenderString(Value), TOML_RenderValue(Value),
		"numeric-looking text must retain its quoted string representation")
}
for Value in ["0", "1", "001", "1.25", "1e3", ""]
	Test("TOML: preserves string '" . Value . "' (toml-numeric-string-render)",
		_TNS_Render.Bind(Value))

_TNS_WholeFileRoundtrip(BuildOnly) {
	Path := _CTU_NewPath()
	Original := '[personal_editor]`ndefault_section = "001"`ncompact_view = "0"`n'
	Updates := [{ Section: "personal_editor", Key: "close_on_add", Value: "1" }]
	try {
		AssertTrue(FSWrite(Path, Original))
		if BuildOnly {
			Content := TOML_BuildUpdatedContent(Path, Updates)
			AssertTrue(Content is Map)
			AssertEqual("ok", Content["status"])
			AssertEqual(Original, FSRead(Path), "detached rendering must not publish")
			AssertTrue(FSWrite(Path, Content["content"]))
		} else {
			AssertTrue(TOML_BatchWrite(Path, Updates))
		}
		Parsed := TOML_ParseFreshFile(Path)["personal_editor"]
		for Key, Expected in Map("default_section", "001", "compact_view", "0", "close_on_add", "1") {
			AssertTrue(Parsed[Key] is String, Key . " must remain text after an unrelated write")
			AssertEqual(Expected, Parsed[Key])
		}
	} finally FSDelete(Path)
}
Test("TOML: whole-file writes preserve numeric-looking strings (toml-numeric-string-write)",
	_TNS_WholeFileRoundtrip.Bind(false))
Test("TOML: detached builds preserve numeric-looking strings (toml-numeric-string-build)",
	_TNS_WholeFileRoundtrip.Bind(true))

_TNS_NumericControl() {
	AssertEqual("0", TOML_RenderValue(0))
	AssertEqual("1", TOML_RenderValue(1))
	AssertEqual("1.25", TOML_RenderValue(1.25))
	AssertEqual("false", TOML_RenderValue(TOML_Bool(false)))
	AssertEqual("true", TOML_RenderValue(TOML_Bool(true)))
}
Test("TOML: explicit numeric and Boolean intent remains typed (toml-numeric-string-control)",
	_TNS_NumericControl)

_TNS_WidgetProducers(Mode) {
	global _LLM_Menu
	OldX := WPMWidget.pos_x
	OldY := WPMWidget.pos_y
	try {
		WPMWidget.pos_x := -125
		WPMWidget.pos_y := 0
		switch Mode {
			case "position": Updates := _WPMWidget_BuildPositionCandidate(false, 0, false, 0).updates
			case "display": Updates := _WPMWidget_BuildDisplayCandidate(false, 0, false, 0,
				false, 0, false, 0).updates
			case "full":
				Menu := _HSDeepCloneMap(_LLM_Menu)
				Menu["onboarding_seen"] := false
				Menu["app_profile_overrides"] := Map()
				Menu["user_profiles"] := []
				Updates := _ConfigCollectFullSaveUpdates(ManifestBuildFeaturesMap(), Menu)
			default: throw ValueError("Unknown widget producer")
		}
		Coordinates := Map()
		for Update in Updates {
			if Update.Section == "metrics"
					&& (Update.Key == WPMWidgetConst.CFG_X || Update.Key == WPMWidgetConst.CFG_Y) {
				AssertTrue(Update.Value is Integer,
					"the producer must retain numeric intent before any writer coercion")
				Coordinates[Update.Key] := Update.Value
			}
		}
		AssertEqual(2, Coordinates.Count)
		AssertEqual(-125, Coordinates[WPMWidgetConst.CFG_X])
		AssertEqual(0, Coordinates[WPMWidgetConst.CFG_Y])
	} finally {
		WPMWidget.pos_x := OldX
		WPMWidget.pos_y := OldY
	}
}
for Mode in ["position", "display", "full"]
	Test("TOML: widget " . Mode . " producer retains numbers (toml-numeric-string-widget)",
		_TNS_WidgetProducers.Bind(Mode))
