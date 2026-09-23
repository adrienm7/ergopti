; tests/unit/test_hotstring_bulk_checkboxes.ahk

; ==============================================================================
; MODULE: Hotstring Bulk Controls Are Checkboxes
; DESCRIPTION:
; A hotstring category submenu opens with its gate, then one control for all of
; its sections; a language submenu opens with one control for every section of
; its categories. Each is a checkbox: one label, ticked from the state it
; governs, and a click that switches everything to the other side.
;
; ROOT CAUSE ENCODED: the gate alternated between « ✅ Activée (cliquer pour
; désactiver) » and « ❌ Désactivée (cliquer pour activer) », and the sections
; came with a « Tout activer » / « Tout désactiver » pair: two keys and two rows
; for one control, and a state the user could only read from the words. The
; rows are built by the real builders over the live Features and CategoryEnabled
; maps, which each test restores.
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
	_HBC_WithRolls(false, true, () => AssertFalse(_HS_ScopeAllOn(["Rolls"], Paths),
		"a closed gate is not « all on »"))
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

; A category opens with its gate checkbox, then one « all sections » checkbox.
_HBC_CategoryHeadRows() {
	for State in [true, false]
		_HBC_WithRolls(State, true, _HBC_AssertCategoryHead.Bind(State))
}

; The head rows of Rolls, with its gate at State and every section on.
_HBC_AssertCategoryHead(State) {
	Rows := _HS_CategoryHeadRows("Rolls", "hotstrings.rolls", HotstringsBundledTomlPath("Rolls"))
	AssertEqual(t("menu.hotstrings.category_enable"), Rows[1]["label"], "the gate is the first row")
	AssertEqual(State, Rows[1]["checked"], "the gate is a checkbox ticked from the category gate")
	All := _HBC_RowsLabelled(Rows, t("menu.hotstrings.enable_all_sections"))
	AssertEqual(1, All.Length, "one control for every section of the category")
	AssertEqual(State, All[1]["checked"], "ticked exactly when the gate and every section are on")
	_HBC_AssertNoRetired(Rows, "the category submenu")
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

Test("hotstring bulk: the « all sections » row is one checkbox (hotstring-bulk-checkboxes)",
	_HBC_AllSectionsRowIsACheckbox)
Test("hotstring bulk: « all on » reads the gate and every section (hotstring-bulk-checkboxes)",
	_HBC_ScopeAllOnReadsEverySection)
Test("hotstring bulk: a category opens with its gate and one « all » checkbox (hotstring-bulk-checkboxes)",
	_HBC_CategoryHeadRows)
Test("hotstring bulk: a language opens with one « all » checkbox (hotstring-bulk-checkboxes)",
	_HBC_LanguageSwitchRowIsACheckbox)
