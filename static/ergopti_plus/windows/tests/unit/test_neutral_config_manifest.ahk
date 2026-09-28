; tests/unit/test_neutral_config_manifest.ahk

; Neutral defaults must remain separate from both runtime mutations and imports.
_NeutralConfigManifestProjections() {
	AssertEqual(ManifestDefaultFor("category_enabled.shortcuts"), false)
	AssertEqual(ManifestRecommendedFor("category_enabled.shortcuts"), true)
	AssertEqual(ManifestDefaultFor("shortcuts.keyboard.win_a"), "none")
	AssertEqual(ManifestRecommendedFor("shortcuts.keyboard.win_a"), "select_line")
	State := ManifestBuildFeaturesMap()
	State["hotstrings"]["magic_key"]["replace"]["enabled"] := true
	AssertEqual(ManifestDefaultFor("hotstrings.magic_key.replace.enabled"), false,
		"runtime edits must not mutate the canonical neutral baseline")
}
Test("neutral-config: manifest projections preserve recommended intent", _NeutralConfigManifestProjections)

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
	for Row in ManifestScopeOperations("gestures", "clear") {
		Assert(InStr(Row.Section, "gestures") == 1)
		AssertEqual(Row.Delete, 1)
	}
}
Test("neutral-config: shared scopes never restore metrics or AI consent", _NeutralConfigScopesExcludeConsent)

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
Test("neutral-config: real feature state boot leaves every master and shortcut off", _NeutralConfigRealFeatureState)

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
