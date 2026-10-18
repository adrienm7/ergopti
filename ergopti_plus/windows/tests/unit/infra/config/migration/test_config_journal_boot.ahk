; tests/unit/infra/config/migration/test_config_journal_boot.ahk

; ==============================================================================
; MODULE: Config Journal Boot Authority
; DESCRIPTION:
; The genuine Boot constructor owns source admission: public snapshots and
; custom migrations cannot seed it, schema successors refuse before gateway
; effects, the first writer owns the schema stamp and registry observers
; cannot forge a generation.
; ==============================================================================

#Requires AutoHotkey v2.0





; These subjects exercise the genuine default Boot constructor. Custom Run
; algorithm seams never establish journal authority for production consumers.
_CMJ_CurrentSource() {
	return '[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion()
		. '`n[hotstrings]`ntrigger_char = "@"`n[future]`nkeep = { truth=false, number=1, text="1" } # unchanged`n'
}

_CMJ_BuiltGateway(Path, &Calls) {
	global ConfigurationFile
	PreviousPath := ConfigurationFile
	ConfigurationFile := Path
	Calls := { build: 0, write: 0 }
	Build() {
		Calls.build += 1
		return { updates: [{ Section: "hotstrings", Key: "trigger_char", Value: "!" }] }
	}
	Writer(Destination, Updates) {
		Calls.write += 1
		return 1
	}
	try return ConfigCommitBuilt(Path, "configuration journal subject", Build, Writer, (*) => 0)
	finally ConfigurationFile := PreviousPath
}

_CMJ_Cleanup(Dir, Path) {
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	for Cache in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache] {
		if Cache.Has(Path)
			Cache.Delete(Path)
	}
	Refusals := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Path)
	if Refusals.Has(Key)
		Refusals.Delete(Key)
	DirDelete(Dir, true)
}

_CMJ_GenuineCurrentConstructor() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Result := ConfigMigrateBoot(Path)
		AssertEqual("current", Result["status"])
		Snapshot := ConfigTomlReadSnapshot(Path)
		AssertEqual("@", Snapshot.Cache["hotstrings"]["trigger_char"])
		AssertTrue(Snapshot.Document["future"]["keep"]["truth"] is TOML_Bool)
		AssertEqual(false, Snapshot.Document["future"]["keep"]["truth"].Value)
		AssertTrue(FSUtf8ExactMatches(Path, Source), "genuine current boot changes no source bytes")
		Result["status"] := "invalid"
		Result["read_only"] := 1
		AssertTrue(_CMJ_BuiltGateway(Path, &Calls), "mutating a detached public result cannot revoke the actual private constructor")
		AssertEqual(1, Calls.build)
		AssertEqual(1, Calls.write, "this observes early admission, not a native durable writer receipt")
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally _CMJ_Cleanup(Dir, Path)
}
Test("config journal: genuine current constructor owns source admission independently of its public result", _CMJ_GenuineCurrentConstructor)

_CMJ_UnconstructedPublicSnapshotCannotSeed() {
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Fake := ConfigTomlDecodeSnapshot(Source)
		Fake.Present := true
		_ConfigTomlSnapshots[Path] := Fake
		_ParseTomlCache[Path] := Fake.Cache
		_TomlFileCache[Path] := Fake.Source
		AssertThrows(ConfigTomlReadSnapshot.Bind(Path), "public reader cache images cannot initialize the actual constructor")
		AssertFalse(_CMJ_BuiltGateway(Path, &Calls), "an unconstructed selected configuration has no permissive fallback")
		AssertEqual(0, Calls.build)
		AssertEqual(0, Calls.write)
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally _CMJ_Cleanup(Dir, Path)
}
Test("config journal: public snapshots cannot seed a selected configuration constructor", _CMJ_UnconstructedPublicSnapshotCannotSeed)

_CMJ_CustomRunCannotSeed() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Registry := ConfigMigrateLoadRegistry(ConfigMigrateRegistryPath())
		Result := ConfigMigrateRun(Path, Registry, _CMG_STAMP, (*) => 1, (*) => "")
		AssertEqual("current", Result["status"], "the algorithm seam still has its existing current-file contract")
		Result["read_only"] := 0
		AssertFalse(_CMJ_BuiltGateway(Path, &Calls), "an injected algorithm observation is not the actual Boot issuer")
		AssertEqual(0, Calls.build)
		AssertEqual(0, Calls.write)
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally _CMJ_Cleanup(Dir, Path)
}
Test("config journal: custom migration results cannot seed private Boot authority", _CMJ_CustomRunCannotSeed)

_CMJ_ExternalSuccessorRefuses(Metadata) {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Successor := Metadata . '`n[hotstrings]`ntrigger_char = "#"`n[future]`nkeep = [false, 1, "1"]`n'
	try {
		AssertTrue(FSWriteDurable(Path, _CMJ_CurrentSource()))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		AssertTrue(FSWriteDurable(Path, Successor))
		AssertFalse(_CMJ_BuiltGateway(Path, &Calls), "a fresh noncurrent successor refuses before candidate effects")
		AssertEqual(0, Calls.build)
		AssertEqual(0, Calls.write)
		AssertTrue(FSUtf8ExactMatches(Path, Successor), "all external successor bytes remain authoritative")
	} finally _CMJ_Cleanup(Dir, Path)
}
Test("config journal: native future-schema successor refuses before gateway effects",
	_CMJ_ExternalSuccessorRefuses.Bind('[_meta]`nschema_version = ' . (ConfigMigrateCurrentVersion() + 1)))
Test("config journal: native invalid-schema successor refuses before gateway effects",
	_CMJ_ExternalSuccessorRefuses.Bind('_meta = { schema_version="11" }'))
Test("config journal: native metadata-array successor refuses before gateway effects",
	_CMJ_ExternalSuccessorRefuses.Bind('[[_meta]]`nschema_version = ' . ConfigMigrateCurrentVersion()))

_CMJ_VersionRefusalReadsOnlyCapturedImage() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Original := '[_meta]`nschema_version = "invalid"`n[hotstrings]`ntrigger_char = "!"`n'
	try {
		AssertTrue(FSWriteDurable(Path, Original))
		AssertEqual("invalid", ConfigMigrateBoot(Path)["status"])
		CapturedRead := ConfigMigrateBoot(Path, "capture_read")
		AssertTrue(HasMethod(CapturedRead, "Call"))
		AssertTrue(CapturedRead.Call(Original, 1))
		AssertEqual("!", ConfigTomlReadSnapshot(Path).Cache["hotstrings"]["trigger_char"], "the exact captured initial image stays readable only")
		Reason := TOML_WriteRefusal(Path)
		Assert(Reason != "", "invalid boot owns its persistence refusal")
		Repair := _CMJ_CurrentSource()
		AssertTrue(FSWriteDurable(Path, Repair))
		AssertFalse(CapturedRead.Call(Repair, 1), "a readable external repair cannot borrow the initial source permission")
		Fresh := ConfigTomlReadSnapshot(Path)
		AssertEqual(Repair, Fresh.Source, "a fresh read observes actual repaired bytes without granting write readiness")
		AssertEqual("@", Fresh.Cache["hotstrings"]["trigger_char"])
		AssertEqual(Reason, TOML_WriteRefusal(Path), "read availability never clears the invalid boot persistence refusal")
		AssertFalse(_CMJ_BuiltGateway(Path, &Calls))
		AssertEqual(0, Calls.build)
		AssertEqual(0, Calls.write)
		AssertTrue(FSUtf8ExactMatches(Path, Repair))
	} finally _CMJ_Cleanup(Dir, Path)
}
Test("config journal: invalid boot reads only its genuine captured image", _CMJ_VersionRefusalReadsOnlyCapturedImage)

_CMJ_DefaultRegistryMutationRefuses() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	Registry := ConfigMigrateShippedRegistry(), Current := Registry["current"]
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Registry["current"] := Current + 1
		AssertFalse(_CMJ_BuiltGateway(Path, &Calls), "same default registry object with forged contents loses genuine source authority")
		AssertEqual(0, Calls.build)
		AssertEqual(0, Calls.write)
		AssertThrows(ConfigTomlReadSnapshot.Bind(Path))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally {
		Registry["current"] := Current
		_CMJ_Cleanup(Dir, Path)
	}
}
Test("config journal: in-place default registry mutation cannot forge a version", _CMJ_DefaultRegistryMutationRefuses)

_CMJ_PreparationRunsNoMigration() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Prepared := ConfigSchemaPrepareSource(Path)
		AssertEqual("current", Prepared["status"])
		AssertEqual(1, Prepared["read_only"])
		AssertEqual("@", ConfigTomlReadSnapshot(Path).Cache["hotstrings"]["trigger_char"])
		AssertFalse(_CMJ_BuiltGateway(Path, &Calls), "read-only preparation does not fabricate the missing initial write handoff")
		AssertEqual(0, Calls.build)
		AssertEqual(0, Calls.write)
		AssertTrue(FSUtf8ExactMatches(Path, Source))
		AssertThrows(ConfigSchemaPrepareSource.Bind(Path), "duplicate read-only initialization refuses")
		AssertEqual("current", ConfigMigrateBoot(Path)["status"], "the real default boot retains its later migration timing")
		AssertTrue(_CMJ_BuiltGateway(Path, &Calls))
		AssertEqual(1, Calls.build)
		AssertEqual(1, Calls.write)
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally _CMJ_Cleanup(Dir, Path)
}
Test("config journal: read-only preparation retains actual later default boot completion", _CMJ_PreparationRunsNoMigration)

_CMJ_FreshCandidateProof() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	try {
		AssertEqual("absent", ConfigMigrateBoot(Path)["status"])
		AssertFalse(FSStrictExists(Path), "an actual absent boot creates no source")
		Candidate := _CMJ_CurrentSource()
		Admission := ConfigMigrateBoot(Path, "capture_write", Candidate)
		AssertTrue(HasMethod(Admission, "Call"), "a complete current candidate receives a private source-bound check")
		AssertTrue(Admission.Call("", 0, Candidate))
		AssertFalse(Admission.Call("", 1, Candidate), "presence is native source identity")
		AssertFalse(Admission.Call("changed", 0, Candidate), "source bytes are independent of candidate validity")
		AssertFalse(Admission.Call("", 0, Candidate . "# changed`n"), "another candidate cannot borrow the same captured check")
		AssertFalse(ConfigMigrateBoot(Path, "capture_write", '[hotstrings]`ntrigger_char = "@"`n'), "unstamped candidate never gains current-schema proof")
		AssertFalse(FSStrictExists(Path), "checking is not a native target publication")
	} finally _CMJ_Cleanup(Dir, Path)
}
Test("config journal: genuine absent boot captures exact current candidate proof without publishing", _CMJ_FreshCandidateProof)


_CMJ_PrebootOwnedFreshTargetRequiresExactBundle() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	Candidate := _CMJ_CurrentSource()
	try {
		AssertFalse(ConfigSchemaCanPrepareWrite(Path))
		Clone := { kind: Bundle.kind, id: Bundle.id, tokens: Bundle.tokens,
			authorized: false, shutdown_claimed: false }
		AssertFalse(ConfigSchemaPrepareOwnedSource(Path, Clone), "a same-value public bundle cannot initialize the private source")
		AssertTrue(ConfigSchemaPrepareOwnedSource(Path, Bundle), "the actual native target issuer can construct a fresh wizard target")
		AssertFalse(FileExist(Path), "the chosen-target handoff neither migrates nor publishes")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		Admission := ConfigMigrateBoot(Path, "capture_write", Candidate)
		AssertTrue(HasMethod(Admission, "Call"))
		AssertTrue(Admission.Call("", 0, Candidate))
		WrongVersion := '[_meta]`nschema_version = ' . (ConfigMigrateCurrentVersion() + 1) . '`n'
		AssertFalse(HasMethod(ConfigMigrateBoot(Path, "capture_write", WrongVersion), "Call"))
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		AssertFalse(Admission.Call("", 0, Candidate), "releasing the genuine bundle withdraws preboot candidate permission")
		AssertFalse(ConfigSchemaCanPrepareWrite(Path))
		AssertEqual("absent", ConfigMigrateBoot(Path)["status"], "only the later genuine boot completes fresh READY")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
	} finally {
		_ConfigWriteTerminalRelease(Bundle)
		_CMJ_Cleanup(Dir, Path)
	}
}
Test("config journal: actual preboot chosen-target issuance binds the fresh source and candidate", _CMJ_PrebootOwnedFreshTargetRequiresExactBundle)

_CMJ_PrebootOwnedTargetPreservesCapturedRefusal() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Original := '[_meta]`nschema_version = "invalid"`n[future]`nkeep=false`n'
	Bundle := false
	try {
		AssertTrue(FSWriteDurable(Path, Original))
		AssertEqual("invalid", ConfigSchemaPrepareSource(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertFalse(ConfigSchemaPrepareOwnedSource(Path, Bundle), "an actual bundle cannot upgrade an invalid initial source")
		AssertTrue(FSUtf8ExactMatches(Path, Original))
		AssertTrue(FSWriteDurable(Path, _CMJ_CurrentSource()))
		AssertFalse(ConfigSchemaPrepareOwnedSource(Path, Bundle), "a repaired successor cannot inherit the captured refusal")
		AssertFalse(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(FSUtf8ExactMatches(Path, _CMJ_CurrentSource()))
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_CMJ_Cleanup(Dir, Path)
	}
}
Test("config journal: exact chosen-target ownership cannot erase the initial source refusal", _CMJ_PrebootOwnedTargetPreservesCapturedRefusal)


_CMJ_FreshNativeWriterStampsOnlyItsActualCandidate() {
	global ConfigurationFile
	OldPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Dir := A_Temp . "\ergopti-journal-first-write-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Dir), Path := Dir . "\config.toml"
	Updates := [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(true) }]
	try {
		ConfigurationFile := Path
		AssertFalse(FSStrictExists(Path))
		AssertEqual("absent", ConfigMigrateBoot(Path)["status"])
		AssertFalse(FSStrictExists(Path), "actual Boot absence is readonly")
		AssertTrue(TOML_ConfigBatchWrite(Path, []), "actual native first-use noop needs no fabricated schema candidate")
		AssertFalse(FSStrictExists(Path), "an empty native acknowledgement does not materialize a first-use file")
		AssertTrue(TOML_ConfigBatchWrite(Path, [{ Section: "layout", Key: "ergopti_base", Delete: 1 }]))
		AssertFalse(FSStrictExists(Path), "neutral native deletion preserves genuine first-use absence")
		AssertTrue(TOML_ConfigBatchWrite(Path, Updates), "actual default native writer creates its genuine first-use source")
		Actual := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual(ConfigMigrateCurrentVersion(), Actual["_meta"]["schema_version"])
		AssertTrue(Actual["layout"]["ergopti_base"].Value)
		AssertEqual(1, Updates.Length, "fresh schema authoring never mutates the caller batch")
		AssertEqual("layout", Updates[1].Section)
		AssertTrue(TOML_ConfigBatchWrite(Path, Updates), "the genuine stamped source admits an actual native noop")
	} finally {
		ConfigurationFile := IsSet(OldPath) ? OldPath : unset
		DirDelete(Dir, true)
	}
}
Test("config source journal: actual fresh native writer owns its first schema stamp", _CMJ_FreshNativeWriterStampsOnlyItsActualCandidate)

_CMJ_FreshWriterCannotOverrideExplicitInvalidMetadata() {
	global ConfigurationFile
	OldPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Dir := A_Temp . "\ergopti-journal-invalid-first-write-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Dir), Path := Dir . "\config.toml"
	try {
		ConfigurationFile := Path
		AssertEqual("absent", ConfigMigrateBoot(Path)["status"])
		AssertFalse(TOML_ConfigBatchWrite(Path, [{ Section: "_meta", Key: "schema_version", Value: "invalid" }]))
		AssertFalse(FSStrictExists(Path), "explicit invalid metadata cannot be overwritten by automatic first-use authoring")
	} finally {
		ConfigurationFile := IsSet(OldPath) ? OldPath : unset
		DirDelete(Dir, true)
	}
}
Test("config source journal: first-use authoring preserves strict explicit metadata refusal", _CMJ_FreshWriterCannotOverrideExplicitInvalidMetadata)

_CMJ_GenuinePublishedGenerationSurvivesMutationAndRetirement() {
	global ConfigurationFile, _ParseTomlCache
	OldPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Dir := A_Temp . "\ergopti-journal-reader-generation-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Dir), Path := Dir . "\config.toml"
	Source := '[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion() . '`n[layout]`nergopti_base = true`n'
	Changed := StrReplace(Source, "ergopti_base = true", "ergopti_base = false")
	try {
		ConfigurationFile := Path
		AssertTrue(FSWriteDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Cache := ParseConfigTomlFile(Path)
		Snapshot := ConfigTomlReadSnapshot(Path)
		AssertTrue(FSWriteDurable(Path, Changed))
		AssertTrue(ParseConfigTomlFile(Path) == Cache, "the actual native published cache retains its admitted source generation")
		AssertTrue(ConfigTomlReadSnapshot(Path) == Snapshot)
		AssertTrue(IniCacheGet(Cache, "layout", "ergopti_base"))
		_ParseTomlCache.Delete(Path)
		Fresh := ParseConfigTomlFile(Path)
		AssertFalse(Fresh == Cache, "actual cache retirement issues a genuinely reread native generation")
		AssertFalse(IniCacheGet(Fresh, "layout", "ergopti_base"))
		AssertTrue(FSDeleteStrict(Path))
		AssertTrue(ParseConfigTomlFile(Path) == Fresh, "physical deletion does not split the published boot generation")
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "retained cached reads never admit a deleted current native write source")
		_ParseTomlCache.Delete(Path)
		Absent := ConfigTomlReadSnapshot(Path)
		AssertFalse(Absent.Present, "genuine retirement observes actual native absence")
		AssertEqual(0, Absent.Rows.Length)
		AssertFalse(ConfigSchemaCanPrepareWrite(Path))
	} finally {
		ConfigurationFile := IsSet(OldPath) ? OldPath : unset
		DirDelete(Dir, true)
	}
}
Test("config source journal: native published source survives mutation/deletion until genuine cache retirement", _CMJ_GenuinePublishedGenerationSurvivesMutationAndRetirement)


; Native fixtures author their own metadata instead of forging journal READY.
; Read-only legacy corpus bytes remain exact; this helper never migrates them.
_CMJFixtureReadonly(Path) {
	if !ConfigMigrateBoot(Path, "known")
		ConfigSchemaPrepareSource(Path)
}

_CMJFixtureCurrentSource(Source) {
	HadBom := SubStr(Source, 1, 1) == Chr(0xFEFF)
	Body := HadBom ? SubStr(Source, 2) : Source
	; Root dotted metadata does not change the root scope of existing fixtures.
	return (HadBom ? Chr(0xFEFF) : "") . "_meta.schema_version = "
		. ConfigMigrateCurrentVersion() . "`n" . Body
}

; Pure final predicates must reject modifications of the SAME genuine producer
; object before executing a caller getter/method. No replacement owner is minted.
_CMJ_PurityNativeGateway(Path, State, ExistingOwner := 0) {
	Build() {
		State.build += 1
		return { updates: [{ Section: "hotstrings", Key: "trigger_char", Value: "!" }],
			publish: () => (State.publish += 1, State.runtime := "!") }
	}
	return ConfigCommitBuilt(Path, "genuine owner purity subject", Build, 0, (*) => 0, ExistingOwner)
}

_CMJ_RegistryObserver(Name, NestedArray := false) {
	global ConfigurationFile
	OldPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Stage := Path . ".stage"
	Source := _CMJ_CurrentSource(), Candidate := StrReplace(Source, 'trigger_char = "@"', 'trigger_char = "!"')
	Registry := ConfigMigrateShippedRegistry(), Owner := NestedArray ? Registry["steps"] : Registry
	Hits := { count: 0 }, Publication := { build: 0, publish: 0, runtime: "@" }
	try {
		ConfigurationFile := Path
		AssertTrue(FSWriteDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		NoopGuard := ConfigMigrateBoot(Path, "capture_noop")
		WriteGuard := ConfigMigrateBoot(Path, "capture_write", Candidate)
		AssertTrue(HasMethod(NoopGuard, "Call")), AssertTrue(HasMethod(WriteGuard, "Call"))
		AssertTrue(FSWriteDurable(Stage, Candidate))
		if Name == "__Enum" {
			Prototype := NestedArray ? Array.Prototype : Map.Prototype
			Owner.DefineProp(Name, { Call: (This, Arity) =>
				(Hits.count += 1, Prototype.__Enum.Call(This, Arity)) })
		} else {
			Original := Owner.%Name%
			Owner.DefineProp(Name, { Get: (*) => (Hits.count += 1, Original) })
		}
		Acknowledged := ConfigSchemaAcknowledgeNoop(Path, NoopGuard)
		AssertFalse(Acknowledged, "the genuine native final noop refuses an altered actual registry descriptor")
		AssertFalse(FSConfigAtomicMoveReplace(Stage, Path, &NativeError,
			() => WriteGuard.Call(Source, 1, Candidate)), "the native final replacement refuses before executing registry observers")
		AssertFalse(_CMJ_PurityNativeGateway(Path, Publication), "the actual builder/runtime publisher also refuses")
		AssertEqual(0, Hits.count, "no public registry getter or method executes, including inside native Critical")
		AssertEqual(0, Publication.build), AssertEqual(0, Publication.publish)
		AssertEqual("@", Publication.runtime, "refusal acknowledges no replacement RAM intent")
		AssertTrue(FSUtf8ExactMatches(Path, Source)), AssertTrue(FSUtf8ExactMatches(Stage, Candidate))
		Owner.DeleteProp(Name)
		AssertTrue(ConfigSchemaAcknowledgeNoop(Path, NoopGuard), "exact genuine descriptor repair restores the captured native noop")
		AssertTrue(FSConfigAtomicMoveReplace(Stage, Path, &NativeError, () => WriteGuard.Call(Source, 1, Candidate)),
			"the same captured native write guard admits exact original-owner repair")
		AssertTrue(FSUtf8ExactMatches(Path, Candidate))
		AssertTrue(_CMJ_PurityNativeGateway(Path, Publication), "actual default writer/runtime publisher remains usable after repair")
		AssertEqual(1, Publication.build), AssertEqual(1, Publication.publish), AssertEqual("!", Publication.runtime)
		AssertEqual(0, Hits.count, "repair uses original native data rather than executing the rejected observer")
	} finally {
		if Object.Prototype.HasOwnProp.Call(Owner, Name)
			Owner.DeleteProp(Name)
		ConfigurationFile := IsSet(OldPath) ? OldPath : unset
		_CMJ_Cleanup(Dir, Path)
	}
}
for Name in ["__Enum", "Count", "CaseSense"]
	Test("config journal: genuine registry observer refuses without invocation " . Name,
		_CMJ_RegistryObserver.Bind(Name))
for Name in ["__Enum", "Length"]
	Test("config journal: genuine nested registry array observer refuses without invocation " . Name,
		_CMJ_RegistryObserver.Bind(Name, true))

_CMJ_SnapshotObserver(Kind) {
	global ConfigurationFile
	OldPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	Hits := { count: 0 }, Owner := 0, Name := ""
	try {
		ConfigurationFile := Path
		AssertTrue(FSWriteDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		ParseConfigTomlFile(Path)
		Snapshot := ConfigTomlReadSnapshot(Path)
		switch Kind {
			case "snapshot-cache-getter":
				Owner := Snapshot, Name := "Cache"
				Descriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
				Original := Descriptor.Value
				Owner.DefineProp(Name, { Get: (*) => (Hits.count += 1, Original) })
			case "snapshot-own-count":
				Owner := Snapshot, Name := "OwnPropCount"
				Original := 0
				for Field in ObjOwnProps(Owner)
					Original += 1
				Owner.DefineProp(Name, { Call: (*) => (Hits.count += 1, Original) })
			case "cache-map-enumerator":
				Owner := Snapshot.Cache, Name := "__Enum"
				Owner.DefineProp(Name, { Call: (This, Arity) =>
					(Hits.count += 1, Map.Prototype.__Enum.Call(This, Arity)) })
			case "typed-bool-value":
				Owner := Snapshot.Document["future"]["keep"]["truth"], Name := "Value"
				AssertTrue(Owner is TOML_Bool, "the subject is the actual decoder's native Boolean sentinel")
				Descriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
				Original := Descriptor.Value
				Owner.DefineProp(Name, { Get: (*) => (Hits.count += 1, Original) })
		}
		; Only the genuine parser publishes the replacement generation.
		ParseConfigTomlFile(Path)
		Fresh := ConfigTomlReadSnapshot(Path)
		AssertEqual(0, Hits.count, "read generation comparison rejects genuine exported observers before any invocation")
		AssertFalse(Fresh == Snapshot, "only a genuine fresh native reread replaces the altered published generation")
		AssertEqual("@", Fresh.Cache["hotstrings"]["trigger_char"])
		AssertFalse(Fresh.Document["future"]["keep"]["truth"].Value)
		AssertEqual(1, Fresh.Document["future"]["keep"]["number"])
		AssertEqual("1", Fresh.Document["future"]["keep"]["text"])
		AssertTrue(FSUtf8ExactMatches(Path, Source), "observer refusal changes no actual source bytes")
		if Kind == "snapshot-cache-getter" || Kind == "typed-bool-value"
			Owner.DefineProp(Name, Descriptor)
		else
			Owner.DeleteProp(Name)
		AssertTrue(_ConfigTomlSnapshotEqual(Snapshot, Fresh), "exact data-descriptor repair retains the independent original snapshot image")
		AssertTrue(ConfigTomlReadSnapshot(Path) == Fresh,
			"repair does not resurrect a retired old cache; the genuinely reread generation remains published")
		AssertEqual(0, Hits.count)
	} finally {
		if Owner is Object && Name != "" {
			if Kind == "snapshot-cache-getter" || Kind == "typed-bool-value"
				Owner.DefineProp(Name, Descriptor)
			else if Object.Prototype.HasOwnProp.Call(Owner, Name)
				Owner.DeleteProp(Name)
		}
		ConfigurationFile := IsSet(OldPath) ? OldPath : unset
		_CMJ_Cleanup(Dir, Path)
	}
}
for Kind in ["snapshot-cache-getter", "snapshot-own-count", "cache-map-enumerator", "typed-bool-value"]
	Test("config journal: genuine published snapshot observer cannot forge a read generation " . Kind,
		_CMJ_SnapshotObserver.Bind(Kind))

_CMJ_GenuineDenseArrayMutation(SnapshotSubject := false) {
	global ConfigurationFile
	OldPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	ArrayOwner := 0
	try {
		ConfigurationFile := Path
		AssertTrue(FSWriteDurable(Path, Source)), AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		if SnapshotSubject {
			Snapshot := ConfigTomlReadSnapshot(Path)
			ArrayOwner := Snapshot.Rows
		} else {
			ArrayOwner := ConfigMigrateShippedRegistry()["steps"]
			Guard := ConfigMigrateBoot(Path, "capture_noop")
		}
		AssertTrue(ArrayOwner.Length > 0, "the genuine producer array must have an independently observed cell")
		Original := ArrayOwner[1], Length := ArrayOwner.Length
		ArrayOwner.Delete(1)
		AssertEqual(Length, ArrayOwner.Length, "the actual sparse mutation keeps the misleading original Length")
		AssertFalse(ArrayOwner.Has(1))
		if SnapshotSubject {
			Fresh := ConfigTomlReadSnapshot(Path)
			AssertFalse(Fresh == Snapshot, "native reread must retire an actual sparse published row array")
			AssertTrue(Fresh.Rows.Has(1)), AssertTrue(FSUtf8ExactMatches(Path, Source))
			ArrayOwner[1] := Original
			AssertTrue(_ConfigTomlSnapshotEqual(Snapshot, Fresh), "exact original cell repair retains the independently decoded source")
		} else {
			AssertFalse(ConfigSchemaAcknowledgeNoop(Path, Guard), "a skipped genuine registry cell cannot authorize native noop")
			AssertFalse(ConfigSchemaCanPrepareWrite(Path))
			AssertTrue(FSUtf8ExactMatches(Path, Source))
			ArrayOwner[1] := Original
			AssertTrue(ConfigSchemaAcknowledgeNoop(Path, Guard), "exact original cell repair restores genuine dense registry admission")
		}
	} finally {
		if ArrayOwner is Array && IsSet(Original)
			ArrayOwner[1] := Original
		ConfigurationFile := IsSet(OldPath) ? OldPath : unset
		_CMJ_Cleanup(Dir, Path)
	}
}
Test("config journal: genuine registry sparse cell cannot hide behind unchanged Length", _CMJ_GenuineDenseArrayMutation)
Test("config journal: genuine published sparse row array retires to actual native reread", _CMJ_GenuineDenseArrayMutation.Bind(true))

_CMJ_BootRegistryWithdrawal(When := "prepared") {
	global ConfigurationFile, _LOGGER_TEST_SINK, LOGGER_MIN_LEVEL
	OldPath := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Registry := ConfigMigrateShippedRegistry(), Step := Registry["steps"][1], Reason := Step["reason"]
	Source := '[_meta]`nschema_version = ' . Registry["unstamped"] . '`n[hotstrings]`ntrigger_char = "@"`n'
	NativeWrite := FSWriteDurable, PreviousSink := _LOGGER_TEST_SINK
	PreviousLevel := LOGGER_MIN_LEVEL
	Seen := { stage: 0, completed: 0, stage_paths: [], stage_content: "", source_unchanged: false }
	Observe(Line) {
		if When == "stage" && InStr(Line, "[INFO] [ConfigMigrate] Verified durable migration stage '")
				&& InStr(Line, "' for '" . Path . "' before native publication.") {
			Seen.stage += 1
			; Inspect the real default writer's verified stage, then withdraw its
			; original registry before the actual final native move can run.
			loop Files Path . "." . A_ScriptHwnd . "-migration-*.stage", "F" {
				Seen.stage_paths.Push(A_LoopFileFullPath)
				Seen.stage_content := FSReadUtf8Exact(A_LoopFileFullPath)
			}
			Seen.source_unchanged := FSUtf8ExactMatches(Path, Source)
			Step["reason"] := Reason . " withdrawn after actual durable stage"
		}
		if InStr(Line, "[SUCCESS] [ConfigMigrate] Migrated '") {
			Seen.completed += 1
			Step["reason"] := Reason . " withdrawn after genuine native publication"
		}
		if PreviousSink != 0
			PreviousSink.Call(Line)
	}
	try {
		ConfigurationFile := Path
		AssertTrue(NativeWrite.Call(Path, Source))
		AssertEqual("migrate", ConfigSchemaPrepareSource(Path)["status"], "the actual older native source owns this migration subject")
		AssertTrue(FSUtf8ExactMatches(Path, Source), "genuine readonly prepare performs no migration effects")
		switch When {
			case "prepared":
				Step["reason"] := Reason . " withdrawn after genuine prepare"
			case "stage", "completed":
				; Close the preceding observer cohort before enabling this one.
				_LoggerFlushRepeats(true)
				LOGGER_MIN_LEVEL := "INFO"
				_LoggerRefreshFastFlags()
				LoggerSetTestSink(Observe)
		}
		Result := ConfigMigrateBoot(Path)
		AssertEqual("failed", Result["status"], "lost original registry handoff is an actual failure, never a public success map")
		AssertEqual(1, Result["read_only"]), AssertFalse(ConfigSchemaCanPrepareWrite(Path))
		if When == "prepared" {
			AssertEqual("", Result["backup"], "registry withdrawal refuses before creating any backup")
			Count := 0
			loop Files Dir . "\*", "F"
				Count += 1
			AssertEqual(1, Count, "only the exact original native source exists")
			AssertTrue(FSUtf8ExactMatches(Path, Source))
		} else {
			AssertTrue(Result["backup"] != "", "the genuine admitted backup remains owned evidence")
			AssertTrue(FSUtf8ExactMatches(Result["backup"], Source), "the real backup preserves the complete original source")
			if When == "stage" {
				AssertEqual(1, Seen.stage, "withdrawal occurs after the real default durable staging write")
				AssertEqual(1, Seen.stage_paths.Length, "the observer must inspect exactly one real owned native stage")
				AssertTrue(Seen.source_unchanged, "the native source remains original when the verified stage is observed")
				AssertEqual(ConfigMigrateCurrentVersion(), TOML_ParseDocument(Seen.stage_content)["_meta"]["schema_version"],
					"the actual durable staged bytes contain the genuinely migrated current schema")
				AssertTrue(FSUtf8ExactMatches(Path, Source), "the actual native final rename refuses the withdrawn owner")
			} else {
				AssertEqual(1, Seen.completed, "the real default native migration completed before final handoff withdrawal")
				AssertEqual(ConfigMigrateCurrentVersion(), TOML_ParseDocument(FSReadUtf8Exact(Path))["_meta"]["schema_version"])
				AssertFalse(FSUtf8ExactMatches(Path, Source), "completed native publication is reported honestly, not described as rolled back")
			}
		}
		Step["reason"] := Reason
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "repair does not resurrect this session's refused initial boot")
	} finally {
		try {
			; Close this real observer cohort before restoring the exact previous sink.
			try _LoggerFlushRepeats(true)
			finally LoggerSetTestSink(PreviousSink)
		} finally {
			LOGGER_MIN_LEVEL := PreviousLevel
			_LoggerRefreshFastFlags()
			Step["reason"] := Reason
			ConfigurationFile := IsSet(OldPath) ? OldPath : unset
			_CMJ_Cleanup(Dir, Path)
		}
	}
}
for When in ["prepared", "stage", "completed"]
	Test("config journal: default native older-source migration retains registry custody " . When,
		_CMJ_BootRegistryWithdrawal.Bind(When))

; These source inputs are handwritten against the independently published v12
; registry. The real direct semantic writer must not borrow an earlier boot's
; current-schema decision after an external successor replaces its source.
_CMJ_PostBootDirectPublication(Metadata, Refuse) {
	global ConfigurationFile
	HadPath := IsSet(ConfigurationFile)
	PreviousPath := HadPath ? ConfigurationFile : ""
	Coordinator := _ConfigFullSaveCoordinator()
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Original := '[_meta]`nschema_version = 12`n[llm]`nmodel = "user-model"`n'
	Successor := Metadata . '`n[llm]`nmodel = "user-model"`n[future]`nkeep = [false, 1, "1"]`n'
	try {
		AssertEqual(12, ConfigMigrateCurrentVersion(), "the authored current source owns the actual v12 registry contract")
		ConfigurationFile := Path
		AssertTrue(FSWriteDurable(Path, Original))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		AssertEqual("", TOML_WriteRefusal(Path), "a genuine successful boot must not pre-seed the refusal being tested")
		AssertTrue(FSWriteDurable(Path, Successor))
		BeforeNoOp := FSReadUtf8Exact(Path)
		AssertEqual(Refuse ? 0 : 1, TOML_ConfigBatchWrite(Path, []),
			"direct unchanged acknowledgement must freshly admit the actual successor schema")
		AssertTrue(FSUtf8ExactMatches(Path, BeforeNoOp), "a no-op or refusal never replaces the authoritative successor bytes")
		AssertEqual(Refuse ? 0 : 1, TOML_ConfigBatchWrite(Path,
			[{ Section: "llm", Key: "model", Value: "changed-model" }]),
			"direct native publication must freshly admit the actual successor schema")
		if Refuse {
			AssertTrue(FSUtf8ExactMatches(Path, Successor), "future and invalid metadata survive refusal byte for byte")
			AssertTrue(FSWriteDurable(Path, Original))
			AssertTrue(TOML_ConfigBatchWrite(Path, []), "exact genuine current source repair restores unchanged admission")
			AssertTrue(TOML_ConfigBatchWrite(Path, [{ Section: "llm", Key: "model", Value: "changed-model" }]),
				"exact genuine current source repair restores actual native publication")
		}
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual(12, Document["_meta"]["schema_version"], "publication must retain the independent current stamp")
		AssertEqual("changed-model", Document["llm"]["model"])
		Stages := 0
		Loop Files, Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages, "these admitted/refused owners leave no unacknowledged stage")
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		ConfigurationFile := HadPath ? PreviousPath : unset
		_CMJ_Cleanup(Dir, Path)
	}
}
Test("config journal: post-boot direct current12 no-op and writer keep genuine admission",
	_CMJ_PostBootDirectPublication.Bind('[_meta]`nschema_version = 12', false))
Test("config journal: post-boot direct future99 no-op and writer refuse without borrowing boot",
	_CMJ_PostBootDirectPublication.Bind('[_meta]`nschema_version = 99', true))
Test("config journal: post-boot direct nonversion no-op and writer refuse without borrowing boot",
	_CMJ_PostBootDirectPublication.Bind('[_meta]`nschema_version = "not-a-version"', true))
Test("config journal: post-boot direct scalar metadata no-op and writer refuse without borrowing boot",
	_CMJ_PostBootDirectPublication.Bind('_meta = true', true))
