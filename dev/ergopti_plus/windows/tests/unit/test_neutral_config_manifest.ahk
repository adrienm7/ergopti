; tests/unit/test_neutral_config_manifest.ahk

; Neutral defaults must remain separate from both runtime mutations and imports.
_NeutralConfigManifestProjections() {
	AssertEqual(ManifestDefaultFor("category_enabled.shortcuts"), false)
	AssertEqual(ManifestRecommendedFor("category_enabled.shortcuts"), true)
	AssertEqual(ManifestDefaultFor("shortcuts.keyboard.win_a"), "none")
	AssertEqual(ManifestRecommendedFor("shortcuts.keyboard.win_a"), "select_line")
	; The declared exception: the script-management chords start with their
	; preset (maintainer decision of 2026-09-30).
	for Slot, Action in Map("script_altgr_enter", "script_pause_toggle", "script_altgr_backspace", "script_reload",
			"script_altgr_delete", "open_personal_shortcuts", "script_altgr_escape", "script_quit") {
		AssertEqual(Action, ManifestDefaultFor("shortcuts.script_control." . Slot), Slot . " starts with its preset")
		AssertEqual(Action, ManifestRecommendedFor("shortcuts.script_control." . Slot), Slot . " keeps its preset")
	}
	State := ManifestBuildFeaturesMap()
	State["hotstrings"]["magic_key"]["replace"]["enabled"] := true
	AssertEqual(ManifestDefaultFor("hotstrings.magic_key.replace.enabled"), false,
		"runtime edits must not mutate the canonical neutral baseline")
}
Test("neutral-config: manifest projections preserve recommended intent", _NeutralConfigManifestProjections)

_NeutralConfigClonePreservesMapCaseSense() {
	Source := TOML_CoerceValue('{ "Key" = "upper", "key" = "lower" }', true)
	Copy := ManifestCloneValue(Source)
	AssertEqual("On", Copy.CaseSense, "the clone retains case-sensitive TOML inline keys")
	AssertEqual(2, Copy.Count, "distinct key spellings must survive copying")
	AssertEqual("upper", Copy["Key"])
	AssertEqual("lower", Copy["key"])
	Copy["Key"] := "copied upper"
	Source["key"] := "source lower"
	AssertEqual("upper", Source["Key"], "editing the copy must leave the source key intact")
	AssertEqual("lower", Copy["key"], "editing the source must leave the copied key intact")
	for Mode in ["Off", "Locale"] {
		Other := Map()
		Other.CaseSense := Mode
		Other["Key"] := "value"
		AssertEqual(Mode, ManifestCloneValue(Other).CaseSense, "retain every supported comparison mode")
	}
}
Test("neutral-config: value clones preserve every Map comparison mode and distinct keys", _NeutralConfigClonePreservesMapCaseSense)

_NeutralConfigCloneOwnsNestedTypedValues() {
	Source := TOML_CoerceValue('{ records = [{ enabled = true, values = ["before", { visible = false }] }] }', true)
	Copy := ManifestCloneValue(Source)
	Assert(Copy["records"][1]["enabled"] is TOML_Bool, "true retains its TOML Boolean type")
	Assert(Copy["records"][1]["values"][2]["visible"] is TOML_Bool, "false retains its TOML Boolean type")
	AssertEqual(true, Copy["records"][1]["enabled"].Value)
	AssertEqual(false, Copy["records"][1]["values"][2]["visible"].Value)
	Reread := TOML_CoerceValue(TOML_RenderValue(Copy), true)
	Assert(Reread["records"][1]["enabled"] is TOML_Bool, "the clone renders true with its source type")
	Assert(Reread["records"][1]["values"][2]["visible"] is TOML_Bool, "the clone renders false with its source type")
	AssertEqual(true, Reread["records"][1]["enabled"].Value)
	AssertEqual(false, Reread["records"][1]["values"][2]["visible"].Value)
	Copy["records"][1]["enabled"].Value := false
	Copy["records"][1]["values"][1] := "copy"
	Copy["records"].Push(Map("enabled", TOML_Bool(false)))
	AssertEqual(true, Source["records"][1]["enabled"].Value, "the copied Boolean wrapper is independent")
	AssertEqual("before", Source["records"][1]["values"][1], "nested copied arrays own their elements")
	AssertEqual(1, Source["records"].Length, "appending to the copy does not grow the source array")
	Source["records"][1]["values"][2]["visible"].Value := true
	Source["records"][1]["values"].Push("source")
	Source["records"][1]["future"] := "source only"
	AssertEqual(false, Copy["records"][1]["values"][2]["visible"].Value, "source Boolean edits cannot alter the copy")
	AssertEqual(2, Copy["records"][1]["values"].Length, "source appends cannot grow the copied nested array")
	AssertFalse(Copy["records"][1].Has("future"), "source Map edits cannot add copied keys")
	AssertEqual("true", TOML_RenderValue(Source["records"][1]["enabled"]))
	AssertEqual("false", TOML_RenderValue(Copy["records"][1]["enabled"]))
}
Test("neutral-config: nested value clones own arrays, Maps and typed Boolean wrappers", _NeutralConfigCloneOwnsNestedTypedValues)

_NeutralConfigClonePreservesOpaqueValues() {
	Opaque := { FutureValue: "opaque" }
	Source := Map("text", "001", "integer", 1, "float", 1.5, "opaque", Opaque)
	Copy := ManifestCloneValue(Source)
	for Key in ["text", "integer", "float"] {
		AssertEqual(Type(Source[Key]), Type(Copy[Key]), "cloning preserves scalar types: " . Key)
		AssertEqual(Source[Key], Copy[Key], "cloning preserves scalar values: " . Key)
	}
	AssertEqual(ObjPtr(Opaque), ObjPtr(Copy["opaque"]), "unsupported objects retain the existing opaque identity contract")
}
Test("neutral-config: value clones preserve scalars and leave unsupported objects opaque", _NeutralConfigClonePreservesOpaqueValues)

_NeutralConfigCloneWithoutTypedCodec() {
	Root := A_Temp . "\ergopti_manifest_clone_" . A_ScriptHwnd . "_" . A_TickCount
	AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Root, "Ptr", 0, "Int"),
		"the isolated clone fixture must exclusively own its directory")
	try {
		Script := Root . "\probe.ahk"
		Receipt := Root . "\result.txt"
		; Run the actual production function in a fresh process whose typed TOML
		; class is absent. The suite itself already includes that class.
		FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n#Warn All, StdOut`n"
			. _DriverFuncBody("ManifestCloneValue") . "`n"
			. "try {`n"
			. 'if IsSet(TOML_Bool)' . "`n"
			. 'throw Error("the isolated probe must not load the typed TOML class")' . "`n"
			. 'Source := Map()' . "`n"
			. 'Source.CaseSense := "On"' . "`n"
			. 'Source["values"] := ["before"]' . "`n"
			. 'Source["Key"] := "upper"' . "`n"
			. 'Source["key"] := "lower"' . "`n"
			. 'Copy := ManifestCloneValue(Source)' . "`n"
			. 'Copy["values"][1] := "copy"' . "`n"
			. 'if Copy.CaseSense != "On" || Copy.Count != 3 || Copy["Key"] != "upper" || Copy["key"] != "lower"' . "`n"
			. 'throw Error("generic cloning lost case-sensitive keys")' . "`n"
			. 'if Source["values"][1] != "before"' . "`n"
			. 'throw Error("generic cloning shared a nested array")' . "`n"
			. 'FileAppend("complete", A_Args[1], "UTF-8-RAW")' . "`n"
			. "} catch Error as Err {`n"
			. 'FileAppend(Err.Message . "``n" . Err.Stack, A_Args[1], "UTF-8-RAW")' . "`n"
			. "ExitApp(1)`n}`nExitApp(0)`n", Script, "UTF-8")
		Code := RunWait('"' . A_AhkPath . '" /ErrorStdOut "' . Script . '" "' . Receipt . '"', , "Hide")
		AssertTrue(FileExist(Receipt), "the actual clone probe must report its outcome; exit=" . Code)
		Result := FileRead(Receipt, "UTF-8")
		AssertEqual(0, Code, Result)
		AssertEqual("complete", Result)
	} finally DirDelete(Root, true)
}
Test("neutral-config: actual value cloning remains usable without the typed TOML class", _NeutralConfigCloneWithoutTypedCodec)

_NeutralConfigSparseOperations() {
	Removed := ManifestSparseOperation("category_enabled.shortcuts", false)
	AssertEqual(Removed.Delete, 1)
	Assert(!Removed.HasOwnProp("Value"), "deletion must be explicit, never a missing value")
	Assigned := ManifestSparseOperation("category_enabled.shortcuts", true)
	AssertEqual(Assigned.Section, "category_enabled")
	AssertEqual(Assigned.Key, "shortcuts")
	AssertEqual(Assigned.Value, true)
}
Test("neutral-config: default values produce sparse deletion", _NeutralConfigSparseOperations)

_NeutralConfigDynamicHotstrings() {
	AssertEqual(ManifestDefaultFor("category_enabled.french_autocorrection"), false)
	AssertEqual(ManifestSparseOperation("category_enabled.french_autocorrection", false).Delete, 1)
	AssertEqual(ManifestDefaultFor("hotstrings.groups.french_autocorrection"), false)
	AssertEqual(ManifestDefaultFor("hotstrings.modules.french_autocorrection.accents"), false)
	AssertEqual(ManifestRecommendedFor("hotstrings.groups.french_autocorrection"), true)
	Removed := ManifestSparseOperation("hotstrings.modules.french_autocorrection.accents", false)
	AssertEqual(Removed.Delete, 1)
}
Test("neutral-config: dynamic hotstrings inherit neutral absence", _NeutralConfigDynamicHotstrings)

_NeutralConfigPersonalDefaults() {
	AssertEqual(ManifestDefaultFor("hotstrings.personal.user_added.enabled"), false)
	AssertEqual(ManifestDefaultFor("hotstrings.personal.user_added.time_activation_seconds"), 0)
	AssertEqual(ManifestDefaultFor("shortcuts.personal.user_added"), false)
	AssertEqual(ManifestDefaultFor("hotstrings.personal.autocorrection.time_activation_seconds"), 0.75,
		"known parameter declarations take priority over dynamic user sections")
}
Test("neutral-config: personal runtime sections inherit declared defaults", _NeutralConfigPersonalDefaults)

_NeutralConfigScopesExcludeConsent() {
	Rows := ManifestScopeOperations("global", "recommended")
	Assert(Rows.Length > 100, "exercise the real global scope")
	FoundShortcut := false
	for Row in Rows {
		Path := Row.Section . "." . Row.Key
		Assert(Path != "llm.enabled" && Path != "metrics.enabled" && Path != "metrics.metrics_enabled",
			"restore recommended must never import consent")
		if Path == "category_enabled.shortcuts"
			FoundShortcut := Row.Value == true
	}
	Assert(FoundShortcut, "restore must include selected recommended child state")
	FoundSubcategory := false
	for Row in ManifestScopeOperations("hotstrings", "recommended") {
		if Row.Section == "category_enabled" && Row.Key == "autocorrection"
			FoundSubcategory := Row.Value == true
	}
	Assert(FoundSubcategory, "hotstrings restore must include its subordinate master gates")
	Cleared := 0
	for Row in ManifestScopeOperations("gestures", "clear") {
		Assert(InStr(Row.Section, "gestures") == 1)
		AssertEqual(Row.Delete, 1)
		Assert(!(Row.Section == "gestures" && Row.Key == "enabled"),
			"the Gestures clear leaves the switch as it is (gestures-clear-keeps-switch)")
		Cleared += 1
	}
	Assert(Cleared > 5, "the Gestures clear still removes the assignments, got " . Cleared)
	for Row in ManifestScopeOperations("global", "clear")
		Assert(!(Row.Section == "gestures" && Row.Key == "enabled"), "no clear rewrites the Gestures switch")
	Restored := false
	for Row in ManifestScopeOperations("gestures", "recommended") {
		if Row.Section == "gestures" && Row.Key == "enabled"
			Restored := Row.HasOwnProp("Value") && Row.Value == true
	}
	Assert(Restored, "the Gestures restore still switches them on")
}
Test("neutral-config: shared scopes never restore metrics or AI consent", _NeutralConfigScopesExcludeConsent)

; The Shortcuts clear and the global clear deleted every key of their scope,
; and a deleted script chord starts with its preset: « Tout effacer » switched
; the chords back on. They write each slot's declared off value instead
; (script-chords-three-os-2026-09-30).
_NeutralConfigClearWritesChordsOff() {
	for Scope in ["shortcuts", "global"] {
		Found := Map()
		for Row in ManifestScopeOperations(Scope, "clear") {
			if Row.Section != "shortcuts.script_control" || !InStr(Row.Key, "script_altgr_")
				continue
			Assert(!Row.HasOwnProp("Delete"), Scope . " clear must not delete " . Row.Key)
			AssertEqual("none", Row.Value, Scope . " clear leaves " . Row.Key . " to the system")
			Found[Row.Key] := true
		}
		AssertEqual(4, Found.Count, Scope . " clear covers the four script chords")
	}
}
Test("neutral-config: every clear writes the script chords off (script-chords-three-os-2026-09-30)", _NeutralConfigClearWritesChordsOff)

_NeutralConfigMissingTapHold() {
	global _SharedDir
	Preset := _SharedDir . "\tap_hold\defaults.toml"
	Assert(FileExist(Preset), "exercise the actual shipped recommendations")
	Loaded := LoadTapHoldToml(A_Temp . "\ergopti-no-neutral-config-" . A_TickCount . ".toml", Preset)
	AssertEqual(Loaded["keys"].Count, 0, "absence must never import the recommendation")
	AssertFalse(Loaded.Has("layers"), "navigation mappings belong only to layers.toml")
}
Test("neutral-config: an absent tap-hold file imports no recommended bindings", _NeutralConfigMissingTapHold)

_NeutralConfigRealFeatureState() {
	AssertEqual(0, _FeatureStateBootRun("neutral"), "real neutral startup must complete")
}
Test("neutral-config: real feature state boot leaves every master and shortcut off, the script chords on their preset", _NeutralConfigRealFeatureState)

_NeutralConfigScriptNone() {
	AssertEqual(0, _FeatureStateBootRun("script_none"), "a stored none must survive the preset default")
}
Test("neutral-config: a config naming none for a script chord keeps it off (script-chords-on-2026-09-30)", _NeutralConfigScriptNone)

_NeutralConfigFirstBoot() {
	AssertEqual(0, _FeatureStateBootRun("neutral_first_boot"), "real first boot must remain neutral")
}
Test("neutral-config: first boot does not seed either recommended bindings or neutral overrides", _NeutralConfigFirstBoot)

; Real restore operations must use the same sparse contract as individual saves.
_NeutralConfigSparseRestore() {
	Rows := ManifestScopeOperations("global", "recommended")
	NeutralScalars := 0, NeutralLeaves := 0, NonNeutral := 0
	for Row in Rows {
		Path := Row.Section . "." . Row.Key
		Recommended := ManifestRecommendedFor(Path)
		Neutral := ManifestDefaultFor(Path)
		if ManifestValuesEqual(Recommended, Neutral) {
			Assert(Row.HasOwnProp("Delete") && Row.Delete == 1, "neutral restore must delete: " . Path)
			Assert(!Row.HasOwnProp("Value"), "neutral restore must not serialize a value: " . Path)
			if ManifestFindEntryByPath(Path)
				NeutralScalars += 1
			else
				NeutralLeaves += 1
		} else {
			NonNeutral += 1
			Assert(!Row.HasOwnProp("Delete"), "non-neutral recommendation must remain assigned: " . Path)
			Assert(ManifestValuesEqual(Row.Value, Recommended), "preserve recommendation: " . Path)
		}
		Assert(Path != "llm.enabled" && Path != "metrics.enabled" && Path != "metrics.metrics_enabled"
			&& Path != "hotstrings.preview_ai_enabled", "restore must never import consent")
	}
	Assert(NeutralScalars > 0 && NeutralLeaves > 0 && NonNeutral > 0, "exercise all real recommendation shapes")
	for Path in ["shortcuts.personal.sparse_probe", "hotstrings.personal.sparse_probe.enabled",
		"hotstrings.personal.sparse_probe.time_activation_seconds"] {
		Row := ManifestSparseOperation(Path, ManifestRecommendedFor(Path))
		AssertEqual(Row.Delete, 1, "runtime-owned neutral recommendation: " . Path)
		Assert(!Row.HasOwnProp("Value"))
	}
	Group := ManifestSparseOperation("hotstrings.groups.sparse_probe", ManifestRecommendedFor("hotstrings.groups.sparse_probe"))
	AssertEqual(Group.Value, true, "a non-neutral dynamic recommendation stays explicit")
	Assert(!Group.HasOwnProp("Delete"))
}
Test("neutral-config: restore recommended stays sparse (scope-sparse)", _NeutralConfigSparseRestore)
