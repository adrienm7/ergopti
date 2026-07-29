; tests/unit/test_master_gates_not_persisted.ahk

; ==============================================================================
; MODULE: Regression — a runtime master gate must never be written to disk
; DESCRIPTION:
; ApplyMasterGatesToFeatures zeroes a master-disabled category's features IN
; PLACE, and its own module header states the contract: the per-feature state
; persisted on disk is NOT touched, it stays in config.toml and is restored at
; the next Reload once the master flips back on.
;
; ROOT CAUSE ENCODED:
; SaveFullConfig had no notion of that distinction. It flattened the same live
; Features map, so the boot-armed save (armed at boot right AFTER the gates are
; applied) serialised the runtime zeroes as if they were the user's intent.
; Turning a category off therefore erased every per-feature choice it contained,
; permanently: re-enabling the category later showed every child unticked, with
; no error, no log line and nothing to connect it to the save that caused it.
; The same happens without a reboot on any live SaveFullConfig call made while a
; gate is off.
;
; The fix omits a gated-off branch from the collected updates. TOML_BatchWrite
; preserves keys it does not re-collect, so the on-disk values survive untouched
; for exactly as long as the gate is off — which is what the gate already
; promised.
; ==============================================================================

#Requires AutoHotkey v2.0

; The stubbed CategoryEnabled map carries only the four categories the harness
; needs (Layout, Shortcuts, Hotstrings, TapHolds), so a bare read of Rolls or
; Autocorrection raises "Item has no value". Save through a sentinel and restore
; by removing the keys this test invented, exactly like test_master_gates.ahk.
_MGP_SaveGate(Name) {
	global CategoryEnabled
	return CategoryEnabled.Has(Name) ? CategoryEnabled[Name] : "<absent>"
}
_MGP_RestoreGate(Name, Saved) {
	global CategoryEnabled
	if (Saved == "<absent>") {
		if CategoryEnabled.Has(Name)
			CategoryEnabled.Delete(Name)
		return
	}
	CategoryEnabled[Name] := Saved
}





; ==============================================================
; ==============================================================
; ======= 1/ Shared fixture ====================================
; ==============================================================
; ==============================================================

; Mirrors the real tree shape: a top-level gated category (layout) plus the
; hotstrings sub-tree, whose sub-categories carry their own independent gates.
_MGP_Fixture() {
	return Map(
		"layout", Map("ergopti_base", true, "ergopti_alt_gr", true),
		"hotstrings", Map(
			"rolls",          Map("hc", Map("enabled", true)),
			"autocorrection", Map("errors", Map("enabled", true))
		)
	)
}

; A throwaway TapHold target so the gate application never touches the global.
_MGP_TapHoldStub() {
	return Map("keys", Map(), "layers", Map())
}

; Run the exact composition SaveFullConfig uses to build its feature writes.
_MGP_Collect(FeaturesMap) {
	Updates := []
	_CollectFeatureUpdates(Updates, "", _PruneMasterGatedFeatures(FeaturesMap))
	return Updates
}

; True when some update writes Key into a section naming Needle. Matching on the
; section SUBSTRING rather than the fully resolved name keeps this test about
; persistence, not about the manifest's ahk.-prefix resolution (which
; test_config_io_feature_section_prefix.ahk already owns).
_MGP_HasKeyUnder(Updates, Needle, Key) {
	for U in Updates {
		if (InStr(U.Section, Needle) and U.Key = Key)
			return true
	}
	return false
}





; ==============================================================
; ==============================================================
; ======= 2/ Top-level master gate =============================
; ==============================================================
; ==============================================================

_MGP_GatedCategoryContributesNoWrite() {
	global CategoryEnabled
	ManifestEnsureLoaded()
	OldLayout := _MGP_SaveGate("Layout")
	OldHotstrings := _MGP_SaveGate("Hotstrings")
	OldRolls := _MGP_SaveGate("Rolls")
	OldAuto := _MGP_SaveGate("Autocorrection")
	try {
		CategoryEnabled["Hotstrings"] := true
		CategoryEnabled["Rolls"] := true
		CategoryEnabled["Autocorrection"] := true

		; Positive control FIRST, so the assertions below cannot pass merely
		; because the collector emitted nothing at all.
		CategoryEnabled["Layout"] := true
		OnFeatures := _MGP_Fixture()
		ApplyMasterGatesToFeatures(OnFeatures, _MGP_TapHoldStub(), IsCategoryGated)
		OnUpdates := _MGP_Collect(OnFeatures)
		AssertTrue(_MGP_HasKeyUnder(OnUpdates, "layout", "ergopti_base"),
			"an un-gated category must still be serialised")
		AssertTrue(_MGP_HasKeyUnder(OnUpdates, "layout", "ergopti_alt_gr"),
			"an un-gated category must still be serialised")

		CategoryEnabled["Layout"] := false
		OffFeatures := _MGP_Fixture()
		ApplyMasterGatesToFeatures(OffFeatures, _MGP_TapHoldStub(), IsCategoryGated)
		AssertFalse(OffFeatures["layout"]["ergopti_base"],
			"sanity: the runtime gate zeroes the live map in place — that is the value the save must NOT persist")

		OffUpdates := _MGP_Collect(OffFeatures)
		AssertFalse(_MGP_HasKeyUnder(OffUpdates, "layout", "ergopti_base"),
			"a master-gated-off category must contribute NO feature write: the zeroes in Features are a RUNTIME gate, and persisting them destroys the per-feature settings the gate promised to preserve on disk")
		AssertFalse(_MGP_HasKeyUnder(OffUpdates, "layout", "ergopti_alt_gr"),
			"a master-gated-off category must contribute NO feature write for any of its leaves")
		; The rest of the tree must keep being saved — refusing everything would
		; be a different bug wearing the same green tick.
		AssertTrue(_MGP_HasKeyUnder(OffUpdates, "rolls", "enabled"),
			"gating one category off must not stop the others from being serialised")
	} finally {
		_MGP_RestoreGate("Layout", OldLayout)
		_MGP_RestoreGate("Hotstrings", OldHotstrings)
		_MGP_RestoreGate("Rolls", OldRolls)
		_MGP_RestoreGate("Autocorrection", OldAuto)
	}
}





; ==============================================================
; ==============================================================
; ======= 3/ Hotstring sub-category gates ======================
; ==============================================================
; ==============================================================

_MGP_GatedSubCategoryContributesNoWrite() {
	global CategoryEnabled
	ManifestEnsureLoaded()
	OldHotstrings := _MGP_SaveGate("Hotstrings")
	OldRolls := _MGP_SaveGate("Rolls")
	OldAuto := _MGP_SaveGate("Autocorrection")
	try {
		CategoryEnabled["Hotstrings"] := true
		CategoryEnabled["Autocorrection"] := true
		CategoryEnabled["Rolls"] := false

		Feat := _MGP_Fixture()
		ApplyMasterGatesToFeatures(Feat, _MGP_TapHoldStub(), IsCategoryGated)
		AssertFalse(Feat["hotstrings"]["rolls"]["hc"]["enabled"],
			"sanity: the sub-category gate zeroes only its own branch in place")

		Updates := _MGP_Collect(Feat)
		AssertFalse(_MGP_HasKeyUnder(Updates, "rolls", "enabled"),
			"a gated-off hotstring sub-category must contribute NO feature write — its sections were zeroed by the runtime gate, and persisting that wipes the user's per-section choices under that category")
		AssertTrue(_MGP_HasKeyUnder(Updates, "autocorrection", "enabled"),
			"an un-gated sibling sub-category must still be serialised")
	} finally {
		_MGP_RestoreGate("Hotstrings", OldHotstrings)
		_MGP_RestoreGate("Rolls", OldRolls)
		_MGP_RestoreGate("Autocorrection", OldAuto)
	}
}





; ==============================================================
; ==============================================================
; ======= 4/ The writer really uses the filter =================
; ==============================================================
; ==============================================================

; The behavioural cases above exercise the composition directly; this pins that
; SaveFullConfig is what performs it, so the filter cannot be left orphaned.
_MGP_SaveFullConfigFiltersBeforeCollecting() {
	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig() must exist")
	Assert(InStr(Body, "_CollectFeatureUpdates") > 0,
		"SaveFullConfig must still flatten the feature tree")
	Assert(InStr(Body, "_PruneMasterGatedFeatures") > 0,
		"SaveFullConfig must feed the collector a gate-filtered view of Features — walking the live map serialises the runtime zeroes ApplyMasterGatesToFeatures wrote for gating purposes only")
}


Test("config_io: a master-gated-off category is not serialised", _MGP_GatedCategoryContributesNoWrite)
Test("config_io: a gated-off hotstring sub-category is not serialised", _MGP_GatedSubCategoryContributesNoWrite)
Test("config_io: SaveFullConfig filters the feature tree before collecting", _MGP_SaveFullConfigFiltersBeforeCollecting)
