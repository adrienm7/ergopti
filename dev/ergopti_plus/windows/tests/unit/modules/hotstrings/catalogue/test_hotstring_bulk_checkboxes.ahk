; tests/unit/modules/hotstrings/catalogue/test_hotstring_bulk_checkboxes.ahk

; ==============================================================================
; MODULE: Hotstring Scope Menu Commands And Independent Checkboxes
; DESCRIPTION:
; Real Win32 category commands dispatch the explicit requested posture once,
; regardless of existing gates and section choices. Language section
; checkboxes retain their independent desired-state contract. The Hotstrings
; menu itself has no whole-tree « all sections » row.
;
; Bulk selection edits desired section state independently of category masters.
; The checks below keep those masters closed while selecting every child.
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





; =====================================================
; =====================================================
; ======= 4/ No whole-tree « all sections » row =======
; =====================================================
; =====================================================

; hotstrings-menu-no-whole-tree-2026-10-17: the Hotstrings menu drew one
; checkbox that switched every section of every category on, the hotstring
; packs of every language and the programmable hotstrings included. Only the
; submenus keep bulk rows, each for its own content.
_HBC_NoWholeTreeRow() {
	Declared := _MR_GetMenuDef("hotstrings_menu")
	Assert(Declared is Array && Declared.Length > 0, "the Hotstrings menu is declared")
	for Row in Declared {
		if !(Row is Map)
			continue
		Assert(Row.Get("id", "") != "hotstrings_all_sections",
			"the Hotstrings menu must not declare a whole-tree « all sections » row")
		Assert(Row.Get("i18n", "") != "menu.hotstrings.enable_all_sections",
			"no top-level Hotstrings row may switch every section at once")
	}
	; The submenus keep theirs: categories two explicit commands, languages one checkbox.
	Category := _MR_GetMenuDef("hotstring_category_menu")
	Ids := Map()
	for Row in Category
		if Row is Map
			Ids[Row.Get("id", "")] := true
	Assert(Ids.Has("hotstring_category_enable_all") && Ids.Has("hotstring_category_disable_all"),
		"every category submenu keeps its check-all and uncheck-all commands")
	; A bundled category's commands select that category only.
	Apply := _DriverFuncBody("_HS_CategorySelectionApply")
	Assert(Apply != "" && InStr(Apply, "ToggleCategoryAllSections(Targets[1], Enabled)") > 0,
		"the category commands reach the category's own selection owner")
}

Test("hotstring bulk: the « all sections » row is one checkbox (hotstring-bulk-checkboxes)",
	_HBC_AllSectionsRowIsACheckbox)
Test("hotstring bulk: « all on » reads every desired section (hotstring-bulk-checkboxes)",
	_HBC_ScopeAllOnReadsEverySection)
Test("hotstring bulk: a category opens with two explicit scoped commands (hotstring-bulk-checkboxes)",
	_HBC_CategoryHeadRows)
Test("hotstring bulk: a language opens with one « all » checkbox (hotstring-bulk-checkboxes)",
	_HBC_LanguageSwitchRowIsACheckbox)
Test("hotstring bulk: the Hotstrings menu has no whole-tree « all sections » row (hotstring-bulk-checkboxes)",
	_HBC_NoWholeTreeRow)
