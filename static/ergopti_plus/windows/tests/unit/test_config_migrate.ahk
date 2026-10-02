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
		Plan := ConfigMigratePlan(_CMG_Read(CaseInfo["input"]), Registry, "ahk")
		AssertEqual(Spec["outcome"], Plan["outcome"], Name . ": outcome (" . Plan["detail"] . ")")
		if (Spec["outcome"] != "migrated") {
			AssertFalse(Plan.Has("candidate"), Name . ": a refused or current file has no candidate")
			continue
		}
		AssertEqual(Spec["from_version"], Plan["version"], Name . ": the version the migration starts from")
		AssertEqual(Spec["to_version"], Registry["current"], Name . ": the version it reaches")
		Migrated := _ConfigMigrateParse(Plan["candidate"], Name . " candidate")
		Expected := _CMG_Parse(CaseInfo["expected"])
		Assert(ConfigMigrateSameModel(Migrated, Expected), Name
			. ": the migrated file must read as expected.toml - got " . _CMG_ModelText(Migrated)
			. " expected " . _CMG_ModelText(Expected))
		Replay := ConfigMigrateApplySteps(_ConfigMigrateClone(Migrated), Registry, "ahk",
			Spec["from_version"])
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
			Result := ConfigMigrateRun(Path, Registry, _CMG_STAMP)
			AssertEqual(Spec["outcome"], Result["status"], Name . ": boot status (" . Result["detail"] . ")")
			Backup := ConfigMigrateBackupPath(Path, Registry["current"], _CMG_STAMP)
			if (Spec["outcome"] == "migrated") {
				AssertEqual(0, Result["read_only"], Name . ": a migrated file stays writable")
				AssertEqual(Backup, Result["backup"], Name . ": the backup sits next to the file")
				Assert(FSUtf8ExactMatches(Backup, Input), Name . ": the backup holds the exact old bytes")
				Assert(ConfigMigrateSameModel(_CMG_Parse(Path), _CMG_Parse(CaseInfo["expected"])),
					Name . ": the published file reads as expected.toml")
				Published := _CMG_Read(Path)
				Again := ConfigMigrateRun(Path, Registry, "20990101-000001")
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
	Snapshot := InStr(Body, "`nglobal _IniCache := ParseTomlFile(ConfigurationFile)")
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
