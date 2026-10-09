; tests/unit/test_hotstring_bulk_checkboxes.ahk

; ==============================================================================
; MODULE: Hotstring Scope Menu Commands And Independent Checkboxes
; DESCRIPTION:
; Real Win32 category commands dispatch the explicit requested posture once,
; regardless of existing gates and section choices. Language and whole-tree
; section checkboxes retain their independent desired-state contract.
;
; Bulk selection edits desired section state independently of category masters.
; The checks below keep those masters closed while selecting every child and
; exercise the durable writer against a scratch config.toml.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Fixture helpers =======
; ==================================
; ==================================

; Every label a list of rows draws, at any depth, so a retired one can be found.
_HBC_Labels(Rows, Out := "") {
	if !(Out is Array)
		Out := []
	for Row in Rows {
		if !(Row is Map)
			continue
		if Row.Has("label")
			Out.Push(Row["label"])
		if Row.Has("items")
			_HBC_Labels(Row["items"], Out)
	}
	return Out
}

; Fails when a list of rows still draws a retired label.
_HBC_AssertNoRetired(Rows, Where) {
	Labels := _HBC_Labels(Rows)
	Assert(Labels.Length > 0, Where . " drew no labelled row, so the absence proves nothing")
	for Label in Labels {
		for RetiredKey in ["menu.hotstrings.category_on", "menu.hotstrings.category_off",
			"menu.hotstrings.enable_all", "menu.hotstrings.disable_all"]
			Assert(Label != RetiredKey and Label != t(RetiredKey), Where . " still draws the retired " . RetiredKey . " row")
	}
}

; The rows labelled Label.
_HBC_RowsLabelled(Rows, Label) {
	Found := []
	for Row in Rows {
		if (Row is Map and Row.Has("label") and Row["label"] == Label)
			Found.Push(Row)
	}
	return Found
}

; Sets every path of one hotstring section, returning the previous values.
_HBC_SetSections(V2Section, Value) {
	global Features
	Saved := Map()
	Paths := _HS_SectionPaths(V2Section)
	Assert(Paths.Length > 1, V2Section . " must have several sections for this test")
	for V2Path in Paths {
		Loc := FeatureLocateV2(Features, V2Path)
		Assert(Loc != false, V2Path . " must resolve in Features")
		Saved[V2Path] := Loc["v2_node"][Loc["key"]]
		Loc["v2_node"][Loc["key"]] := Value
	}
	return Saved
}

; Puts back what _HBC_SetSections saved.
_HBC_Restore(Saved) {
	global Features
	for V2Path, SavedValue in Saved {
		Loc := FeatureLocateV2(Features, V2Path)
		Loc["v2_node"][Loc["key"]] := SavedValue
	}
}

; Runs Body with the Rolls gate and every Rolls section as given, then puts both
; back, including a gate the fixture did not declare.
_HBC_WithRolls(GateOn, SectionsOn, Body) {
	global CategoryEnabled
	HadGate := CategoryEnabled.Has("Rolls")
	SavedGate := HadGate ? CategoryEnabled["Rolls"] : ""
	Saved := _HBC_SetSections("hotstrings.rolls", SectionsOn)
	CategoryEnabled["Rolls"] := GateOn
	try {
		Body()
	} finally {
		_HBC_Restore(Saved)
		if HadGate
			CategoryEnabled["Rolls"] := SavedGate
		else
			CategoryEnabled.Delete("Rolls")
	}
}





; ===========================================
; ===========================================
; ======= 2/ The one « all » checkbox =======
; ===========================================
; ===========================================

; One label, ticked from the state, and a click that asks for the other side.
_HBC_AllSectionsRowIsACheckbox() {
	for State in [true, false] {
		Asked := []
		Row := _HS_AllSectionsRow(State, (Bool) => Asked.Push(Bool))
		AssertEqual(t("menu.hotstrings.enable_all_sections"), Row["label"], "one label, whatever the state")
		AssertEqual(State, Row["checked"], "ticked exactly when every section is on")
		Row["action"].Call()
		AssertEqual(1, Asked.Length, "one click is one batched write")
		AssertEqual(!State, Asked[1], "the click switches everything to the other side")
	}
}

; « All on » means every section and the category gate, and nothing less.
_HBC_ScopeAllOnReadsEverySection() {
	Paths := _HS_SectionPaths("hotstrings.rolls")
	_HBC_WithRolls(true, true, () => AssertTrue(_HS_ScopeAllOn(["Rolls"], Paths),
		"every section on and the gate on is « all on »"))
	_HBC_WithRolls(false, true, () => AssertTrue(_HS_ScopeAllOn(["Rolls"], Paths),
		"selected sections stay checked behind a closed gate"))
	_HBC_WithRolls(true, true, _HBC_OneSectionOff.Bind(Paths))
	AssertFalse(_HS_ScopeAllOn([], Paths), "a scope with no gate has nothing the checkbox could switch on")
	AssertFalse(_HS_ScopeAllOn(["Rolls"], []), "a scope with no section has nothing the checkbox could switch on")
}

; One section off, the rest on: not « all on ».
_HBC_OneSectionOff(Paths) {
	global Features
	Loc := FeatureLocateV2(Features, Paths[1])
	Loc["v2_node"][Loc["key"]] := false
	AssertFalse(_HS_ScopeAllOn(["Rolls"], Paths), "one section off is not « all on »")
}





; ============================================
; ============================================
; ======= 3/ The submenus that show it =======
; ============================================
; ============================================

; A category opens with two explicit commands, independent of its old posture.
_HBC_CategoryHeadRows() {
	for State in [true, false]
		_HBC_WithRolls(State, true, _HBC_AssertCategoryHead.Bind(State))
}

_HBC_AssertCategoryHead(State) {
	global _MenuDispatchCallbacks
	Asked := []
	Apply(Targets, Enabled) {
		Asked.Push(Map("targets", Targets, "enabled", Enabled))
	}
	Built := _HS_CategoryMenu("Rolls", HotstringsBundledTomlPath("Rolls"),
		[Map("label", "fixture-section", "action", (*) => 0)], Apply)
	try {
		for Position, Enabled in [true, false] {
			Label := t(Enabled ? "menu.hotstrings.scope_enable_all" : "menu.hotstrings.scope_disable_all")
			AssertEqual(Label, _CTC_LabelAt(Built, Position - 1), "both commands have the shared order")
			AssertFalse(_CTC_IsChecked(Built, Position - 1), "explicit commands carry no category checkbox")
			Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position - 1, "uint")
			Assert(_MenuDispatchCallbacks.Has(Id), "the native command must be registered")
			_MenuDispatchCallbacks[Id].Call()
			AssertEqual(Position, Asked.Length, "each native click dispatches one transaction")
			AssertEqual(1, Asked[Position]["targets"].Length)
			AssertEqual("Rolls", Asked[Position]["targets"][1])
			AssertEqual(Enabled, Asked[Position]["enabled"], "the command never inverts the captured posture")
		}
		AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.category_enable")))
		AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.enable_all_sections")))
		AssertEqual(1, _CTC_CountLabel(Built, "fixture-section"), "native section data still renders once")
	} finally _CTC_ReleaseMenu(Built)
}

; Each language opens with one « all sections » checkbox for all its categories.
_HBC_LanguageSwitchRowIsACheckbox() {
	Packs := HotstringsLanguageCategories()
	Assert(Packs.Length > 0, "the shared index declares at least one language pack")
	for Pack in Packs {
		Row := _HS_LanguageSwitchRow(Pack)
		AssertEqual(t("menu.hotstrings.enable_all_sections"), Row["label"],
			"a language submenu opens with its one checkbox")
		Assert(Row["checked"] is Integer, "and it is a checkbox, ticked or not")
		Assert(HasMethod(Row["action"]), "that acts on the whole language")
	}
}





; ==========================================
; ==========================================
; ======= 4/ The whole-tree checkbox =======
; ==========================================
; ==========================================

; Runs Body(ConfigPath) against a scratch config.toml with Gates applied over a
; copy of the live gates, then restores every global the writer replaces. The
; tree is the Rolls category: ui/tray_menu.ahk, which declares the tray's
; category tables, is not loaded by this runner, so the fixture declares them.
_HBC_WithScratchConfig(Gates, Body) {
	global ConfigurationFile, Features, CategoryEnabled, _Stub_SentText, _ParseTomlCache
	global _FLAT_HOTSTRING_V1_CATS, _LegacyTopCategoryMap
	Assert(!IsSet(_FLAT_HOTSTRING_V1_CATS) and !IsSet(_LegacyTopCategoryMap),
		"the runner loads the tray's category tables now; use them instead of this fixture's")
	SavedPath := ConfigurationFile
	SavedFeatures := Features
	SavedCategories := CategoryEnabled
	SavedOwner := MasterGateState().Clone()
	ReloadsBefore := _Stub_SentText.Length
	ConfigPath := A_Temp . "\ergopti_hbc_whole_tree_" . A_ScriptHwnd . "_" . A_TickCount . ".toml"
	try FileDelete(ConfigPath)
	try {
		_FLAT_HOTSTRING_V1_CATS := ["Rolls"]
		_LegacyTopCategoryMap := Map("Rolls", "hotstrings.rolls")
		ConfigurationFile := ConfigPath
		Features := ManifestBuildFeaturesMap()
		CategoryEnabled := CategoryEnabled.Clone()
		for Gate, Value in Gates
			CategoryEnabled[Gate] := Value
		_HBC_SetSections("hotstrings.rolls", Gates["Hotstrings"])
		MasterGateState()["initialized"] := false
		MasterGateInitialize(Features, Map(), IsCategoryGated)
		Body(ConfigPath)
	} finally {
		_FLAT_HOTSTRING_V1_CATS := unset
		_LegacyTopCategoryMap := unset
		ConfigurationFile := SavedPath
		Features := SavedFeatures
		CategoryEnabled := SavedCategories
		MasterGateState().Clear()
		for Key, Value in SavedOwner
			MasterGateState()[Key] := Value
		while (_Stub_SentText.Length > ReloadsBefore)
			_Stub_SentText.Pop()
		if _ParseTomlCache.Has(ConfigPath)
			_ParseTomlCache.Delete(ConfigPath)
		try FileDelete(ConfigPath)
	}
}

; What the reload that follows every write does before the tray is drawn again:
; a closed gate zeroes its sections in Features.
_HBC_ApplyGatesAsAtBoot() {
	global Features
	ApplyMasterGatesToFeatures(Features, Map(), IsCategoryGated, 0)
}

; Unticking switches every section off and leaves the gates as they are: the
; Hotstrings switch and each category gate are checkboxes of their own.
_HBC_WholeTreeUntickKeepsGates() {
	_HBC_WithScratchConfig(Map("Hotstrings", true, "Rolls", true), _HBC_AssertUntickKeepsGates)
}

_HBC_AssertUntickKeepsGates(ConfigPath) {
	global CategoryEnabled
	AssertTrue(ToggleAllHotstrings(false), "the whole-tree write must commit")
	AssertTrue(CategoryEnabled["Hotstrings"],
		"unticking every section must leave the Hotstrings switch on, as macOS and Linux do")
	AssertTrue(CategoryEnabled["Rolls"], "and every category gate as it was")
	AssertEqual(-1, TOML_Read(ConfigPath, "category_enabled", "hotstrings", -1),
		"no gate is written when the sections are switched off")
	_HBC_ApplyGatesAsAtBoot()
	AssertFalse(_HS_AllHotstringsOn(), "every section is off, so the checkbox is unticked")
}

; Ticking with a category gate closed opens it: that gate zeroes its sections at
; every boot, so leaving it shut left the checkbox unticked however often it was
; clicked.
_HBC_WholeTreeTickOpensEveryGate() {
	_HBC_WithScratchConfig(Map("Hotstrings", false, "Rolls", false), _HBC_AssertTickOpensGates)
}

_HBC_AssertTickOpensGates(ConfigPath) {
	global CategoryEnabled
	AssertFalse(_HS_AllHotstringsOn(), "unselected sections leave the checkbox unticked")
	AssertTrue(ToggleAllHotstrings(true), "the whole-tree write must commit")
	AssertFalse(CategoryEnabled["Hotstrings"], "selecting every section leaves the master disabled")
	AssertFalse(CategoryEnabled["Rolls"], "section selection preserves the category gate")
	AssertEqual(-1, TOML_Read(ConfigPath, "category_enabled", "rolls", -1),
		"section selection cannot create a master override")
	_HBC_ApplyGatesAsAtBoot()
	AssertTrue(_HS_AllHotstringsOn(), "one click ticks the checkbox, once the reload has applied the gates")
}

Test("hotstring bulk: the « all sections » row is one checkbox (hotstring-bulk-checkboxes)",
	_HBC_AllSectionsRowIsACheckbox)
Test("hotstring bulk: « all on » reads every desired section (hotstring-bulk-checkboxes)",
	_HBC_ScopeAllOnReadsEverySection)
Test("hotstring bulk: a category opens with two explicit scoped commands (hotstring-bulk-checkboxes)",
	_HBC_CategoryHeadRows)
Test("hotstring bulk: a language opens with one « all » checkbox (hotstring-bulk-checkboxes)",
	_HBC_LanguageSwitchRowIsACheckbox)
Test("hotstring bulk: unticking the whole tree keeps every gate (hotstring-bulk-checkboxes)",
	_HBC_WholeTreeUntickKeepsGates)
Test("hotstring bulk: ticking the whole tree preserves disabled gates (hotstring-bulk-checkboxes)",
	_HBC_WholeTreeTickOpensEveryGate)

_HBC_ReadOnlyEnumerationDoesNotSeed() {
	global ScriptInformation, _ReadPersonalTomlCache
	global _FLAT_HOTSTRING_V1_CATS, _LegacyTopCategoryMap
	Saved := ScriptInformation
	SavedCache := _ReadPersonalTomlCache
	SavedFlat := IsSet(_FLAT_HOTSTRING_V1_CATS) ? _FLAT_HOTSTRING_V1_CATS : false
	SavedLegacy := IsSet(_LegacyTopCategoryMap) ? _LegacyTopCategoryMap : false
	Path := A_Temp . "\ergopti-enumeration-" . A_ScriptHwnd . "-" . A_TickCount . ".toml"
	try {
		FileAppend('[[First]]`n"first" = "one"`n[[Second]]`n"second" = "two"`n', Path, "UTF-8-RAW")
		ScriptInformation := Map("PersonalTomlPath", Path)
		_ReadPersonalTomlCache := false
		; Scope the fixture to dynamic and personal paths; flat-category ownership
		; belongs to the entry and is deliberately absent in the unit harness.
		_FLAT_HOTSTRING_V1_CATS := []
		_LegacyTopCategoryMap := Map()
		Target := Map("hotstrings", Map())
		ReadOnly := _CollectAllHotstringsV2Paths(Target, false)
		AssertFalse(Target["hotstrings"].Has("personal"), "a checkbox read cannot seed live configuration")
		Detached := _HSDeepCloneMap(Target)
		Writable := _CollectAllHotstringsV2Paths(Detached)
		AssertTrue(Detached["hotstrings"].Has("personal"), "writers still seed their detached candidate")
		AssertEqual(Writable.Length, ReadOnly.Length)
		loop Writable.Length
			AssertEqual(Writable[A_Index], ReadOnly[A_Index], "read-only enumeration preserves canonical order")
		AssertEqual("hotstrings.personal.first", ReadOnly[ReadOnly.Length - 1])
		AssertEqual("hotstrings.personal.second", ReadOnly[ReadOnly.Length])
	} finally {
		ScriptInformation := Saved
		_ReadPersonalTomlCache := SavedCache
		_FLAT_HOTSTRING_V1_CATS := SavedFlat is Array ? SavedFlat : unset
		_LegacyTopCategoryMap := SavedLegacy is Map ? SavedLegacy : unset
		FileDelete(Path)
	}
}
Test("hotstring bulk: read-only whole-tree enumeration preserves order without seeding live state", _HBC_ReadOnlyEnumerationDoesNotSeed)
