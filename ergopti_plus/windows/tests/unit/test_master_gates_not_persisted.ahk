; tests/unit/test_master_gates_not_persisted.ahk

; ==============================================================================
; MODULE: Master Gates Must Not Replace Saved Intent
; DESCRIPTION:
; A full save once flattened runtime zeroes into configuration, erasing desired
; children behind disabled masters. Omitting those branches avoided the loss but
; also discarded edits made while disabled. The collector now serializes retained
; intent as explicit sparse set/delete operations while preserving unknown TOML.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 1/ Desired persistence ===========
; ==========================================
; ==========================================

_MGP_DesiredBatchPreservesUnknown() {
	global ConfigurationFile, Features
	Original := "[unknown.nested]" . Chr(10) . 'token = "retain"' . Chr(10)
	Original .= "[layout]" . Chr(10) . "ergopti_alt_gr = true" . Chr(10)
	FileAppend(Original, ConfigurationFile, "UTF-8-RAW")
	try {
		Updates := _ConfigCollectFullSaveUpdates()
		AssertTrue(ConfigCommitUpdates(ConfigurationFile, Updates, "desired fixture"),
			"the full-save batch must cross the durable transaction gateway")
		AssertEqual("retain", TOML_Read(ConfigurationFile, "unknown.nested", "token", "missing"),
			"unknown nested keys survive the mixed sparse batch")
		AssertEqual(1, TOML_Read(ConfigurationFile, "layout", "ergopti_base", -1),
			"desired true survives while its runtime master is disabled")
		AssertEqual(-1, TOML_Read(ConfigurationFile, "layout", "ergopti_alt_gr", -1),
			"a desired neutral leaf deletes its previous override rather than omitting it")
		AssertEqual(1, TOML_Read(ConfigurationFile, "hotstrings.rolls.hc", "enabled", -1),
			"disabled hotstring subcategories retain their desired section choices")
		AssertFalse(Features["layout"]["ergopti_base"], "saving cannot activate runtime")
	} finally {
		FileDelete(ConfigurationFile)
	}
}
Test("config_io: sparse desired save preserves disabled children and unknown TOML (a1-sparse)",
	_A1_WithDesiredFixture.Bind(_MGP_DesiredBatchPreservesUnknown))

_MGP_SaveFullConfigCollectsDesired() {
	Save := _StripFullLineComments(_DriverFuncBody("SaveFullConfig"))
	Collector := _StripFullLineComments(_DriverFuncBody("_ConfigCollectFullSaveUpdates"))
	Assert(Save != "" && Collector != "", "both full-save phases must exist")
	Assert(InStr(Save, "_ConfigCollectFullSaveUpdates()") > 0,
		"the durable coordinator must invoke the authoritative collector")
	DesiredPos := InStr(Collector, "MasterGateDesiredFeatures(")
	FlattenPos := InStr(Collector, "_CollectFeatureUpdates(")
	Assert(DesiredPos > 0 && FlattenPos > DesiredPos,
		"the collector must capture retained intent before flattening")
	Assert(InStr(Collector, "_PruneMasterGatedFeatures(") == 0,
		"disabled branches remain editable and cannot be omitted from persistence")
	Assert(InStr(Collector, "_ConfigSparseUpdates(") > FlattenPos,
		"neutral desired values must become explicit deletes")
}
Test("config_io: SaveFullConfig snapshots desired state before collecting", _MGP_SaveFullConfigCollectsDesired)
