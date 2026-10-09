; tests/unit/test_config_migrate.ahk

; ==============================================================================
; MODULE: Config Migration Tests
; DESCRIPTION:
; Replays the shared corpus (_shared/tests/corpus/config_migrations) through
; the Windows interpreter twice: as a pure plan, which must read as every
; expected.toml and change nothing when replayed on its own output, and as the
; boot transaction on a temporary config.toml, which must back the file up
; byte for byte before migrating it and must never write a newer, invalid or
; unsupported file, refusing every later TOML write to it for the session.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include test_config_migrate_records.ahk
#Include test_common_autocorrection_migration.ahk

global _CMG_STAMP := "20990101-000000"
global _CMG_MIN_CASES := 10

_CMG_CorpusDir() {
	global _SharedDir
	return _SharedDir . "\tests\corpus\config_migrations"
}

_CMG_NewDir() {
	static Seq := 0
	Seq += 1
	Dir := A_Temp . "\ergopti_config_migrate_" . A_TickCount . "_" . Seq
	DirCreate(Dir)
	return Dir
}

; Exact bytes of a file the test needs, failing the test when it is unreadable.
_CMG_Read(Path) {
	Content := FSReadUtf8Exact(Path)
	Assert(Content is String, "unreadable test file: " . Path)
	return Content
}

_CMG_Parse(Path) {
	return _ConfigMigrateParse(_CMG_Read(Path), Path)
}

_CMG_Has(List, Value) {
	for Item in List {
		if (Item == Value)
			return true
	}
	return false
}

; One line per key, for a failure message that shows both models.
_CMG_ModelText(Model) {
	Text := ""
	for Section, Entries in Model {
		for Key, Value in Entries
			Text .= "[" . Section . "] " . Key . " = " . TOML_RenderValue(Value) . "; "
	}
	return Text
}

; Every case the corpus index lists, with its spec and registry.
_CMG_Cases() {
	Dir := _CMG_CorpusDir()
	Cases := []
	for Name in _CMG_Parse(Dir . "\cases.toml")["corpus"]["cases"] {
		CaseDir := Dir . "\" . Name
		Own := CaseDir . "\migrations.toml"
		Cases.Push(Map("name", Name,
			"spec", _CMG_Parse(CaseDir . "\case.toml")["case"],
			"registry", FileExist(Own) ? ConfigMigrateLoadRegistry(Own) : ConfigMigrateShippedRegistry(),
			"input", CaseDir . "\input.toml", "expected", CaseDir . "\expected.toml"))
	}
	return Cases
}

; Real macOS binding identities from the authoritative action registry and
; actual modifier matrix, not an expected fixture allowlist.
_CMG_MigrationContext() {
	global _SharedDir
	Catalogue := JsonParse(_CMG_Read(_SharedDir . "\modules\actions\modifier_chords.json"))
	Registry := _CMG_Parse(_SharedDir . "\modules\actions\actions.toml")
	Actions := Map()
	Actions.CaseSense := "On"
	for Family in ["sg", "ax"] {
		for Id in Registry[Family . "_order"]["items"] {
			Section := Family . "_actions." . Id
			if !Registry.Has(Section)
				continue
			Row := Registry[Section]
			if Row.Has("is_header") && (Row["is_header"] is TOML_Bool) && Row["is_header"].Value
				continue
			Claimed := StrSplit(Row["platform"], ",")
			for Platform in Claimed {
				if Trim(Platform) == "all" || Trim(Platform) == "hs"
					Actions[Id] := true
			}
		}
	}
	Modifiers := Catalogue["platforms"]["macos"]["modifiers"]
	Loop (2 ** Modifiers.Length) - 1 {
		Mask := A_Index, Prefix := ""
		for Index, Modifier in Modifiers {
			if Mod(Floor(Mask / (2 ** (Index - 1))), 2) == 1
				Prefix .= (Prefix == "" ? "" : "_") . Modifier["id"]
		}
		for Key in Catalogue["keys"]
			Actions[Prefix . "_" . Key["id"]] := true
	}
	return Map("modifier_chords", Catalogue, "assignable_actions", Actions)
}

_CMG_RingText() {
	Text := ""
	for _, Line in LoggerRingBufferSnapshot()
		Text .= Line . "`n"
	return Text
}





; ================================
; ================================
; ======= 1/ Corpus replay =======
; ================================
; ================================

_CMG_CorpusPlansMatchExpected() {
	global _CMG_MIN_CASES
	Replayed := 0
	for CaseInfo in _CMG_Cases() {
		Spec := CaseInfo["spec"]
		if !_CMG_Has(Spec["drivers"], "ahk")
			continue
		Replayed += 1
		Name := CaseInfo["name"]
		Registry := CaseInfo["registry"]
		Plan := ConfigMigratePlan(_CMG_Read(CaseInfo["input"]), Registry, "ahk", _CMG_MigrationContext())
		AssertEqual(Spec["outcome"], Plan["outcome"], Name . ": outcome (" . Plan["detail"] . ")")
		if (Spec["outcome"] != "migrated") {
			AssertFalse(Plan.Has("candidate"), Name . ": a refused or current file has no candidate")
			continue
		}
		AssertEqual(Spec["from_version"], Plan["version"], Name . ": the version the migration starts from")
		AssertEqual(Spec["to_version"], Registry["current"], Name . ": the version it reaches")
		if Spec.Has("preserve_source") && Spec["preserve_source"].Value {
			Input := _CMG_Read(CaseInfo["input"])
			WithoutStamp := RegExReplace(Plan["candidate"], "\[_meta\]\nschema_version = 2\n\n", "", &Removed, 1)
			AssertEqual(1, Removed, Name . ": only the stamp is added")
			AssertEqual(Input, WithoutStamp, Name . ": every unsupported source and destination byte survives")
		}
		Migrated := _ConfigMigrateParse(Plan["candidate"], Name . " candidate")
		Expected := _CMG_Parse(CaseInfo["expected"])
		Assert(ConfigMigrateSameModel(Migrated, Expected), Name
			. ": the migrated file must read as expected.toml - got " . _CMG_ModelText(Migrated)
			. " expected " . _CMG_ModelText(Expected))
		Replay := ConfigMigrateApplySteps(_ConfigMigrateClone(Migrated), Registry, "ahk",
			Spec["from_version"], _CMG_MigrationContext())
		Assert(ConfigMigrateSameModel(Replay, Migrated),
			Name . ": replaying the steps on their own output must change nothing")
	}
	Assert(Replayed >= _CMG_MIN_CASES, "expected at least " . _CMG_MIN_CASES
		. " corpus cases for ahk, replayed " . Replayed)
}
Test("config migrate: every corpus case plans the expected model and replays idempotently "
	. "(config-migrate-corpus)", _CMG_CorpusPlansMatchExpected)

_CMG_CopyOwnsNestedValues() {
	Dir := _CMG_CorpusDir() . "\op_copy_if_absent"
	Model := _CMG_Parse(Dir . "\input.toml")
	Expected := _CMG_Parse(Dir . "\expected.toml")
	Registry := ConfigMigrateLoadRegistry(Dir . "\migrations.toml")
	ConfigMigrateApplySteps(Model, Registry, "ahk", 1)
	Source := Model["source"]["records"]
	Copied := Model["destination"]["records"]
	Sibling := Model["sibling"]["records"]
	Assert(ConfigMigrateSameValue(Copied, Expected["destination"]["records"]), "copy matches the whole independent expected value")
	Assert(ConfigMigrateSameValue(Sibling, Expected["sibling"]["records"]), "sibling matches the independent expected value")
	Source[1]["palette"][1]["Key"] := "edited source"
	Source.Push(Map("future", "source only"))
	Assert(ConfigMigrateSameValue(Copied, Expected["destination"]["records"]), "source edits cannot change the copy")
	Assert(ConfigMigrateSameValue(Sibling, Expected["sibling"]["records"]), "source edits cannot change the sibling")
	Copied[1]["palette"][1]["key"] := "edited copy"
	Copied[1]["visible"].Value := true
	AssertEqual("lower", Source[1]["palette"][1]["key"], "copy edits cannot change the source's nested Map")
	AssertEqual(false, Source[1]["visible"].Value, "copy edits cannot change the source's typed Boolean")
	Assert(ConfigMigrateSameValue(Sibling, Expected["sibling"]["records"]), "copy edits cannot change another destination")
	Model["source"]["rows"][1][1] := 99
	Assert(ConfigMigrateSameValue(Model["destination"]["rows"], Expected["destination"]["rows"]),
		"nested copied arrays own every child")
}
Test("config migrate: conditional copies own nested values independently (config-migrate-copy-ownership)", _CMG_CopyOwnsNestedValues)

_CMG_CopyPreservesOccupiedNamespaceBytes() {
	Dir := _CMG_CorpusDir() . "\copy_preserves_occupied_namespaces"
	Input := _CMG_Read(Dir . "\input.toml")
	Plan := ConfigMigratePlan(Input, ConfigMigrateLoadRegistry(Dir . "\migrations.toml"), "ahk")
	AssertEqual("migrated", Plan["outcome"], Plan["detail"])
	AssertContains(Plan["candidate"], Input, "conditional copies preserve every source byte, including empty table headers")
}
Test("config migrate: conditional copies retain every occupied namespace byte (config-migrate-copy-bytes)",
	_CMG_CopyPreservesOccupiedNamespaceBytes)

_CMG_CopyPreservesInlineAncestor() {
	Input := _CMG_Read(_CMG_CorpusDir() . "\copy_preserves_occupied_namespaces\inline_ancestor.toml")
	Registry := ConfigMigrateValidateRegistry(_ConfigMigrateParse('[registry]`ncurrent_version = 2`nunstamped_version = 1`n'
		. '[steps.v1_to_v2]`nfrom = 1`nto = 2`ndrivers = ["ahk", "hs", "linux"]`n'
		. 'reason = "Contract: preserve occupied inline namespaces."`n'
		. 'ops = [{ op = "copy_if_absent", section = "source", key = "choice", to_section = "settings.inline.deep", to_key = "child" },'
		. '{ op = "copy_if_absent", section = "source", key = "choice", to_section = "settings", to_key = "inline" }]`n', "inline contract"))
	Plan := ConfigMigratePlan(Input, Registry, "ahk")
	AssertEqual("migrated", Plan["outcome"], Plan["detail"])
	Expected := _ConfigMigrateParse(Input, "independent inline choices")
	Expected["_meta"] := Map("schema_version", 2)
	Assert(ConfigMigrateSameModel(Plan["model"], Expected), "all source choices and the complete inline ancestor survive")
	for Line in StrSplit(Input, "`n") {
		if Line != ""
			AssertContains(Plan["candidate"], Line . "`n", "every original row keeps its exact bytes")
	}
}
Test("config migrate: conditional copies preserve occupied inline namespaces (config-migrate-copy-namespace)", _CMG_CopyPreservesInlineAncestor)

_CMG_ChordPreservesInlineAncestor() {
	Dir := _CMG_CorpusDir() . "\op_move_chord_scalar_ancestor"
	Input := _CMG_Read(Dir . "\inline_ancestor.toml")
	Plan := ConfigMigratePlan(Input, ConfigMigrateLoadRegistry(Dir . "\migrations.toml"), "ahk", _CMG_MigrationContext())
	AssertEqual("migrated", Plan["outcome"], Plan["detail"])
	WithoutStamp := RegExReplace(Plan["candidate"], "\[_meta\]\nschema_version = 2\n\n", "", &Removed, 1)
	AssertEqual(1, Removed)
	AssertEqual(Input, WithoutStamp, "both complete inline records and comments remain byte exact")
}
Test("config migrate: chord handoffs preserve inline ancestor ownership (config-migrate-chord-namespace)", _CMG_ChordPreservesInlineAncestor)

_CMG_ChordContextOwnsKnownActions() {
	Context := _CMG_MigrationContext(), Actions := Context["assignable_actions"]
	AssertTrue(Actions.Has("none"), "NONE comes from the real action catalogue")
	AssertTrue(Actions.Has("open_hotstrings_editor"), "the editor comes from the real action catalogue")
	AssertTrue(Actions.Has("cmd_ctrl_option_shift_comma"), "the actual modifier matrix is complete")
	AssertFalse(Actions.Has("future_action"), "unknown strings do not become recognized choices")
	AssertFalse(Actions.Has("alt_d"), "native aliases are not persisted action identities")
	AssertFalse(Actions.Has("_modifier_chords_placeholder"), "picker metadata is not an action")
}
Test("config migrate: chord context uses actual offered actions (config-migrate-chord-context)", _CMG_ChordContextOwnsKnownActions)

_CMG_ChordRequiresContext() {
	Dir := _CMG_CorpusDir() . "\op_move_chord_false"
	Input := _CMG_Read(Dir . "\input.toml")
	Registry := ConfigMigrateLoadRegistry(Dir . "\migrations.toml")
	Raised := false
	try ConfigMigratePlan(Input, Registry, "ahk")
	catch as Err {
		Raised := true
		AssertContains(Err.Message, "missing chord action context")
	}
	AssertTrue(Raised, "no legacy cleanup can be authorized without actual catalogue context")
	AssertEqual(Input, _CMG_Read(Dir . "\input.toml"), "the entire legacy source remains unchanged")
}
Test("config migrate: absent chord context refuses legacy cleanup (config-migrate-chord-context)", _CMG_ChordRequiresContext)

_CMG_StampOnlyPreservesExactRecords() {
	Dir := _CMG_CorpusDir() . "\copy_preserves_occupied_namespaces"
	Input := _CMG_Read(Dir . "\input.toml")
	Registry := ConfigMigrateLoadRegistry(Dir . "\migrations.toml")
	OldMeta := '[_meta] # metadata owner`nschema_version = 1.0 # retain this comment`nunknown = "keep"`n`n'
	NewMeta := StrReplace(OldMeta, "= 1.0", "= 2")
	Missing := '[_meta]`nunknown = "keep"`n`n'
	TightMeta := '[_meta]`nschema_version = 1.0#metadata-owner`nunknown = "keep"`n`n'
	Cases := [
		{ Source: TightMeta . Input, Expected: StrReplace(TightMeta, "1.0#", "2#") . Input },
		{ Source: OldMeta . Input, Expected: NewMeta . Input },
		{ Source: Missing . Input, Expected: '[_meta]`nschema_version = 2`nunknown = "keep"`n`n' . Input },
		{ Source: Chr(0xFEFF) . StrReplace(OldMeta . Input, "`n", "`r`n"),
			Expected: Chr(0xFEFF) . StrReplace(NewMeta . Input, "`n", "`r`n") },
		{ Source: RTrim(OldMeta . Input, "`n"), Expected: RTrim(NewMeta . Input, "`n") },
		{ Source: Input . "[_meta]", Expected: Input . "[_meta]`nschema_version = 2`n" }
	]
	for CaseInfo in Cases {
		Plan := ConfigMigratePlan(CaseInfo.Source, Registry, "ahk")
		AssertEqual("migrated", Plan["outcome"], Plan["detail"])
		AssertEqual(CaseInfo.Expected, Plan["candidate"], "only the metadata stamp may change")
	}
}
Test("config migrate: stamp-only plans preserve comments, BOM, EOL and final rows (config-migrate-stamp-bytes)",
	_CMG_StampOnlyPreservesExactRecords)

; The boot transaction on a real file: backup, publication or refusal.
_CMG_CorpusBootTransactions() {
	global _CMG_STAMP
	Ran := 0
	for CaseInfo in _CMG_Cases() {
		Spec := CaseInfo["spec"]
		if !_CMG_Has(Spec["drivers"], "ahk")
			continue
		Ran += 1
		Name := CaseInfo["name"]
		Registry := CaseInfo["registry"]
		Dir := _CMG_NewDir()
		try {
			Path := Dir . "\config.toml"
			Input := _CMG_Read(CaseInfo["input"])
			AssertTrue(FSWriteDurable(Path, Input), Name . ": the fixture config must be written")
			Result := ConfigMigrateRun(Path, Registry, _CMG_STAMP, 0, 0, _CMG_MigrationContext())
			AssertEqual(Spec["outcome"], Result["status"], Name . ": boot status (" . Result["detail"] . ")")
			Backup := ConfigMigrateBackupPath(Path, Registry["current"], _CMG_STAMP)
			if (Spec["outcome"] == "migrated") {
				AssertEqual(0, Result["read_only"], Name . ": a migrated file stays writable")
				AssertEqual(Backup, Result["backup"], Name . ": the backup sits next to the file")
				Assert(FSUtf8ExactMatches(Backup, Input), Name . ": the backup holds the exact old bytes")
				Assert(ConfigMigrateSameModel(_CMG_Parse(Path), _CMG_Parse(CaseInfo["expected"])),
					Name . ": the published file reads as expected.toml")
				Published := _CMG_Read(Path)
				Again := ConfigMigrateRun(Path, Registry, "20990101-000001", 0, 0, _CMG_MigrationContext())
				AssertEqual("current", Again["status"], Name . ": a second boot finds the file current")
				Assert(FSUtf8ExactMatches(Path, Published), Name . ": a current file is not rewritten")
				AssertFalse(FileExist(ConfigMigrateBackupPath(Path, Registry["current"], "20990101-000001")),
					Name . ": a current file is not backed up")
			} else if (Spec["outcome"] == "current") {
				AssertEqual(0, Result["read_only"])
				Assert(FSUtf8ExactMatches(Path, Input), Name . ": a current file is not rewritten")
				AssertFalse(FileExist(Backup), Name . ": a current file is not backed up")
			} else {
				AssertEqual(1, Result["read_only"], Name . ": the session becomes read-only")
				Assert(FSUtf8ExactMatches(Path, Input), Name . ": a refused file keeps its exact bytes")
				AssertFalse(FileExist(Backup), Name . ": a refused file is not backed up")
				Assert(TOML_WriteRefusal(Path) != "", Name . ": later writes are refused")
				AssertFalse(TOML_BatchWrite(Path, [{ Section: "gestures", Key: "enabled", Value: TOML_Bool(false) }]),
					Name . ": a later batch write must refuse")
				Assert(FSUtf8ExactMatches(Path, Input), Name . ": the refused write changed nothing")
			}
		} finally DirDelete(Dir, true)
	}
	Assert(Ran > 0, "the corpus must hold boot cases for ahk")
}
Test("config migrate: the boot transaction backs up, publishes or refuses every corpus case "
	. "(config-migrate-boot-corpus)", _CMG_CorpusBootTransactions)





; ==============================
; ==============================
; ======= 2/ Boot guards =======
; ==============================
; ==============================

_CMG_NewerFileIsLoggedAndReadOnly() {
	Dir := _CMG_NewDir()
	try {
		Path := Dir . "\config.toml"
		Newer := "[_meta]`nschema_version = 999`n`n[gestures]`nenabled = true`n"
		AssertTrue(FSWriteDurable(Path, Newer))
		Result := ConfigMigrateRun(Path)
		AssertEqual("newer", Result["status"])
		Ring := _CMG_RingText()
		Assert(InStr(Ring, "Config migration of '" . Path . "' refused (newer)", true),
			"the refusal must reach the log")
		Built := TOML_BuildUpdatedContent(Path, [{ Section: "gestures", Key: "enabled", Value: TOML_Bool(false) }])
		AssertEqual("error", Built["status"], "a transactional candidate over the refused file must refuse too")
		Assert(FSUtf8ExactMatches(Path, Newer), "the refused file keeps its exact bytes")
	} finally DirDelete(Dir, true)
}
Test("config migrate: a newer config logs its refusal and refuses candidate rendering "
	. "(config-migrate-newer-read-only)", _CMG_NewerFileIsLoggedAndReadOnly)

_CMG_AbsentFileIsLeftAlone() {
	Dir := _CMG_NewDir()
	try {
		Path := Dir . "\config.toml"
		Result := ConfigMigrateRun(Path)
		AssertEqual("absent", Result["status"])
		AssertEqual(0, Result["read_only"])
		AssertFalse(FileExist(Path), "no config is created")
		AssertEqual("", TOML_WriteRefusal(Path))
	} finally DirDelete(Dir, true)
}
Test("config migrate: an absent config.toml is left for onboarding (config-migrate-absent)",
	_CMG_AbsentFileIsLeftAlone)

; A migration step: v1 renames hotstrings.dynamic.datefr.
_CMG_OneStepRegistry() {
	return ConfigMigrateValidateRegistry(_ConfigMigrateParse(
		"[registry]`ncurrent_version = 2`nunstamped_version = 1`n`n"
		. '[steps.v1_to_v2]`nfrom = 1`nto = 2`ndrivers = ["ahk"]`nreason = "r"`n'
		. 'ops = [{ op = "rename", section = "hotstrings.dynamic", key = "datefr", to_key = "date_fr" }]`n',
		"the test registry"))
}

_CMG_FailedBackupAndConcurrentEditKeepTheFile() {
	global _CMG_STAMP
	Dir := _CMG_NewDir()
	try {
		Path := Dir . "\config.toml"
		Source := "[hotstrings.dynamic]`ndatefr = true`n"
		AssertTrue(FSWriteDurable(Path, Source))
		Result := ConfigMigrateRun(Path, _CMG_OneStepRegistry(), _CMG_STAMP, (*) => 0)
		AssertEqual("failed", Result["status"], "a refused backup fails the migration")
		AssertEqual(1, Result["read_only"])
		Assert(FSUtf8ExactMatches(Path, Source), "a refused backup leaves the file untouched")

		Other := Dir . "\edited.toml"
		AssertTrue(FSWriteDurable(Other, Source))
		Edited := Source . "`n[layout]`nedited = true`n"
		EditingBackup(BackupPath, Content) {
			FSWriteCreateDurable(BackupPath, Content)
			FSWriteDurable(Other, Edited)
			return 1
		}
		Result := ConfigMigrateRun(Other, _CMG_OneStepRegistry(), _CMG_STAMP, EditingBackup)
		AssertEqual("failed", Result["status"], "an edit made after the read fails the publication")
		Assert(FSUtf8ExactMatches(Other, Edited), "the edit made after the read survives")
	} finally DirDelete(Dir, true)
}
Test("config migrate: a refused backup or a concurrent edit leaves the file untouched "
	. "(config-migrate-backup-and-edit)", _CMG_FailedBackupAndConcurrentEditKeepTheFile)

_CMG_UnparsableFileIsRefused() {
	global _CMG_STAMP
	Dir := _CMG_NewDir()
	try {
		Path := Dir . "\config.toml"
		Broken := '[gestures]`nitems = [`n"a",`n'
		AssertTrue(FSWriteDurable(Path, Broken))
		Result := ConfigMigrateRun(Path, _CMG_OneStepRegistry(), _CMG_STAMP)
		AssertEqual("failed", Result["status"])
		AssertEqual(1, Result["read_only"])
		Assert(FSUtf8ExactMatches(Path, Broken), "the broken file keeps its exact bytes")
	} finally DirDelete(Dir, true)
}
Test("config migrate: a file the reader cannot fully parse is refused, never rewritten "
	. "(config-migrate-unparsable)", _CMG_UnparsableFileIsRefused)

; The shared registry-defect corpus: the loader accepts the control and rejects
; every defect the Lua engine and the JS reference reject too.
_CMG_RegistryLoaderRejectsDefects() {
	global _SharedDir
	Corpus := _SharedDir . "\tests\corpus\config_migration_registries"
	Index := _CMG_Parse(Corpus . "\cases.toml")["corpus"]
	Control := ConfigMigrateLoadRegistry(Corpus . "\" . Index["control"] . ".toml")
	AssertEqual(2, Control["current"], "the control registry must be accepted")
	Rejected := 0
	for Name in Index["rejected"] {
		Path := Corpus . "\" . Name . ".toml"
		_CMG_Parse(Path)
		AssertThrows(() => ConfigMigrateLoadRegistry(Path), Name . " must be rejected")
		Rejected += 1
	}
	Assert(Rejected >= 20, "expected at least 20 rejected registries, found " . Rejected)
	Shipped := ConfigMigrateShippedRegistry()
	Assert(Shipped["steps"].Length >= 1
		&& Shipped["steps"].Length == Shipped["current"] - Shipped["unstamped"],
		"the shipped registry is a gap-free chain with at least one step")
	AssertEqual(Shipped["current"], ConfigMigrateCurrentVersion())
}
Test("config migrate: the registry loader accepts the control and rejects every shared registry "
	. "defect (config-migrate-registry)", _CMG_RegistryLoaderRejectsDefects)





; ================================
; ================================
; ======= 3/ Driver wiring =======
; ================================
; ================================

; The full save stamps what the boot migration reads.
_CMG_FullSaveStampsTheCurrentVersion() {
	global _LLM_Menu
	Menu := _HSDeepCloneMap(_LLM_Menu)
	Menu["onboarding_seen"] := false
	Menu["app_profile_overrides"] := Map()
	Menu["user_profiles"] := []
	Stamps := []
	for Update in _ConfigCollectFullSaveUpdates(ManifestBuildFeaturesMap(), Menu) {
		if (Update.Section == "_meta" && Update.Key == "schema_version")
			Stamps.Push(Update.Value)
	}
	AssertEqual(1, Stamps.Length, "a full save stamps the version exactly once")
	AssertEqual(ConfigMigrateCurrentVersion(), Stamps[1],
		"a full save must stamp the registry's current version, not a literal")
}
Test("config migrate: the full save stamps the registry's current version "
	. "(config-migrate-full-save-stamp)", _CMG_FullSaveStampsTheCurrentVersion)

; The boot migrates before the first read of config.toml and before every
; producer that can save it; the entry script cannot run headless, so its
; order is read from the source.
_CMG_BootMigratesBeforeAnyReaderOrWriter() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Body := ""
	try Body := FileRead(WindowsDir . "\ErgoptiPlus.ahk", "UTF-8")
	Assert(Body != "", "ErgoptiPlus.ahk must be readable")
	Migrate := InStr(Body, "`nConfigMigrateBoot(ConfigurationFile)")
	Snapshot := InStr(Body, "`nglobal _IniCache := ParseConfigTomlFile(ConfigurationFile)")
	Apply := InStr(Body, "ApplyBootConfigToml(Features,")
	FullSave := InStr(Body, "_ConfigQueueFullSave(CONFIG_FULL_SAVE_BOOT_DELAY_MS")
	Assert(Migrate > 0 && Snapshot > 0 && Apply > 0 && FullSave > 0,
		"every boot marker must still exist in ErgoptiPlus.ahk")
	Assert(Migrate < Snapshot && Snapshot < Apply && Apply < FullSave,
		"the migration runs before the boot snapshot, ApplyBootConfigToml and the boot full save")
	StrReplace(Body, "ConfigMigrateBoot(", , , &Calls)
	AssertEqual(1, Calls, "the boot migrates exactly once")
}
Test("config migrate: the boot migrates config.toml before reading or saving it "
	. "(config-migrate-boot-order)", _CMG_BootMigratesBeforeAnyReaderOrWriter)

; A config.toml the session must not write keeps every full save disarmed.
_CMG_ReadOnlyConfigBlocksFullSaves() {
	global ConfigurationFile
	Dir := _CMG_NewDir()
	Previous := ConfigurationFile
	try {
		Path := Dir . "\config.toml"
		AssertTrue(FSWriteDurable(Path, "[_meta]`nschema_version = 999`n"))
		AssertEqual("newer", ConfigMigrateRun(Path)["status"])
		ConfigurationFile := Path
		AssertFalse(ConfigFullStateCanPersist(), "full saves stay disarmed for a read-only config")
	} finally {
		ConfigurationFile := Previous
		DirDelete(Dir, true)
	}
}
Test("config migrate: a read-only config.toml keeps every full save disarmed "
	. "(config-migrate-full-save-read-only)", _CMG_ReadOnlyConfigBlocksFullSaves)

; A file this build creates carries this build's version; an existing file
; keeps its own, since stamping it would skip the steps it still needs.
_CMG_OnlyANewFileIsStamped() {
	Dir := _CMG_NewDir()
	try {
		Path := Dir . "\config.toml"
		Updates := ConfigMigrateStampNewFile([{ Section: "script", Key: "locale", Value: "fr" }], Path)
		AssertEqual(2, Updates.Length, "a file about to be created gets the stamp")
		AssertEqual("_meta", Updates[2].Section)
		AssertEqual("schema_version", Updates[2].Key)
		AssertEqual(ConfigMigrateCurrentVersion(), Updates[2].Value)
		AssertTrue(FSWriteDurable(Path, '[script]`nlocale = "en"`n'))
		AssertEqual(1, ConfigMigrateStampNewFile([{ Section: "script", Key: "locale", Value: "fr" }], Path).Length,
			"an existing file is never stamped by a writer")
	} finally DirDelete(Dir, true)
	Body := _DriverFuncBody("_Onboarding_Commit")
	Assert(Body != "", "_Onboarding_Commit must be found")
	Assert(InStr(Body, "ConfigMigrateStampNewFile(updates, CandidateConfig)", true) > 0,
		"the wizard stamps the config.toml it creates")
}
Test("config migrate: only a config.toml this build creates is stamped by a writer "
	. "(config-migrate-stamp-new-file)", _CMG_OnlyANewFileIsStamped)


_CMG_SemanticSourceAndCandidateProofs() {
	Registry := _CMR_CopyRegistry()
	Duplicate := '[source]`nchoice="legitimate"`n[future]`na.b=1`na."b"=2`n'
	Before := _ConfigMigrateParse(Duplicate, "legacy dotted source projection")
	AssertEqual(1, Before["future"]["a.b"])
	AssertEqual(2, Before["future"]['a."b"'], "the flat model cannot observe the semantic duplicate")
	Plan := ConfigMigratePlan(Duplicate, Registry, "ahk")
	AssertEqual("failed", Plan["outcome"], "an unrelated malformed namespace cannot authorize publication")
	AssertFalse(Plan.Has("candidate"))
	AssertContains(Plan["detail"], "Duplicate TOML semantic assignment")

	Source := '[source]`nchoice="legitimate"`n[foo]`nbar.future=1`n'
	Registry := _CMR_TargetRegistry("copy_if_absent")
	Before := _ConfigMigrateParse(Source, "dotted parent before")
	After := ConfigMigrateApplySteps(_ConfigMigrateClone(Before), Registry, "ahk", 1)
	Updates := _ConfigMigrateWriterBatch(Before, After, &Drops)
	Built := _ConfigMigrateRenderRecords(Source, Updates, Drops)
	Assert(ConfigMigrateSameModel(After, _ConfigMigrateParse(Built["content"], "legacy dotted candidate projection")),
		"the old flat candidate readback cannot detect the redeclared dotted parent")
	AssertThrows(TOML_ParseDocument.Bind(Built["content"]), "the independent semantic namespace owner rejects the candidate")
	Plan := ConfigMigratePlan(Source, Registry, "ahk")
	AssertEqual("failed", Plan["outcome"], "candidate namespace validation precedes publication")
	AssertFalse(Plan.Has("candidate"))
	AssertContains(Plan["detail"], "Duplicate or closed TOML table namespace")
}
Test("config migrate: exact semantic source and candidate namespaces precede publication (config-migrate-dotted-document)",
	_CMG_SemanticSourceAndCandidateProofs)

_CMG_SemanticProofPreservesUnownedValues() {
	Foreign := 'future.a.b = 1`n"future.a.b" = "literal dot"`n'
		. '[[profiles]]`nshortcut.key="first"`n[[profiles]]`nshortcut.key="second"`n'
		. '[legacy]`ntext = ' . "O'Brien" . '`nshape = { rows=[{ flag=false, count=0, text="001" }] }`n'
	Source := Foreign . '[source]`nchoice="legitimate"`n'
	Plan := ConfigMigratePlan(Source, _CMR_CopyRegistry(), "ahk")
	AssertEqual("migrated", Plan["outcome"], Plan["detail"])
	; The metadata owner inserts its new table before the first physical header,
	; after root values. Pin the entire independent byte image, including that
	; owned insertion, rather than assuming all foreign records are contiguous.
	Expected := 'future.a.b = 1`n"future.a.b" = "literal dot"`n'
		. '[_meta]`nschema_version = 2`n`n'
		. '[[profiles]]`nshortcut.key="first"`n[[profiles]]`nshortcut.key="second"`n'
		. '[legacy]`ntext = ' . "O'Brien" . '`nshape = { rows=[{ flag=false, count=0, text="001" }] }`n'
		. '[source]`nchoice="legitimate"`n`n[destination]`nchoice = "legitimate"`n'
	Assert(StrCompare(Plan["candidate"], Expected, true) == 0,
		"all unknown source bytes and the exact owned metadata and destination insertions remain exact")
	Document := TOML_ParseDocument(Plan["candidate"])
	AssertEqual(1, Document["future"]["a"]["b"])
	AssertEqual("literal dot", Document["future.a.b"])
	AssertEqual(2, Document["profiles"].Length)
	AssertEqual("first", Document["profiles"][1]["shortcut"]["key"])
	AssertEqual("second", Document["profiles"][2]["shortcut"]["key"])
	AssertEqual("O'Brien", Document["legacy"]["text"], "an unowned legacy bare scalar retains its existing contract")
	AssertTrue(Document["legacy"]["shape"]["rows"][1]["flag"] is TOML_Bool)
	AssertTrue(Document["legacy"]["shape"]["rows"][1]["count"] is Integer)
	AssertTrue(Document["legacy"]["shape"]["rows"][1]["text"] is String)
	AssertEqual("legitimate", Document["destination"]["choice"])
}
Test("config migrate: semantic proof preserves valid unknown and legacy values (config-migrate-dotted-document-preservation)",
	_CMG_SemanticProofPreservesUnownedValues)

_CMG_CurrentSemanticRefusalOwnsBoot() {
	global _CMG_STAMP
	Directory := _CMG_NewDir(), Calls := { Backup: 0, Publish: 0 }
	Backup(Path, Bytes) {
		Calls.Backup += 1
		return 1
	}
	Publish(Path, Candidate, Source) {
		Calls.Publish += 1
		return ""
	}
	Path := Directory . "\config.toml"
	Source := '[_meta]`nschema_version=2`n[future]`na.b=1`na."b"=2`n'
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Legacy := _ConfigMigrateParse(Source, "current flat source projection")
		AssertEqual("current", ConfigMigrateClassify(Legacy, _CMR_CopyRegistry(), &Version),
			"a current stamp alone cannot prove semantic source ownership")
		Result := ConfigMigrateRun(Path, _CMR_CopyRegistry(), _CMG_STAMP, Backup, Publish)
		AssertEqual("failed", Result["status"])
		AssertEqual(1, Result["read_only"])
		AssertEqual(0, Calls.Backup, "callbacks only observe: no backup before source proof")
		AssertEqual(0, Calls.Publish, "the exact publication owner receives no unsafe candidate")
		AssertContains(Result["detail"], "Duplicate TOML semantic assignment")
		AssertTrue(FSUtf8ExactMatches(Path, Source))
		AssertFalse(TOML_BatchWrite(Path, [{ Section: "future", Key: "value", Value: 7 }]))
		AssertTrue(FSUtf8ExactMatches(Path, Source), "later writes retain the actual owner's refusal")
	} finally {
		if _TOML_WriteRefusals().Has(Path)
			_TOML_WriteRefusals().Delete(Path)
		DirDelete(Directory, true)
	}
}
Test("config migrate: current-version boot still requires the exact semantic source proof (config-migrate-dotted-document-boot)",
	_CMG_CurrentSemanticRefusalOwnsBoot)

_CMG_SemanticSnapshotKeepsStampAuthority(Literal, ExpectedStatus) {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Source := 'hotstrings.trigger_char = "@"`n[_meta]`nschema_version = ' . Literal . "`n"
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
		AssertTrue(FSWriteDurable(Path, Source))
		Result := ConfigMigrateRun(Path, 0, "semantic-snapshot", Backup, Publish)
		AssertEqual(ExpectedStatus, Result["status"])
		AssertEqual(0, Calls.Backup)
		AssertEqual(0, Calls.Publish)
		Cache := ParseConfigTomlFile(Path)
		AssertEqual("@", IniCacheGet(Cache, "hotstrings", "trigger_char"),
			"the reader consumes the admitted setting without inventing stamp authority")
		if ExpectedStatus == "current" {
			AssertEqual("", TOML_WriteRefusal(Path))
			AssertTrue(TOML_BatchWrite(Path, [{ Section: "hotstrings", Key: "trigger_char", Value: "@" }]))
		} else {
			AssertEqual(1, Result["read_only"])
			Reason := TOML_WriteRefusal(Path)
			Assert(Reason != "", "the actual migration owns the session write refusal")
			ParseConfigTomlFile(Path)
			AssertEqual(Reason, TOML_WriteRefusal(Path), "repeated semantic reads never clear invalid/newer stamp refusal")
			AssertFalse(TOML_BatchWrite(Path, [{ Section: "hotstrings", Key: "trigger_char", Value: "!" }]))
			Built := TOML_BuildUpdatedContent(Path, [{ Section: "hotstrings", Key: "trigger_char", Value: "!" }])
			AssertEqual("error", Built["status"])
		}
		AssertTrue(FSUtf8ExactMatches(Path, Source), "boot consumption must not rewrite any source bytes")
	} finally DirDelete(Dir, true)
}
_CMG_SemanticCurrentSourceConsumesRootSettings() {
	_CMG_SemanticSnapshotKeepsStampAuthority(String(ConfigMigrateCurrentVersion()), "current")
}
_CMG_SemanticInvalidStampsStayReadOnly() {
	_CMG_SemanticSnapshotKeepsStampAuthority('"10"', "invalid")
	_CMG_SemanticSnapshotKeepsStampAuthority("false", "invalid")
	_CMG_SemanticSnapshotKeepsStampAuthority("999", "newer")
}
Test("config migrate: a current semantic snapshot consumes root settings without rewriting (config-semantic-snapshot)",
	_CMG_SemanticCurrentSourceConsumesRootSettings)
Test("config migrate: semantic readers cannot clear invalid/newer stamp write refusal (config-semantic-snapshot)",
	_CMG_SemanticInvalidStampsStayReadOnly)


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
