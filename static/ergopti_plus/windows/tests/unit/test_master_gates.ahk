; static/ergopti_plus/windows/tests/unit/test_master_gates.ahk

; ==============================================================================
; MODULE: Master Gates Tests
; DESCRIPTION:
; Regression tests for the per-TOML-file hotstring sub-category gates added on
; top of the existing module master gates. ApplyMasterGatesToFeatures must zero
; ONLY the features of a sub-category whose own gate is off (Autocorrection,
; Rolls, ...), leaving the other sub-categories live, so that the parent menu
; checkmark and firing follow the category's own enable toggle rather than the
; aggregate of its section states.
; ==============================================================================





; ============================================
; ============================================
; ======= 1/ Sub-Category Gating =============
; ============================================
; ============================================

TestMasterGates_SubcatGateZerosOnlyItsFeatures() {
	global Features, CategoryEnabled
	; Snapshot the shared stub globals so other tests are unaffected.
	HadHot   := Features.Has("hotstrings")
	OldHot   := HadHot ? Features["hotstrings"] : ""
	OldAuto  := CategoryEnabled.Has("Autocorrection") ? CategoryEnabled["Autocorrection"] : ""
	OldRolls := CategoryEnabled.Has("Rolls") ? CategoryEnabled["Rolls"] : ""
	try {
		CategoryEnabled["Hotstrings"]     := true     ; top gate on
		CategoryEnabled["Autocorrection"] := false    ; this file is OFF
		CategoryEnabled["Rolls"]          := true     ; this file is ON
		Features["hotstrings"] := Map(
			"autocorrection", Map("errors", Map("enabled", true), "accents", Map("enabled", true)),
			"rolls", Map("hc", Map("enabled", true))
		)

		ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated)

		AssertFalse(Features["hotstrings"]["autocorrection"]["errors"]["enabled"],
			"a gated-off sub-category's sections are forced false")
		AssertFalse(Features["hotstrings"]["autocorrection"]["accents"]["enabled"],
			"every section of the gated-off sub-category is forced false")
		AssertTrue(Features["hotstrings"]["rolls"]["hc"]["enabled"],
			"a sub-category whose own gate is on is left untouched")
	} finally {
		if HadHot
			Features["hotstrings"] := OldHot
		else
			Features.Delete("hotstrings")
		if (OldAuto == "")
			CategoryEnabled.Delete("Autocorrection")
		else
			CategoryEnabled["Autocorrection"] := OldAuto
		if (OldRolls == "")
			CategoryEnabled.Delete("Rolls")
		else
			CategoryEnabled["Rolls"] := OldRolls
	}
}
Test("master gates: a sub-category gate zeros only its own features",
	TestMasterGates_SubcatGateZerosOnlyItsFeatures)

TestMasterGates_SubcatGateOnLeavesFeatures() {
	global Features, CategoryEnabled
	HadHot  := Features.Has("hotstrings")
	OldHot  := HadHot ? Features["hotstrings"] : ""
	OldAuto := CategoryEnabled.Has("Autocorrection") ? CategoryEnabled["Autocorrection"] : ""
	try {
		CategoryEnabled["Hotstrings"]     := true
		CategoryEnabled["Autocorrection"] := true
		Features["hotstrings"] := Map(
			"autocorrection", Map("errors", Map("enabled", true), "accents", Map("enabled", false))
		)

		ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated)

		AssertTrue(Features["hotstrings"]["autocorrection"]["errors"]["enabled"],
			"an enabled section stays enabled when the category gate is on")
		AssertFalse(Features["hotstrings"]["autocorrection"]["accents"]["enabled"],
			"a section the user disabled stays disabled (gate does not re-enable it)")
	} finally {
		if HadHot
			Features["hotstrings"] := OldHot
		else
			Features.Delete("hotstrings")
		if (OldAuto == "")
			CategoryEnabled.Delete("Autocorrection")
		else
			CategoryEnabled["Autocorrection"] := OldAuto
	}
}
Test("master gates: a sub-category gate left on does not change section states",
	TestMasterGates_SubcatGateOnLeavesFeatures)

TestMasterGates_RequiresExplicitTargets() {
	Thrown := false
	try ApplyMasterGatesToFeatures("not-a-map", Map(), IsCategoryGated)
	catch as Err
		Thrown := InStr(Err.Message, "Features Map target") > 0
	AssertTrue(Thrown,
		"master gates must fail fast when a caller omits a concrete Features target instead of mutating an implicit global")
}
Test("master gates: explicit target contract fails fast for invalid candidates",
	TestMasterGates_RequiresExplicitTargets)

TestMasterGates_RequiresCategoryGateCallback() {
	global Features, TapHold
	Thrown := false
	try ApplyMasterGatesToFeatures(Features, TapHold, 0)
	catch as Err
		Thrown := InStr(Err.Message, "category-gate callback") > 0
	AssertTrue(Thrown,
		"master gates must fail fast instead of resolving an undeclared category-gate dependency dynamically")
}
Test("master gates: explicit category-gate callback contract fails fast", TestMasterGates_RequiresCategoryGateCallback)

TestMasterGates_InvalidManifestDoesNotMutateCandidate() {
	global _SharedDir, CategoryEnabled
	FixtureRoot := A_Temp . "\ergopti_master_gates_invalid_" . A_TickCount
	FixturePath := FixtureRoot . "\modules\menu\menu_manifest.json"
	SavedSharedDir := _SharedDir
	HadHotstringsGate := CategoryEnabled.Has("Hotstrings")
	SavedHotstringsGate := HadHotstringsGate ? CategoryEnabled["Hotstrings"] : ""
	FeaturesCandidate := Map(
		"layout", Map("enabled", true),
		"hotstrings", Map("fixture", Map("entry", Map("enabled", true)))
	)
	TapHoldCandidate := Map("keys", Map("space", Map("tap", "space")))
	try {
		DirCreate(FixtureRoot . "\modules\menu")
		FileAppend("{}", FixturePath, "UTF-8-RAW")
		_SharedDir := FixtureRoot
		CategoryEnabled["Hotstrings"] := true
		Thrown := false
		try ApplyMasterGatesToFeatures(FeaturesCandidate, TapHoldCandidate, IsCategoryGated)
		catch as Err
			Thrown := InStr(Err.Message, "Master gate manifest") > 0
		AssertTrue(Thrown, "an invalid canonical manifest must fail fast")
		AssertTrue(FeaturesCandidate["layout"]["enabled"],
			"manifest validation must not mutate a candidate Features map")
		AssertTrue(TapHoldCandidate["keys"].Has("space"),
			"manifest validation must not mutate a candidate TapHold map")
	} finally {
		_SharedDir := SavedSharedDir
		if HadHotstringsGate
			CategoryEnabled["Hotstrings"] := SavedHotstringsGate
		else
			CategoryEnabled.Delete("Hotstrings")
		try DirDelete(FixtureRoot, true)
	}
}
Test("master gates: invalid manifest fails before candidate mutation",
	TestMasterGates_InvalidManifestDoesNotMutateCandidate)

TestMasterGates_TargetNamesRemainExplicit() {
	Body := _DriverFuncBody("ApplyMasterGatesToFeatures")
	Assert(Body != "", "ApplyMasterGatesToFeatures must exist")
	Assert(InStr(Body, "Features := FeaturesTarget") = 0
		and InStr(Body, "TapHold := TapHoldTarget") = 0,
		"master gate application must not shadow runtime globals with implicit local aliases")
	Assert(InStr(Body, "FeaturesTarget.Has(") > 0 and InStr(Body, "TapHoldTarget.Has(") > 0,
		"every gate mutation must visibly use its injected candidate target")
}
Test("master gates: application retains explicit candidate targets",
	TestMasterGates_TargetNamesRemainExplicit)
