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

		ApplyMasterGatesToFeatures()

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

		ApplyMasterGatesToFeatures()

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
