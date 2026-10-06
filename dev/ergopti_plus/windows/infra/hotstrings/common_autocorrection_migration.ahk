; infra/hotstrings/common_autocorrection_migration.ahk

; ==============================================================================
; MODULE: Common Autocorrection Override Migration (Windows)
; DESCRIPTION:
; Consumes the shared leaf fan-out policy through the existing migration record
; owner and source-fenced atomic publisher, without changing schema metadata.
; ==============================================================================

; Plan independently versionless override operations, preserving foreign bytes.
HotstringsCommonOverridePlan(Source, Operations) {
	Before := _ConfigMigrateParse(Source, "hotstring overrides")
	Scan := _ConfigMigrateRecordScan(Source)
	_ConfigMigrateRecordValidateModel(Scan, Before)
	Document := TOML_ParseDocument(Source)
	Legacy := Document.Has("autocorrection") && (Document["autocorrection"] is Map)
		? Document["autocorrection"].Get("caps", 0) : 0
	if Legacy is Map {
		for Op in Operations
			if Op["op"] == "copy_if_absent" && Legacy.Has(Op["key"])
					&& !(Before.Has(Op["section"]) && Before[Op["section"]].Has(Op["key"]))
				throw Error("The legacy override leaf has no addressable physical record.")
	}
	for Index, Op in Operations
		_ConfigMigrateValidateOp(Op, "common override operation " . Index)
	Registry := Map("steps", [Map("from", 1, "drivers", Map("ahk", true), "ops", Operations)])
	_ConfigMigrateRecordValidateSources(Scan, Before, Registry, "ahk", 1)
	After := _ConfigMigrateClone(Before)
	for Op in Operations
		_ConfigMigrateApplyOp(After, Op)
	if ConfigMigrateSameModel(Before, After)
		return Map("outcome", "current", "candidate", Source)
	Updates := _ConfigMigrateWriterBatch(Before, After, &DropSections)
	Candidate := _ConfigMigrateRenderRecords(Source, Updates, DropSections, Scan)["content"]
	TOML_ParseDocument(Candidate)
	if !ConfigMigrateSameModel(After, _ConfigMigrateParse(Candidate, "migrated hotstring overrides"))
		throw Error("Common override migration does not read back as its candidate model.")
	return Map("outcome", "migrated", "candidate", Candidate)
}

; Unknown before the actual override owner initializes; explicit refusal gates
; only requested common-family publication and preserves unrelated native owners.
HotstringsCommonOverrideAdmitted() {
	global _HotstringsCommonOverrideAdmitted
	return IsSet(_HotstringsCommonOverrideAdmitted) ? _HotstringsCommonOverrideAdmitted : ""
}

HotstringsCommonRequireAdmission(CategoryName, Enabled) {
	Admission := HotstringsCommonOverrideAdmitted()
	Selected := (Enabled is TOML_Bool) ? Enabled.Value : (Enabled is Integer) && Enabled == true
	if StrLower(CategoryName) == "autocorrection" && Selected && (Admission is Integer) && Admission == false
		throw Error("Common autocorrection cannot register before override migration is acknowledged.")
}

; Actual production feature state determines whether a refused common source
; would be activated. Disabled families never block unrelated native modules.
HotstringsCommonAdmissionRefusal(FeatureMap) {
	Admission := HotstringsCommonOverrideAdmitted()
	if !(Admission is Integer) || Admission != false || !(FeatureMap is Map)
		return ""
	Hotstrings := FeatureMap.Get("hotstrings", 0)
	Common := (Hotstrings is Map) ? Hotstrings.Get("autocorrection", 0) : 0
	if !(Common is Map)
		return ""
	for Section in ["names", "abbreviations", "technical_terms"] {
		Node := Common.Get(Section, 0)
		Enabled := (Node is Map) ? Node.Get("enabled", false) : false
		Selected := (Enabled is TOML_Bool) ? Enabled.Value : (Enabled is Integer) && Enabled == true
		if Selected
			return "Common autocorrection override migration is unacknowledged; requested common families were not activated."
	}
	return ""
}

; Conservative physical ownership proof permits old unrelated passthrough bytes
; to retain their established native save policy, with common activation closed.
_HotstringsCommonLegacyPossible(Source) {
	Scan := _ConfigMigrateRecordScan(Source)
	Target := ["autocorrection", "caps"]
	for Header in Scan.Headers {
		if !(Header.Parts is Array) || _ConfigMigrateRecordPartsUnder(Header.Parts, Target)
			return true
	}
	for Record in Scan.Records {
		Parts := (Record.Header is Object) ? Record.Header.Parts : []
		if !(Parts is Array) || !(Record.KeyParts is Array)
			return true
		Path := Parts.Clone()
		for Part in Record.KeyParts
			Path.Push(Part)
		if _ConfigMigrateRecordPartsUnder(Path, Target) || _ConfigMigrateRecordPartsUnder(Target, Path)
			return true
	}
	return false
}

; Missing files stay absent; publication failures cannot initialize live overrides.
HotstringsCommonOverrideMigrate(Path, PublishFn := 0) {
	global _SharedDir, _HotstringsCommonOverrideAdmitted
	_HotstringsCommonOverrideAdmitted := false
	if !FileExist(Path) {
		_HotstringsCommonOverrideAdmitted := true
		return true
	}
	if TOML_WriteRefusal(Path) != ""
		return false
	Owner := _ConfigWriteLeaseTryAcquire(Path, "common-autocorrection-overrides")
	if !(Owner is Object)
		return false
	try {
		Source := FSReadUtf8Exact(Path)
		if !(Source is String)
			throw Error("Hotstring override source is not readable exact UTF-8.")
		try {
			_ConfigMigrateParse(Source, "hotstring overrides")
			Document := TOML_ParseDocument(Source)
		} catch as DecodeError {
			if !_HotstringsCommonLegacyPossible(Source)
				return true
			throw DecodeError
		}
		if !Document.Has("autocorrection") || !(Document["autocorrection"] is Map)
				|| !Document["autocorrection"].Has("caps") {
			_HotstringsCommonOverrideAdmitted := true
			return true
		}
		Policy := _ConfigMigrateParse(FSReadStrict(_SharedDir
			. "\data\hotstrings\common_autocorrection_migration.toml"), "common override policy")
		if !Policy.Has("migration") || !Policy["migration"].Has("ops")
			throw Error("Common hotstring override migration policy is invalid.")
		Plan := HotstringsCommonOverridePlan(Source, Policy["migration"]["ops"])
		if Plan["outcome"] == "current" {
			_HotstringsCommonOverrideAdmitted := true
			return true
		}
		Refusal := HasMethod(PublishFn, "Call") ? PublishFn.Call(Path, Plan["candidate"], Source)
			: _ConfigMigratePublish(Path, Plan["candidate"], Source)
		if Refusal != ""
			throw Error("Common hotstring override migration publication refused: " . Refusal)
		_HotstringsCommonOverrideAdmitted := true
		return true
	} catch as Err {
		TOML_RefuseWrites(Path, Err.Message)
		try LoggerError("HotstringsConfig", "Common autocorrection override migration refused: {1}", Err.Message)
		return false
	} finally {
		_ConfigWriteLeaseRelease(Owner)
	}
}
