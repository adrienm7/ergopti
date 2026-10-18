; tests/unit/infra/config/migration/test_config_migrate_variant_metadata.ahk

; ==============================================================================
; MODULE: Config Migration Variant and Metadata
; DESCRIPTION:
; The joint Ergopti variant operation preserves every legacy layer
; combination and refuses ambiguous intent, and canonical schema metadata is
; kept exactly or refused before backup and publication.
; ==============================================================================

#Requires AutoHotkey v2.0





_CMG_VariantOperation() => Map("op", "move_ergopti_variant", "section", "layout", "key", "ergopti_plus",
	"to_key", "ergopti_variant", "base_key", "ergopti_base", "alt_gr_key", "ergopti_alt_gr",
	"source_key", "emulated_layout", "false_variant", "ergopti", "true_variant", "ergopti_plus")

_CMG_VariantRegistry() {
	return ConfigMigrateValidateRegistry(_ConfigMigrateParse('[registry]`ncurrent_version = 2`nunstamped_version = 1`n'
		. '[steps.v1_to_v2]`nfrom = 1`nto = 2`ndrivers = ["ahk", "hs", "linux"]`n'
		. 'reason = "Independent joint legacy intent."`nops = [{ op = "move_ergopti_variant", section = "layout", '
		. 'key = "ergopti_plus", to_key = "ergopti_variant", base_key = "ergopti_base", alt_gr_key = "ergopti_alt_gr", '
		. 'source_key = "emulated_layout", false_variant = "ergopti", true_variant = "ergopti_plus" }]`n', "joint variant registry"))
}

_CMG_VariantAtomicCase() {
	for Legacy in [false, true] {
		for Base in [false, true] {
			for General in [false, true] {
				for Selected in ["", "unrecorded"] {
					Layer := Map("ergopti_plus", TOML_Bool(Legacy), "ergopti_base", TOML_Bool(Base),
						"ergopti_alt_gr", TOML_Bool(General), "emulated_layout", Selected, "future", "retained")
					Model := Map("layout", Layer, "private", Map("opaque", ["future", 9]))
					Before := _ConfigMigrateClone(Model)
					_ConfigMigrateApplyOp(Model, _CMG_VariantOperation())
					AssertFalse(Layer.Has("ergopti_plus"), "recognized legacy ownership is consumed exactly once")
					AssertEqual(Legacy ? "ergopti_plus" : "ergopti", Layer["ergopti_variant"])
					for Key in ["ergopti_base", "ergopti_alt_gr", "emulated_layout", "future"]
						AssertTrue(ConfigMigrateSameValue(Before["layout"][Key], Layer[Key]), "joint migration retains independent intent")
					AssertTrue(ConfigMigrateSameValue(Before["private"], Model["private"]))
					After := _ConfigMigrateClone(Model)
					_ConfigMigrateApplyOp(Model, _CMG_VariantOperation())
					AssertTrue(ConfigMigrateSameModel(After, Model), "recognized absent-source replay is inert")
				}
			}
		}
	}
	for Fault in ["legacy-integer", "legacy-string", "base-integer", "altgr-string", "source-boolean", "unknown", "conflict", "casealias", "unknown-absent", "casealias-absent"] {
		Layer := Map("ergopti_plus", TOML_Bool(true), "ergopti_base", TOML_Bool(false),
			"ergopti_alt_gr", TOML_Bool(false), "emulated_layout", "", "future", "retained")
		if Fault == "legacy-integer"
			Layer["ergopti_plus"] := 1
		else if Fault == "legacy-string"
			Layer["ergopti_plus"] := "true"
		else if Fault == "base-integer"
			Layer["ergopti_base"] := 0
		else if Fault == "altgr-string"
			Layer["ergopti_alt_gr"] := "false"
		else if Fault == "source-boolean"
			Layer["emulated_layout"] := TOML_Bool(false)
		else
			Layer["ergopti_variant"] := InStr(Fault, "unknown") ? "future" : InStr(Fault, "casealias") ? "ERGOPTI_PLUS" : "ergopti"
		if InStr(Fault, "-absent")
			Layer.Delete("ergopti_plus")
		Model := Map("layout", Layer)
		Before := _ConfigMigrateClone(Model)
		Failure := _CMG_VariantThrown(() => _ConfigMigrateApplyOp(Model, _CMG_VariantOperation()))
		AssertTrue(Failure is ConfigMigrateVariantRefusal, "joint refusal has the startup-stop type")
		AssertContains(Failure.Message, "Ergopti variant migration refused:")
		AssertTrue(ConfigMigrateSameModel(Before, Model), "even direct mutable operation refuses before deleting historical intent")
	}
}
Test("config migrate: joint variant operation preserves every legacy layer combination and refuses before consumption (todo96-helper-variant)",
	_CMG_VariantAtomicCase)

_CMG_VariantBootRefusalCase() {
	Directory := _CMG_NewDir()
	try {
		for Choice in ["future", "ergopti", "ERGOPTI_PLUS"] {
			Path := Directory . "\" . Choice . ".toml"
			Source := '; independent retained bytes`n[_meta]`nschema_version = 11`n[layout]`nergopti_plus = true`n'
				. 'ergopti_variant = "' . Choice . '"`nergopti_base = false`nergopti_alt_gr = false`nemulated_layout = ""`n'
			AssertTrue(FSWriteDurable(Path, Source))
			Failure := _CMG_VariantThrown(() => ConfigMigrateBoot(Path))
			AssertTrue(Failure is ConfigMigrateVariantRefusal, "actual boot cannot admit a successor with unknown/conflicting helper intent")
			AssertContains(Failure.Message, "Ergopti variant migration refused:")
			AssertTrue(FSUtf8ExactMatches(Path, Source), "actual boot refusal keeps every original byte")
			AssertFalse(TOML_BatchWrite(Path, [{Section: "layout", Key: "ergopti_variant", Value: "ergopti_plus"}]),
				"the existing session refusal owner disarms subsequent saves")
			AssertTrue(FSUtf8ExactMatches(Path, Source))
		}
	} finally DirDelete(Directory, true)
}
Test("config migrate: actual boot rejects readiness on unknown or conflicting joint variant intent (todo96-helper-variant)",
	_CMG_VariantBootRefusalCase)

_CMG_VariantThrown(Fn) {
	try Fn.Call()
	catch as Failure
		return Failure
	throw Error("The actual variant operation should have refused.")
}


_CMG_VariantBootPhysicalRefusalCase() {
	Directory := _CMG_NewDir()
	Sources := [
		'[_meta]`nschema_version = 11`nlayout = { future = "unrelated" }`n',
		'layout = { ergopti_plus = true, ergopti_base = false, ergopti_alt_gr = false, emulated_layout = "" }`n[_meta]`nschema_version = 11`n',
		'[_meta]`nschema_version = 11`n[[layout]]`nergopti_plus = true`nergopti_base = false`nergopti_alt_gr = false`nemulated_layout = ""`n',
		'[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion() . '`n[layout]`nergopti_plus = true`n',
		'[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion() . '`n[layout]`nergopti_variant = "future"`n'
	]
	try {
		for Index, Source in Sources {
			Path := Directory . "\physical" . Index . ".toml"
			AssertTrue(FSWriteDurable(Path, Source))
			if Index == 1 {
				Result := ConfigMigrateBoot(Path)
				AssertTrue(Result is Map, "an unrelated opaque owner retains the existing generic startup policy")
			} else {
				Failure := _CMG_VariantThrown(() => ConfigMigrateBoot(Path))
				AssertTrue(Failure is ConfigMigrateVariantRefusal, "actual boot cannot ignore historical/current variant ownership on generic record refusal")
				AssertContains(Failure.Message, "Ergopti variant migration refused:")
				AssertTrue(FSUtf8ExactMatches(Path, Source))
			}
		}
	} finally DirDelete(Directory, true)
}
Test("config migrate: physical refusal and current-source ambiguity cannot silently neutralize a variant owner (todo96-helper-variant)",
	_CMG_VariantBootPhysicalRefusalCase)

_CMG_NeutralVariantCase() {
	Operation := _CMG_VariantOperation()
	Operation["neutral_variant"] := "none"
	_ConfigMigrateValidateOp(Operation, "independent neutral admission")
	for Bad in [false, 1, "ergopti", "ergopti_plus"] {
		Malformed := Operation.Clone()
		Malformed["neutral_variant"] := Bad
		Failure := _CMG_VariantThrown(() => _ConfigMigrateValidateOp(Malformed, "independent neutral admission"))
		AssertContains(Failure.Message, "neutral variant")
	}
	Model := Map("layout", Map("ergopti_variant", "none", "ergopti_base", TOML_Bool(true),
		"ergopti_alt_gr", TOML_Bool(false), "emulated_layout", ""))
	Before := _ConfigMigrateClone(Model)
	_ConfigMigrateApplyOp(Model, Operation)
	AssertTrue(ConfigMigrateSameModel(Before, Model))
	Directory := _CMG_NewDir()
	try {
		Path := Directory . "\neutral.toml"
		Source := '[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion()
			. '`n[layout]`nergopti_variant = "none"`nergopti_base = true`nergopti_alt_gr = false`nemulated_layout = ""`n'
		AssertTrue(FSWriteDurable(Path, Source))
		Result := ConfigMigrateBoot(Path)
		AssertEqual("current", Result["status"])
		AssertFalse(Result.Get("read_only", false))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally DirDelete(Directory, true)
	for Layer in [Map("ergopti_plus", TOML_Bool(false), "ergopti_variant", "none"),
		Map("ergopti_variant", Map("value", "none")), Map("ergopti_variant", "NONE")] {
		Model := Map("layout", Layer)
		Before := _ConfigMigrateClone(Model)
		Failure := _CMG_VariantThrown(() => _ConfigMigrateApplyOp(Model, Operation))
		AssertContains(Failure.Message, "Ergopti variant migration refused:")
		AssertTrue(ConfigMigrateSameModel(Before, Model))
	}
}
Test("config migrate: neutral current choice remains distinct from legacy false and occupied owners (todo96-helper-variant)",
	_CMG_NeutralVariantCase)


; Independent complete source subjects distinguish semantic metadata from the
; migration operation model. The existing native boot owner receives each one;
; callbacks only observe that no backup or publication effect was attempted.
_CMG_CanonicalMetadataBoot(Metadata, ExpectedStatus, ExpectedVersion) {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Registry := _CMR_CopyRegistry()
	Source := Metadata . '`n[future]`nkeep = { flag=false, number=1, text="1" } # preserve`n'
	Calls := { Backup: 0, Publish: 0 }
	Backup(Destination, Content) {
		Calls.Backup += 1
		return 1
	}
	Publish(Destination, Candidate, Previous) {
		Calls.Publish += 1
		return ""
	}
	try {
		AssertTrue(FSWriteDurable(Path, Source), "the complete native subject must exist")
		Plan := ConfigMigratePlan(Source, Registry, "ahk")
		AssertEqual(ExpectedStatus, Plan["outcome"], "canonical metadata owns the pure plan")
		AssertFalse(Plan.Has("candidate"), "current or refused metadata has no rewrite candidate")
		if ExpectedStatus == "failed"
			AssertContains(Plan["detail"], "legacy metadata is not addressable", "the actual physical owner supplies the refusal")
		Result := ConfigMigrateRun(Path, Registry, _CMG_STAMP, Backup, Publish)
		AssertEqual(ExpectedStatus, Result["status"], "the native migration runner has the same decision")
		if ExpectedStatus == "failed"
			AssertContains(Result["detail"], "legacy metadata is not addressable", "the runner preserves the physical ownership reason")
		AssertEqual(0, Calls.Backup, "metadata classification precedes every backup effect")
		AssertEqual(0, Calls.Publish, "metadata classification precedes every publication effect")
		AssertEqual("", Result["backup"], "no unused backup intention may be published")
		AssertTrue(FSUtf8ExactMatches(Path, Source), "every subject preserves its complete source bytes")
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertTrue(Document["future"]["keep"]["flag"] is TOML_Bool)
		AssertEqual(false, Document["future"]["keep"]["flag"].Value)
		AssertTrue(Document["future"]["keep"]["number"] is Integer)
		AssertTrue(Document["future"]["keep"]["text"] is String)
		if ExpectedStatus == "current" {
			AssertEqual(ExpectedVersion, Result["from"], "a canonical current stamp is not an unstamped file")
			AssertEqual(0, Result["read_only"])
			AssertEqual("", TOML_WriteRefusal(Path), "a genuine current document needs no migration refusal")
		} else {
			AssertEqual(1, Result["read_only"])
			Assert(TOML_WriteRefusal(Path) != "", "the actual boot owner latches the refusal")
			AssertFalse(TOML_ConfigBatchWrite(Path, []), "even a configuration no-op retains that refusal")
			AssertFalse(TOML_ConfigBatchWrite(Path, [{ Section: "future", Key: "changed", Value: 7 }]))
			AssertTrue(FSUtf8ExactMatches(Path, Source), "subsequent writes retain complete source bytes")
		}
	} finally {
		Refusals := _TOML_WriteRefusals(), RefusalKey := _TOML_WriteRefusalKey(Path)
		if Refusals.Has(RefusalKey)
			Refusals.Delete(RefusalKey)
		DirDelete(Dir, true)
	}
}

for Index, Metadata in ['_meta.schema_version = 2', '_meta = { schema_version=2 }',
		'["_meta"]`n"schema_version" = 2',
		'"_meta.schema_version" = 999`n_meta.schema_version = 2'] {
	Test("config migrate: current canonical metadata preserves exact source " . Index,
		_CMG_CanonicalMetadataBoot.Bind(Metadata, "current", 2))
}

for Index, Subject in [
	{ Metadata: '_meta = true', Status: "invalid" },
	{ Metadata: '[["_meta"]]`nschema_version = 2', Status: "invalid" },
	{ Metadata: '_meta.schema_version = "2"', Status: "invalid" },
	{ Metadata: '_meta = { schema_version=false }', Status: "invalid" },
	{ Metadata: '_meta.schema_version = 3', Status: "newer" },
	{ Metadata: '_meta = { schema_version=3 }', Status: "newer" },
	{ Metadata: '_meta.schema_version = 1', Status: "failed" },
	{ Metadata: '_meta = { schema_version=1 }', Status: "failed" }
] {
	Test("config migrate: canonical metadata refuses before backup and publication " . Index,
		_CMG_CanonicalMetadataBoot.Bind(Subject.Metadata, Subject.Status, 0))
}
