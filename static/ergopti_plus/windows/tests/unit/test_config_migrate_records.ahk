; tests/unit/test_config_migrate_records.ahk

; ==============================================================================
; MODULE: Config Migration Record Bytes Tests
; DESCRIPTION:
; Pins exact handwritten candidates through the real Windows migration plan,
; separately from semantic corpus replay. Lexical regressions also exercise
; the actual record renderer, including opaque values and refusal to edit
; ambiguous quoted identities. Ordinary TOML writes keep their existing owner.
; ==============================================================================

#Requires AutoHotkey v2.0

_CMR_CorpusDir() {
	global _SharedDir
	return _SharedDir . "\tests\corpus\config_migration_record_bytes"
}

_CMR_Transform(Bytes, Variant) {
	if Variant == "bom-crlf"
		return Chr(0xFEFF) . StrReplace(Bytes, "`n", "`r`n")
	if Variant == "no-final-lf"
		return RegExReplace(Bytes, "`n$")
	return Bytes
}

_CMR_PhysicalCase(Name, Variant) {
	Directory := _CMR_CorpusDir() . "\" . Name
	Input := _CMR_Transform(_CMG_Read(Directory . "\input.toml"), Variant)
	ExpectedPath := Directory . (Name == "changed" ? "\expected_windows.toml" : "\expected.toml")
	Expected := _CMR_Transform(_CMG_Read(ExpectedPath), Variant)
	Registry := ConfigMigrateLoadRegistry(Directory . "\migrations.toml")
	Plan := ConfigMigratePlan(Input, Registry, "ahk")
	AssertEqual("migrated", Plan["outcome"], Plan["detail"])
	Assert(StrCompare(Expected, Plan["candidate"], true) == 0, "every handwritten candidate byte")
	Assert(ConfigMigrateSameModel(Plan["model"], _ConfigMigrateParse(Expected, "independent record bytes")),
		"the whole independent model, including scalar types")
	Replay := ConfigMigratePlan(Plan["candidate"], Registry, "ahk")
	AssertEqual("current", Replay["outcome"], "a candidate is never rewritten on replay")
}

for _cmr_Name in ["occupied", "changed", "moves"] {
	for _cmr_Variant in ["lf", "bom-crlf", "no-final-lf"] {
		if _cmr_Name == "moves" && _cmr_Variant == "no-final-lf"
			continue
		Test("config migrate records: " . _cmr_Name . ": " . _cmr_Variant . " (config-migrate-records)",
			_CMR_PhysicalCase.Bind(_cmr_Name, _cmr_Variant))
	}
}

_CMR_LexicalOpaqueRecords() {
	Triple := Chr(34) . Chr(34) . Chr(34)
	LiteralTriple := Chr(39) . Chr(39) . Chr(39)
	Input := Chr(0xFEFF) . '# Root prefix`r`n[future] # header`r`n'
		. 'text = ' . Triple . '`r`n[not.a.header]`r`n# literal comment`r`n'
		. 'escaped \" still data`r`n' . Triple . Chr(34) . '`r`n'
		. 'literal = ' . LiteralTriple . '`r`n[[not.an.owner]]`r`n' . LiteralTriple . Chr(39) . '`r`n'
		. 'rows = [`r`n["[array.header]", "hash # data"],`r`n[true, false]`r`n]`r`n'
		. '["foreign.owner"] # quoted dot`r`n"Key=with#data" = "untouched"'
	Scan := _ConfigMigrateRecordScan(Input)
	AssertEqual(2, Scan.Headers.Length, "header-looking value lines never acquire ownership")
	AssertEqual(4, Scan.Records.Length, "each multiline value remains one physical record")
	AssertTrue(Scan.Records[1].MultilineString, "the basic triple-quoted record exposes unsupported native ownership")
	AssertTrue(Scan.Records[2].MultilineString, "the literal triple-quoted record exposes unsupported native ownership")
	AssertFalse(Scan.Records[3].MultilineString, "an ordinary multiline array does not acquire string ownership")
	AssertEqual("future", Scan.Records[1].Header.Section)
	AssertEqual('"Key=with#data"', Scan.Records[4].Key, "quoted equals remains part of a key")
	Rendered := _ConfigMigrateRenderRecords(Input, [], [])
	Assert(StrCompare(Input, Rendered["content"], true) == 0, "zero deltas preserve every opaque byte, BOM, CRLF and absent final terminator")
}
Test("config migrate records: multiline strings and arrays keep lexical ownership (config-migrate-record-lexer)",
	_CMR_LexicalOpaqueRecords)

_CMR_RefusesAmbiguousEditedIdentities() {
	QuotedHeader := '["source"]`nchoice = true`n'
	QuotedKey := '[source]`n"choice" = true`n'
	DottedKey := '[source]`nchoice.future = true`n'
	ArrayTable := '[[source]]`nchoice = true`n[source.child]`nchoice = true`n'
	Duplicate := '[source]`nchoice = true`nchoice = false`n'
	Update := [{ Section: "source", Key: "choice", Value: TOML_Bool(false) }]
	for Input in [QuotedHeader, QuotedKey, DottedKey, ArrayTable, Duplicate]
		AssertThrows(_ConfigMigrateRenderRecords.Bind(Input, Update, []), "ambiguous owned identities refuse instead of rewriting unrelated records")
	AssertThrows(() => _ConfigMigrateRenderRecords(QuotedKey, [], ["source"]), "dropping a table containing an opaque key refuses")
	AssertThrows(() => _ConfigMigrateRenderRecords(ArrayTable, [], ["source"]), "dropping a table-array owner refuses")
	Assert(StrCompare(QuotedHeader, _ConfigMigrateRenderRecords(QuotedHeader, [], [])["content"], true) == 0,
		"an untouched quoted owner remains byte-for-byte usable")
}
Test("config migrate records: ambiguous edits refuse without changing foreign ownership (config-migrate-record-refusal)",
	_CMR_RefusesAmbiguousEditedIdentities)

_CMR_OrdinaryWriterKeepsItsCanonicalContract() {
	Input := '# canonical saves have their own policy`n[source]`nchoice = true # old comment`n'
	Built := _TOML_BatchWriteImpl("config-records:ordinary-writer", [], [], "build", Input)
	AssertEqual("ok", Built["status"])
	; Canonical value rendering owns changed assignments, not foreign comments.
	Expected := Chr(0xFEFF) . '# canonical saves have their own policy`n[source]`nchoice = true # old comment`n'
	AssertEqual(Expected, Built["content"], "ordinary no-op rendering retains every unowned source record and comment")
	Typed := TOML_ParseDocument(Built["content"])
	AssertTrue(Typed["source"]["choice"] is TOML_Bool, "the canonical value remains a Boolean, not numeric one")
	AssertEqual(1, Typed["source"]["choice"].Value)
	Assert(ConfigMigrateSameModel(_ConfigMigrateParse(Input, "ordinary before"),
		_ConfigMigrateParse(Built["content"], "ordinary after")), "ordinary saves keep their typed model")
}
Test("config migrate records: ordinary writes retain typed values and unowned records (config-migrate-record-ordinary)",
	_CMR_OrdinaryWriterKeepsItsCanonicalContract)

_CMR_CopyRegistry() {
	return ConfigMigrateValidateRegistry(_ConfigMigrateParse('[registry]`ncurrent_version = 2`nunstamped_version = 1`n'
		. '[steps.v1_to_v2]`nfrom = 1`nto = 2`ndrivers = ["ahk", "hs", "linux"]`n'
		. 'reason = "Independent physical source ownership."`n'
		. 'ops = [{ op = "copy_if_absent", section = "source", key = "choice", to_section = "destination", to_key = "choice" }]`n',
		"physical source registry"))
}

_CMR_NativePlanRefusesForeignStringSources() {
	Registry := _CMR_CopyRegistry()
	Triple := Chr(39) . Chr(39) . Chr(39)
	Foreign := '[future]`ntext = ' . Triple . '`n[source]`nchoice = "foreign string"`n' . Triple . '`n'
	ForeignCurrent := '[future]`ntext = ' . Triple . '`n[_meta]`nschema_version = 2`n' . Triple . '`n'
	PhysicalVersion := '[_meta]`nschema_version = 1`n' . ForeignCurrent
	PhysicalScan := _ConfigMigrateRecordScan(PhysicalVersion)
	AssertEqual("_meta", PhysicalScan.Records[1].Header.Section, "a real version identity exists before the foreign string")
	AssertEqual("schema_version", PhysicalScan.Records[1].Key)
	AssertEqual(2, _ConfigMigrateParse(PhysicalVersion, "phantom current version")["_meta"]["schema_version"],
		"the historical native reader overwrites the real version with foreign string content")
	for Input in [Foreign, '[source]`nchoice = "legitimate"`n' . Foreign, ForeignCurrent, PhysicalVersion] {
		Plan := ConfigMigratePlan(Input, Registry, "ahk")
		AssertEqual("failed", Plan["outcome"], "unrepresentable native ownership cannot publish a phantom source")
		AssertFalse(Plan.Has("candidate"), "no changed candidate is exposed")
		AssertContains(Plan["detail"], "multiline string ownership", "the refusal names the unsupported native structure")
	}
}
Test("config migrate records: native plan refuses foreign strings that fabricate or overwrite source values (config-migrate-record-source)",
	_CMR_NativePlanRefusesForeignStringSources)

_CMR_NativeCopyRequiresAnAddressableSource() {
	Registry := _CMR_CopyRegistry()
	OpaqueSource := '[[source]]`nchoice = "array element"`n'
	Plan := ConfigMigratePlan(OpaqueSource, Registry, "ahk")
	AssertEqual("failed", Plan["outcome"], "an array-table element is not a scalar source")
	AssertFalse(Plan.Has("candidate"))
	AssertContains(Plan["detail"], "not an addressable physical TOML record")
	Input := '[source]`nchoice = "legitimate"`n`n[[foreign]]`nchoice = "opaque future owner"`n'
	Plan := ConfigMigratePlan(Input, Registry, "ahk")
	AssertEqual("migrated", Plan["outcome"], Plan["detail"])
	AssertEqual("legitimate", Plan["model"]["destination"]["choice"], "only the actual scalar source is copied")
	AssertContains(Plan["candidate"], Input, "a foreign table array keeps every original byte")
}
Test("config migrate records: copies require physical scalar sources and preserve unrelated table arrays (config-migrate-record-array-source)",
	_CMR_NativeCopyRequiresAnAddressableSource)

_CMR_NativeRefusalUsesTheBootOwner() {
	global _CMG_STAMP
	Directory := _CMG_NewDir()
	try {
		Path := Directory . "\config.toml"
		Triple := Chr(39) . Chr(39) . Chr(39)
		ForeignCurrent := '[future]`ntext = ' . Triple . '`n[_meta]`nschema_version = 2`n' . Triple . '`n'
		Inputs := ['[[source]]`nchoice = "array element"`n', ForeignCurrent,
			'[_meta]`nschema_version = 1`n' . ForeignCurrent]
		Calls := { Backup: 0, Publish: 0 }
		Backup(Path, Bytes) {
			Calls.Backup += 1
			return 1
		}
		Publish(Path, Candidate, Source) {
			Calls.Publish += 1
			return ""
		}
		for Index, Input in Inputs {
			Path := Directory . "\config" . Index . ".toml"
			AssertTrue(FSWriteDurable(Path, Input))
			Result := ConfigMigrateRun(Path, _CMR_CopyRegistry(), _CMG_STAMP, Backup, Publish)
			AssertEqual("failed", Result["status"], "even a fabricated current version cannot bypass the owner")
			AssertEqual(1, Result["read_only"], "a renderer refusal disarms later writes")
			AssertEqual(0, Calls.Backup, "no backup begins before physical ownership is proved")
			AssertEqual(0, Calls.Publish, "no candidate reaches the publication owner")
			Assert(FSUtf8ExactMatches(Path, Input), "the original file keeps every byte")
			AssertFalse(TOML_BatchWrite(Path, [{ Section: "source", Key: "choice", Value: "changed" }]),
				"the existing session refusal owner blocks later saves")
			Assert(FSUtf8ExactMatches(Path, Input), "a refused later save keeps every byte")
		}
	} finally DirDelete(Directory, true)
}
Test("config migrate records: physical refusal goes through the actual read-only boot owner (config-migrate-record-boot-refusal)",
	_CMR_NativeRefusalUsesTheBootOwner)

_CMR_TargetRegistry(Kind) {
	if Kind == "copy_if_absent"
		Op := '{ op = "copy_if_absent", section = "source", key = "choice", to_section = "foo.bar", to_key = "choice" }'
	else if Kind == "rename"
		Op := '{ op = "rename", section = "source", key = "choice", to_section = "foo.bar", to_key = "choice" }'
	else if Kind == "move_section"
		Op := '{ op = "move_section", section = "source", to_section = "foo.bar" }'
	else if Kind == "set_if_absent"
		Op := '{ op = "set_if_absent", section = "foo.bar", key = "choice", value = "default" }'
	else
		throw ValueError("unknown target fixture operation")
	return ConfigMigrateValidateRegistry(_ConfigMigrateParse('[registry]`ncurrent_version = 2`nunstamped_version = 1`n'
		. '[steps.v1_to_v2]`nfrom = 1`nto = 2`ndrivers = ["ahk", "hs", "linux"]`n'
		. 'reason = "Independent occupied target namespace."`nops = [' . Op . ']`n', "target namespace registry"))
}

_CMR_TargetNamespacesRemainOwned() {
	Source := '[source]`nchoice = "legitimate"`n'
	Roots := ['foo = 1`n', 'foo = { bar = "future inline owner" }`n',
		'foo.bar = "future dotted owner"`n', '"foo" = "future quoted owner"`n']
	for Root in Roots {
		Plan := ConfigMigratePlan(Root . Source, _CMR_TargetRegistry("copy_if_absent"), "ahk")
		AssertEqual("failed", Plan["outcome"], "a retained root namespace cannot become a new table")
		AssertFalse(Plan.Has("candidate"))
		AssertContains(Plan["detail"], "physical TOML value namespace")
	}
	for Kind in ["rename", "move_section", "set_if_absent"] {
		Input := Source . '[foo]`nbar = { future = "owned inline namespace" }`n'
		Plan := ConfigMigratePlan(Input, _CMR_TargetRegistry(Kind), "ahk")
		AssertEqual("failed", Plan["outcome"], "render admission preserves the occupied target without changing op policy")
		AssertFalse(Plan.Has("candidate"))
	}
	Input := '_meta = { schema_version = 1 }`n' . Source
	Plan := ConfigMigratePlan(Input, _CMR_CopyRegistry(), "ahk")
	AssertEqual("failed", Plan["outcome"], "a root metadata owner cannot be silently replaced by a new header")
	AssertFalse(Plan.Has("candidate"))
	Input := '"foo.bar" = "literal dot owner"`n' . Source
	Plan := ConfigMigratePlan(Input, _CMR_TargetRegistry("copy_if_absent"), "ahk")
	AssertEqual("migrated", Plan["outcome"], Plan["detail"])
	AssertEqual("legitimate", Plan["model"]["foo.bar"]["choice"])
	AssertContains(Plan["candidate"], '"foo.bar" = "literal dot owner"`n', "a quoted literal dot remains distinct from a dotted target")
}
Test("config migrate records: root and inline target namespaces stay independently owned (config-migrate-record-target-namespace)",
	_CMR_TargetNamespacesRemainOwned)

_CMR_TargetAdmissionAllowsOwnedRemoval() {
	Input := '[source]`nscalar = "removed"`n'
	Updates := [{ Section: "source", Key: "scalar", Delete: 1 },
		{ Section: "source.scalar", Key: "choice", Value: TOML_Bool(false) }]
	Built := _ConfigMigrateRenderRecords(Input, Updates, [])
	AssertEqual("ok", Built["status"], "a represented removal frees its former scalar namespace")
	Parsed := _ConfigMigrateParse(Built["content"], "owned namespace conversion")
	Assert(ConfigMigrateSameModel(Parsed, Map("source.scalar", Map("choice", TOML_Bool(false)))),
		"the resulting new table has the independently expected typed false choice")
	Input := '[source]`nchoice = "unchanged"`n'
	Conflicting := [{ Section: "target", Key: "inline", Value: Map("future", "root") },
		{ Section: "target.inline", Key: "child", Value: "nested" }]
	AssertThrows(() => _ConfigMigrateRenderRecords(Input, Conflicting, []),
		"two new leaves cannot redeclare an inline target namespace")
}
Test("config migrate records: target proof permits owned removal and refuses conflicting additions (config-migrate-record-target-deltas)",
	_CMR_TargetAdmissionAllowsOwnedRemoval)


_CMR_VariantJointRecordsCase() {
	Registry := _CMG_VariantRegistry()
	Inputs := [
		'[[layout]]`nergopti_plus = true`nergopti_base = false`nergopti_alt_gr = false`nemulated_layout = ""`n',
		'[layout]`nergopti_plus = true`n"ergopti_base" = false`nergopti_alt_gr = false`nemulated_layout = ""`n',
		'layout = { ergopti_plus = true, ergopti_base = false, ergopti_alt_gr = false, emulated_layout = "" }`n',
		'[layout]`nergopti_plus = true`nergopti_base = false`nergopti_alt_gr = false`n[layout.emulated_layout]`nfuture = "retained"`n',
		'[layout]`nergopti_plus = true`nergopti_base = false`nergopti_alt_gr = false`n[layout.ergopti_variant]`nfuture = "retained"`n'
	]
	for Source in Inputs {
		Plan := ConfigMigratePlan(Source, Registry, "ahk")
		AssertFalse(Plan.Has("candidate"), "non-addressable joint participants cannot produce a publication candidate")
		AssertTrue(Plan["outcome"] != "migrated")
		AssertContains(Plan["detail"], "refused", "the actual source/record owner explains its refusal")
	}
	Source := '; private header remains byte-exact`n[layout]`nergopti_plus = true # recognized old overlay`n'
		. 'ergopti_base = false`nergopti_alt_gr = false`nemulated_layout = ""`n'
		. '[private]`nopaque = "retain exactly" # unrelated owner`n'
	Plan := ConfigMigratePlan(Source, Registry, "ahk")
	AssertEqual("migrated", Plan["outcome"], Plan["detail"])
	AssertEqual("ergopti_plus", Plan["model"]["layout"]["ergopti_variant"])
	AssertFalse(Plan["model"]["layout"]["ergopti_base"].Value)
	AssertFalse(Plan["model"]["layout"]["ergopti_alt_gr"].Value)
	AssertEqual("", Plan["model"]["layout"]["emulated_layout"])
	AssertContains(Plan["candidate"], '; private header remains byte-exact`n')
	AssertContains(Plan["candidate"], '[private]`nopaque = "retain exactly" # unrelated owner`n')
	AssertFalse(InStr(Plan["candidate"], "ergopti_plus ="), "only the recognized historical source is consumed")
}
Test("config migrate records: every joint variant participant retains its semantic and physical owner (todo96-helper-variant)",
	_CMR_VariantJointRecordsCase)
