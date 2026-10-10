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

#Include ../../ui/menu/menu_engine.ahk





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

; « Combinaisons de touches » is the only gate of the key combinations: the
; Shortcuts master does not reach them (decision of 2026-09-29, as on macOS).
; Their slots hold actions, which no master gate rewrites, and their hotkeys
; ask the KeyCombinations gate alone (infra/key_combinations.ahk).
_MGKC_Candidate() {
	return Map("shortcuts", Map(
		"gpt", Map("enabled", true, "link", "https://example.test"),
		"key_combination_taps", Map("alt_gr_then_left_alt", "ctrl_backspace")))
}

; A category-gate callback answering the two switches, every other gate on.
_MGKC_Gates(ShortcutsGate, CombinationsGate) {
	GateValues := Map("Shortcuts", ShortcutsGate, "KeyCombinations", CombinationsGate)
	return (Name) => GateValues.Get(Name, true)
}

TestMasterGates_KeyCombinationsSubGate() {
	global CategoryEnabled
	for _, Gates in [[true, false], [false, true], [false, false]] {
		Candidate := _MGKC_Candidate()
		ApplyMasterGatesToFeatures(Candidate, Map(), _MGKC_Gates(Gates[1], Gates[2]))
		AssertEqual("ctrl_backspace", Candidate["shortcuts"]["key_combination_taps"]["alt_gr_then_left_alt"],
			"a master gate never rewrites a pair's action")
		AssertEqual(Gates[1], Candidate["shortcuts"]["gpt"]["enabled"], "the Shortcuts master still gates the other shortcuts")
		AssertEqual("https://example.test", Candidate["shortcuts"]["gpt"]["link"], "and keeps their parameters")
	}
	Saved := CategoryEnabled.Clone()
	try {
		CategoryEnabled["Shortcuts"] := false
		CategoryEnabled["KeyCombinations"] := true
		AssertTrue(KeyCombinationsAreOn(), "the pairs do not follow the Shortcuts master")
		CategoryEnabled["Shortcuts"] := true
		CategoryEnabled["KeyCombinations"] := false
		AssertFalse(KeyCombinationsAreOn(), "the pairs go off with their own switch")
	} finally CategoryEnabled := Saved
}
Test("master gates: the key-combinations switch gates only the pairs (key-combinations-gate)",
	TestMasterGates_KeyCombinationsSubGate)

; A config.toml written before the switch existed has no [category_enabled]
; key_combinations: its pairs must stay live. The switch turned off must also
; reach the disk, which the sparse writer only does for a value that differs
; from the manifest default.
TestMasterGates_KeyCombinationsAbsentKeyKeepsPairs() {
	global CategoryEnabled
	Saved := CategoryEnabled.Clone()
	try {
		if CategoryEnabled.Has("KeyCombinations")
			CategoryEnabled.Delete("KeyCombinations")
		AssertTrue(KeyCombinationsAreOn(), "the pairs survive an absent switch")
		AssertTrue(ManifestDefaultFor("category_enabled.key_combinations"),
			"which is the manifest default the menu shows for it")
	} finally CategoryEnabled := Saved
	SwitchedOff := _ConfigSparseOperation("category_enabled", "key_combinations", false)
	AssertFalse(SwitchedOff.HasOwnProp("Delete"), "the switch turned off is written, not dropped as neutral")
}
Test("master gates: an absent key-combinations switch keeps the pairs (key-combinations-gate)",
	TestMasterGates_KeyCombinationsAbsentKeyKeepsPairs)

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

; Boot's captured intent must remain editable while only its runtime is gated.
_A1_WithDesiredFixture(Body) {
	global Features, TapHold, CategoryEnabled, ConfigurationFile
	Saved := Map("features", Features, "tap_hold", TapHold,
		"categories", CategoryEnabled, "path", ConfigurationFile)
	Owner := MasterGateState()
	SavedOwner := Owner.Clone()
	Directory := A_Temp . "\ergopti-a1-desired-" . A_TickCount . "-" . Random(10000, 99999)
	DirCreate(Directory)
	try {
		Owner["initialized"] := false
		Features := Map("layout", Map("ergopti_base", true, "ergopti_alt_gr", false),
			"shortcuts", Map("gpt", Map("enabled", true, "link", "https://example.test")),
			"hotstrings", Map("repeat_key_enabled", true, "trigger_char", "*",
				"rolls", Map("hc", Map("enabled", true))))
		TapHold := Map("keys", Map("caps_lock", Map("tap_action", "enter", "hold_modifier", "ctrl")))
		CategoryEnabled := Map("Layout", false, "Shortcuts", false, "Hotstrings", false,
			"TapHolds", false, "Rolls", false)
		ConfigurationFile := Directory . "\config.toml"
		AssertFalse(FSStrictExists(ConfigurationFile), "desired-state tests own an independent actual absent source")
		Boot := ConfigMigrateBoot(ConfigurationFile)
		AssertEqual("absent", Boot["status"], "real native startup precedes these existing desired-state transaction bodies")
		AssertEqual(0, Boot["read_only"])
		MasterGateInitialize(Features, TapHold, IsCategoryGated)
		Body.Call()
	} finally {
		Features := Saved["features"]
		TapHold := Saved["tap_hold"]
		CategoryEnabled := Saved["categories"]
		ConfigurationFile := Saved["path"]
		Owner.Clear()
		for Key, Value in SavedOwner
			Owner[Key] := Value
		if DirExist(Directory)
			DirDelete(Directory, true)
	}
}

_A1_DesiredMenu() {
	global Features
	AssertFalse(Features["layout"]["ergopti_base"], "the native layout remains inactive")
	Row := MenuRowWithLabel("layout.ergopti_base", "Layout fixture", "Layout")
	AssertTrue(Row is Map, "the desired row is reachable")
	AssertTrue(Row["checked"], "the desired child remains checked behind a disabled master")
	AssertFalse(Row.Get("disabled", false), "a disabled master must not disable its child editor")
}
Test("master intent: disabled masters retain editable checked children (a1-desired)",
	_A1_WithDesiredFixture.Bind(_A1_DesiredMenu))

_A1_DesiredWrite() {
	global Features
	Observed := { updates: [] }
	Writer(Path, Updates) {
		Observed.updates := Updates
		return true
	}
	AssertTrue(WriteFeatureV2(Features, "layout.ergopti_alt_gr", true, "", Writer, (*) => 0))
	AssertFalse(Features["layout"]["ergopti_alt_gr"], "editing a child must not revive runtime under master OFF")
	AssertTrue(ReadFeatureStateV2("layout.ergopti_alt_gr")["enabled"], "the committed desired choice is visible")
	AssertTrue(ReadFeatureStateV2("layout.ergopti_base")["enabled"], "editing a sibling preserves prior intent")
	AssertEqual(1, Observed.updates.Length, "the write crosses the real transaction boundary")
}
Test("master intent: child edits preserve disabled runtime and sibling intent (a1-desired)",
	_A1_WithDesiredFixture.Bind(_A1_DesiredWrite))

_A1_GatesKeepParameters() {
	Candidate := Map("layout", Map("ergopti_base", true, "parameter", "retained"),
		"shortcuts", Map("gpt", Map("enabled", true, "letter", "q"), "delay_ms", 42))
	ApplyMasterGatesToFeatures(Candidate, Map(), (*) => false)
	AssertEqual("retained", Candidate["layout"]["parameter"], "gates preserve string parameters")
	AssertEqual(42, Candidate["shortcuts"]["delay_ms"], "gates preserve numeric parameters")
	AssertEqual("q", Candidate["shortcuts"]["gpt"]["letter"], "disabled alpha features retain their parameter")
	AssertFalse(Candidate["layout"]["ergopti_base"])
	AssertFalse(Candidate["shortcuts"]["gpt"]["enabled"])
}
Test("master intent: runtime projection preserves pure parameters (a1-desired)", _A1_GatesKeepParameters)

; A full save must emit desired children even when their runtime is gated off.
_A1_FullSaveUsesDesired() {
	Updates := _ConfigCollectFullSaveUpdates()
	Found := false
	for Update in Updates {
		if Update.Section == "layout" && Update.Key == "ergopti_base" {
			Found := true
			AssertTrue(Update.HasOwnProp("Value") && Update.Value == true,
				"the desired true override survives a full save behind master OFF")
		}
	}
	AssertTrue(Found, "the full-save collector cannot omit the disabled branch")
}
Test("master intent: full save includes desired children behind disabled masters (a1-sparse)",
	_A1_WithDesiredFixture.Bind(_A1_FullSaveUsesDesired))

; Runtime false is not an OFF receipt when the durable desired value was true.
_A1_ExplicitOffDeletesDesiredOverride() {
	global Features
	Observed := { updates: [] }
	Writer(Path, Updates) {
		Observed.updates := Updates
		return true
	}
	AssertFalse(Features["layout"]["ergopti_base"])
	AssertTrue(WriteFeatureV2(Features, "layout.ergopti_base", false, "", Writer, (*) => 0))
	AssertEqual(1, Observed.updates.Length, "runtime false must not bypass the desired OFF write")
	AssertTrue(Observed.updates[1].HasOwnProp("Delete") && Observed.updates[1].Delete == 1,
		"neutral OFF explicitly deletes the former true override")
	AssertFalse(ReadFeatureStateV2("layout.ergopti_base")["enabled"])
}
Test("master intent: explicit OFF deletes a demoted desired override (a1-sparse)",
	_A1_WithDesiredFixture.Bind(_A1_ExplicitOffDeletesDesiredOverride))

_A1_RefusedWriteRetainsBothStates() {
	global Features
	Desired := MasterGateState()["features"]
	Runtime := Features
	AssertFalse(WriteFeatureV2(Features, "layout.ergopti_base", false, "", (*) => false, (*) => 0))
	AssertTrue(MasterGateState()["features"] == Desired, "refusal cannot publish desired candidates")
	AssertTrue(Features == Runtime, "refusal cannot publish runtime candidates")
	AssertTrue(ReadFeatureStateV2("layout.ergopti_base")["enabled"])
	AssertFalse(Features["layout"]["ergopti_base"])
}
Test("master intent: refused persistence preserves desired and raw runtime (a1-desired)",
	_A1_WithDesiredFixture.Bind(_A1_RefusedWriteRetainsBothStates))

_A1_ReenableDesiredOnly() {
	global Features
	AssertTrue(ToggleCategoryAllFeatures("Layout", true, (*) => true, (*) => 0, (*) => true))
	AssertTrue(Features["layout"]["ergopti_base"], "reenabling restores the desired true child")
	AssertFalse(Features["layout"]["ergopti_alt_gr"], "reenabling does not enable the undesired sibling")
	AssertTrue(ToggleCategoryAllFeatures("Shortcuts", true, (*) => true, (*) => 0, (*) => true))
	AssertTrue(Features["shortcuts"]["gpt"]["enabled"])
	AssertEqual("https://example.test", Features["shortcuts"]["gpt"]["link"], "parameters survive OFF and ON")
}
Test("master intent: reenable restores only desired children (a1-desired)",
	_A1_WithDesiredFixture.Bind(_A1_ReenableDesiredOnly))

_A1_UnrelatedDemotionSurvivesEdit() {
	global Features, CategoryEnabled
	CategoryEnabled["Layout"] := true
	AssertTrue(ReadFeatureStateV2("layout.ergopti_base")["enabled"])
	AssertFalse(Features["layout"]["ergopti_base"])
	AssertTrue(WriteFeatureV2(Features, "layout.ergopti_alt_gr", true, "", (*) => true, (*) => 0))
	AssertFalse(Features["layout"]["ergopti_base"], "a sibling edit cannot reactivate a session-demoted feature")
	AssertTrue(Features["layout"]["ergopti_alt_gr"])
}
Test("master intent: unrelated session demotion survives a child edit (a1-desired)",
	_A1_WithDesiredFixture.Bind(_A1_UnrelatedDemotionSurvivesEdit))

_A1_TapHoldEditWhileDisabled() {
	global TapHold, _ConfigDir, _AhkSubDir
	SavedDir := _ConfigDir
	SavedSubDir := _AhkSubDir
	try {
		_ConfigDir := A_Temp . "\ergopti_a1_taphold_" . A_TickCount . "\"
		_AhkSubDir := ""
		AssertTrue(IsTapHoldTapActive("caps_lock", "enter"), "the tap picker reads retained intent")
		AssertTrue(WriteTapHoldTap("tab", "escape", (*) => true, (*) => true, (*) => true))
		AssertEqual(0, TapHold["keys"].Count, "editing tap-holds under OFF cannot activate native bindings")
		Desired := MasterGateDesiredTapHold(TapHold)
		AssertTrue(Desired["keys"].Has("caps_lock"), "editing another key preserves prior desired bindings")
		AssertEqual("escape", Desired["keys"]["tab"]["tap_action"])
		AssertFalse(WriteTapHoldTap("caps_lock", "space", (*) => false, (*) => true, (*) => true))
		AssertTrue(MasterGateDesiredTapHold(TapHold) == Desired, "refused staging preserves desired identity")
		AssertEqual(0, TapHold["keys"].Count)
	} finally {
		_ConfigDir := SavedDir
		_AhkSubDir := SavedSubDir
	}
}
Test("master intent: tap-hold edits retain desired bindings without activation (a1-desired)",
	_A1_WithDesiredFixture.Bind(_A1_TapHoldEditWhileDisabled))

_A1_EditorsUseDesiredIntent() {
	global Features, HSE_RepeatEnabled, ScriptInformation
	SavedRepeat := HSE_RepeatEnabled
	SavedMagic := ScriptInformation.Get("MagicKey", "")
	try {
		HSE_RepeatEnabled := false
		AssertTrue(ToggleRepeatKeyEnabled((*) => true, (*) => 0, (*) => true))
		AssertFalse(ReadFeatureStateV2("hotstrings.repeat_key_enabled")["enabled"],
			"the repeat editor turns desired true OFF even while its runtime is already false")
		AssertFalse(HSE_RepeatEnabled, "the repeat runtime remains disabled")
		AssertTrue(ModifyMagicKey(0, "#", (*) => true, (*) => 0, (*) => true))
		AssertEqual("#", MasterGateDesiredFeatures(Features)["hotstrings"]["trigger_char"],
			"the magic-key parameter publishes into retained intent")
		AssertTrue(ModifyLink(0, "https://changed.test", (*) => true, (*) => 0, (*) => true))
		AssertEqual("https://changed.test", ReadFeatureStateV2("shortcuts.gpt")["link"])
		AssertFalse(Features["shortcuts"]["gpt"]["enabled"], "parameter edits do not activate shortcuts")
	} finally {
		HSE_RepeatEnabled := SavedRepeat
		ScriptInformation["MagicKey"] := SavedMagic
	}
}
Test("master intent: parameter editors and repeat toggle consume desired state (a1-desired)",
	_A1_WithDesiredFixture.Bind(_A1_EditorsUseDesiredIntent))

_A1_DemotionDuringMasterWrite() {
	global Features, CategoryEnabled
	CategoryEnabled["Layout"] := true
	Features["layout"]["ergopti_base"] := true
	Writer(*) {
		global Features
		Features["layout"]["ergopti_base"] := false
		return true
	}
	AssertTrue(ToggleCategoryAllFeatures("Shortcuts", true, Writer, (*) => 0, (*) => true))
	AssertFalse(Features["layout"]["ergopti_base"],
		"a runtime demotion during unrelated durable I/O must survive category publication")
	AssertTrue(ReadFeatureStateV2("layout.ergopti_base")["enabled"], "session demotion must not erase desired intent")
}
Test("master intent: master publication preserves a concurrent runtime demotion (a1-admission)",
	_A1_WithDesiredFixture.Bind(_A1_DemotionDuringMasterWrite))

_A1_TapWriterSharesMasterAdmission() {
	global _ConfigDir, _AhkSubDir, TapHold
	SavedDir := _ConfigDir
	SavedSubDir := _AhkSubDir
	Observed := { nested: -1 }
	Writer(*) {
		Observed.nested := WriteTapHoldTap("tab", "escape", (*) => true, (*) => true, (*) => true)
		return true
	}
	try {
		_ConfigDir := A_Temp . "\ergopti_a1_admission_" . A_TickCount . "\"
		_AhkSubDir := ""
		AssertTrue(ToggleCategoryAllFeatures("TapHolds", true, Writer, (*) => 0, (*) => true))
		AssertFalse(Observed.nested, "tap edits cannot interleave a master snapshot owned through config.toml")
		AssertTrue(TapHold["keys"].Has("caps_lock"))
		AssertFalse(MasterGateDesiredTapHold(TapHold)["keys"].Has("tab"), "a refused nested edit publishes no desired state")
	} finally {
		_ConfigDir := SavedDir
		_AhkSubDir := SavedSubDir
	}
}
Test("master intent: tap-hold writer shares admission with its category master (a1-admission)",
	_A1_WithDesiredFixture.Bind(_A1_TapWriterSharesMasterAdmission))


_MG_VariantProjectionCase() {
	Desired := Map("layout", Map("ergopti_variant", "ergopti_plus", "ergopti_base", false,
		"ergopti_alt_gr", false, "emulated_layout", ""))
	Effective := _HSDeepCloneMap(Desired)
	_MG_DisableFeatureNode(Effective["layout"], "layout")
	AssertEqual("ergopti", Effective["layout"]["ergopti_variant"], "closed category removes helper effects using its typed inactive value")
	AssertFalse(ErgoptiLayout_PlusIsActive(Effective))
	AssertEqual("ergopti_plus", Desired["layout"]["ergopti_variant"], "effective projection cannot consume saved helper intent")
	AssertFalse(Desired["layout"]["ergopti_base"])
	AssertFalse(Desired["layout"]["ergopti_alt_gr"])
	Effective := _HSDeepCloneMap(Desired)
	Effective["layout"]["emulated_layout"] := "unrecorded"
	_MG_SupersedeForEmulatedLayout(Effective)
	AssertEqual("ergopti", Effective["layout"]["ergopti_variant"])
	AssertFalse(ErgoptiLayout_PlusIsActive(Effective), "even an unavailable raw source supersedes helpers")
	AssertEqual("ergopti_plus", Desired["layout"]["ergopti_variant"])
}
Test("master gates: internal helper variant uses typed projection and retains desired source intent (todo96-helper-variant)",
	_MG_VariantProjectionCase)
