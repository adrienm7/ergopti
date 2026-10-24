; tests/unit/infra/toml/test_toml_numeric_strings.ahk

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

_TNS_StoredAnchor(Stored, Key, Value) {
	Stored[Key] := Value
	return true
}

; The widget anchor is stored through the Storage port, not written to
; config.toml: the stored coordinates keep their numeric type, and no
; configuration producer carries them.
_TNS_WidgetProducers(Mode) {
	global _LLM_Menu
	OldX := WPMWidget.pos_x
	OldY := WPMWidget.pos_y
	OldStoreX := WPMWidgetConst.STORE_X
	OldStoreY := WPMWidgetConst.STORE_Y
	try {
		WPMWidgetConst.STORE_X := "test.pos_x"
		WPMWidgetConst.STORE_Y := "test.pos_y"
		WPMWidget.pos_x := -125
		WPMWidget.pos_y := 0
		switch Mode {
			case "position":
				Stored := Map()
				AssertTrue(WPMWidget_SavePosition(-125, 7, _TNS_StoredAnchor.Bind(Stored)))
				AssertEqual(2, Stored.Count)
				for Key, Value in Stored
					AssertTrue(Value is Integer,
						"the stored coordinate must keep its numeric intent")
				return
			case "display": Updates := _WPMWidget_BuildDisplayCandidate(false, 0, false, 0).updates
			case "full":
				Menu := _HSDeepCloneMap(_LLM_Menu)
				Menu["onboarding_seen"] := false
				Menu["app_profile_overrides"] := Map()
				Menu["user_profiles"] := []
				Updates := _ConfigCollectFullSaveUpdates(ManifestBuildFeaturesMap(), Menu)
			default: throw ValueError("Unknown widget producer")
		}
		for Update in Updates
			AssertFalse(Update.Section == "metrics" && (Update.Key == "wpm_widget_x" || Update.Key == "wpm_widget_y"),
				"no configuration producer may carry the widget anchor")
	} finally {
		WPMWidget.pos_x := OldX
		WPMWidget.pos_y := OldY
		WPMWidgetConst.STORE_X := OldStoreX
		WPMWidgetConst.STORE_Y := OldStoreY
	}
}
for Mode in ["position", "display", "full"]
	Test("TOML: widget " . Mode . " producer keeps the anchor out of config (toml-numeric-string-widget)",
		_TNS_WidgetProducers.Bind(Mode))

_TNS_ReadPreservesString(Value) {
	Path := _CTU_NewPath()
	try {
		AssertTrue(FSWrite(Path, "[personal_editor]`ndefault_section = "
			. TOML_RenderString(Value) . "`n"))
		Actual := TOML_Read(Path, "personal_editor", "default_section", "missing")
		AssertTrue(Actual is String,
			"the single-key reader must preserve the parser's quoted string type")
		AssertEqual(Value, Actual,
			"numeric section names must retain leading zeros and exact spelling")
	} finally FSDelete(Path)
}
for Value in ["0", "1", "+0", "00", "001", "000", "1.0", "1e0"]
	Test("TOML: single-key reads retain '" . Value . "' (toml-numeric-string-read)",
		_TNS_ReadPreservesString.Bind(Value))

_TNS_ReadPreservesNativeValues() {
	Path := _CTU_NewPath()
	try {
		AssertTrue(FSWrite(Path,
			'[sample]`nflag_on = true`nflag_off = false`ncount = 1`nitems = ["0", "1"]`n'))
		for Key, Expected in Map("flag_on", 1, "flag_off", 0, "count", 1) {
			Actual := TOML_Read(Path, "sample", Key, "missing")
			AssertTrue(Actual is Integer, "native numeric values must retain their type")
			AssertEqual(Expected, Actual)
		}
		Items := TOML_Read(Path, "sample", "items", "missing")
		AssertTrue(Items is Array)
		AssertEqual(2, Items.Length)
		AssertTrue(Items[1] is String)
		AssertEqual("0", Items[1])
		AssertEqual("missing", TOML_Read(Path, "sample", "absent", "missing"))
	} finally FSDelete(Path)
}
Test("TOML: single-key reads retain native values and defaults (toml-numeric-string-read)",
	_TNS_ReadPreservesNativeValues)

_TNS_EditorNumericSectionPreference() {
	global ConfigurationFile
	OldPath := ConfigurationFile
	Path := _CTU_NewPath()
	try {
		AssertTrue(FSWrite(Path, '[personal_editor]`ndefault_section = "001"`n'))
		ConfigurationFile := Path
		Actual := _EditorPrefGet("default_section", "")
		AssertTrue(Actual is String, "the editor selects sections by string identity")
		AssertEqual("001", Actual, "reopening the editor must select the saved numeric section")
	} finally {
		ConfigurationFile := OldPath
		FSDelete(Path)
	}
}
Test("TOML: editor restores the exact numeric section name (toml-numeric-string-read)",
	_TNS_EditorNumericSectionPreference)

_TNS_EditorSemanticPreference(Shape) {
	global ConfigurationFile
	OldPath := ConfigurationFile
	Path := _CTU_NewPath()
	switch Shape {
		case "dotted": Source := 'personal_editor.default_section = "001"`npersonal_editor.close_on_add = "1"`n'
		case "inline": Source := 'personal_editor = { default_section = "001", close_on_add = "1" }`n'
		case "quoted": Source := '["personal_editor"]`ndefault_section = "001"`nclose_on_add = "1"`n'
		default: throw ValueError("Unknown personal-editor semantic fixture")
	}
	try {
		AssertTrue(FSWrite(Path, Source))
		Admitted := ConfigTomlDecodeSnapshot(Source).Cache
		AssertEqual("001", Admitted["personal_editor"]["default_section"],
			"the canonical config reader must already admit this source identity")
		ConfigurationFile := Path
		Actual := _EditorPrefGet("default_section", "")
		AssertTrue(Actual is String)
		AssertEqual("001", Actual, "the native editor must select the authored section")
		AssertEqual("1", _EditorPrefGet("close_on_add", "0"))
		AssertEqual("absent", _EditorPrefGet("missing", "absent"))
		AssertEqual(Source, FSReadUtf8Exact(Path), "reading preferences must not normalize their source")
	} finally {
		ConfigurationFile := OldPath
		FSDelete(Path)
	}
}
for Shape in ["dotted", "inline", "quoted"]
	Test("TOML: editor reads " . Shape . " preferences (editor-semantic-preference)",
		_TNS_EditorSemanticPreference.Bind(Shape))
