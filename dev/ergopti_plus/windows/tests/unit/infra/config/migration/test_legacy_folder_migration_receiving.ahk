; tests/unit/infra/config/migration/test_legacy_folder_migration_receiving.ahk

; ==============================================================================
; MODULE: Legacy Folder Migration Receiving Scenarios
; DESCRIPTION:
; The native receiving scenarios of the Windows migration recovery audit
; (docs/audits/platform-parity/2026-11-04-recovery/windows-migration). Each case
; runs the boot chain itself (migration, transition recovery, ReadPathsToml,
; boot folder selection) over a real configuration tree in the isolated
; receiving profile, whose LOCALAPPDATA, APPDATA and USERPROFILE the runner
; set before this process started:
; 1. a whole old tree moves byte for byte, and a quoted-key paths.toml follows;
; 2. a folder rename refused by an icacls deny keeps paths.toml naming the
;    folder that still holds the data, and the next boot completes;
; 3. a transition the old build left interrupted beside the old paths.toml is
;    recovered there before anything moves (WFM-004).
; Registered as interactive: they change real folders and ACLs, so only the
; receiving runner selects them.
; ==============================================================================

#Requires AutoHotkey v2.0

; One old configuration image, valid for the transition's schema admission.
_PWRM_ConfigText(Label) {
	return "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n[receiving]`nimage = " . Chr(34) . Label . Chr(34) . "`n"
}

; The folders the boot chain reads, derived from the isolated environment.
_PWRM_Layout() {
	ReceivingProfileRoot()
	Layout := Map()
	Layout["old_paths"] := EnvGet("APPDATA") . "\" . AppDirsMigrationWindowsLegacyPathsFileRelative()
	SplitPath(Layout["old_paths"], , &OldPathsDir)
	Layout["old_paths_dir"] := OldPathsDir
	Layout["old_config"] := EnvGet("USERPROFILE") . "\" . AppDirsMigrationWindowsLegacyConfigRelative()
	Layout["old_local"] := EnvGet("LOCALAPPDATA") . "\" . AppDirsMigrationWindowsLegacyLocalFolder()
	Layout["new_paths"] := AppFoldersPathsFile()
	Layout["new_config"] := RTrim(AppFoldersDefaultConfigDir(), "\")
	Layout["root"] := RTrim(AppFoldersRoot(), "\")
	return Layout
}

; Writes a file and its parent folders.
_PWRM_Put(Path, Text) {
	SplitPath(Path, , &Dir)
	DirCreate(Dir)
	FileAppend(Text, Path, "UTF-8-RAW")
}

; Every file below Dir by relative path, with its exact text.
_PWRM_Tree(Dir) {
	Files := Map()
	loop files, Dir . "\*", "FR"
		Files[SubStr(A_LoopFileFullPath, StrLen(Dir) + 2)] := FileRead(A_LoopFileFullPath, "UTF-8-RAW")
	return Files
}

; The boot chain of core/lifecycle/engine/boot.ahk for an installed driver, in its order.
; @returns {String} The configuration folder boot selects.
_PWRM_Boot() {
	Paths := AppFoldersPathsFile()
	LegacyFolderMigrationRun(Paths)
	ConfigTransitionRecoverAtBootOrThrow(Paths)
	Overrides := ReadPathsToml(Paths)
	return RTrim(ConfigTransitionSelectBootConfigDir(Overrides, AppFoldersDefaultConfigDir()), "\/")
}

; Seeds the old build's layout: paths.toml (quoted key, a comment, an
; unrelated key) naming the old configuration folder, and that folder.
_PWRM_SeedOldProfile(Layout, ConfigText) {
	Locator := "# Custom paths of the previous build.`n"
		. Chr(34) . "ConfigDirPath" . Chr(34) . " = " . Chr(34) . StrReplace(Layout["old_config"], "\", "/") . "/" . Chr(34) . "`n"
		. "UnrelatedKey = " . Chr(34) . "kept as written" . Chr(34) . "`n"
	_PWRM_Put(Layout["old_paths"], Locator)
	_PWRM_Put(Layout["old_config"] . "\config.toml", ConfigText)
	return Locator
}

; Removes what a case made in the profile, so the next case starts from an
; empty one; the deny ACEs are already gone.
_PWRM_ResetProfile() {
	Root := ReceivingProfileRoot()
	for Name in ["Local", "Roaming", "Home"] {
		Dir := Root . "\" . Name
		if DirExist(Dir)
			DirDelete(Dir, true)
		DirCreate(Dir)
	}
}

; 1. The whole old tree, with a non-ASCII profile name, a read-only file, logs
; and cache, reaches the new root byte for byte; the quoted-key paths.toml is
; rewritten with its previous text kept beside it; boot selects the moved
; folder; a second boot moves nothing.
_PWRM_RealTreeMoves() {
	Layout := _PWRM_Layout()
	try {
		_PWRM_SeedOldProfile(Layout, _PWRM_ConfigText("tree"))
		_PWRM_Put(Layout["old_config"] . "\hotstrings\personal.toml", "[brands]`nergo = " . Chr(34) . "Ergopti" . Chr(34) . "`n")
		_PWRM_Put(Layout["old_config"] . "\profils é\private.toml", "privé = 1`n")
		_PWRM_Put(Layout["old_config"] . "\readonly.txt", "READONLY")
		FileSetAttrib("+R", Layout["old_config"] . "\readonly.txt")
		_PWRM_Put(Layout["old_local"] . "\logs\old.log", "LOG")
		_PWRM_Put(Layout["old_local"] . "\cache\blob.bin", "CACHE")
		Before := _PWRM_Tree(Layout["old_config"])
		OldLocator := FileRead(Layout["old_paths"], "UTF-8-RAW")

		Selected := _PWRM_Boot()

		AssertEqual(Layout["new_config"], Selected, "boot selects the moved configuration folder")
		After := _PWRM_Tree(Layout["new_config"])
		AssertEqual(Before.Count, After.Count, "every configuration file arrived")
		for Relative, Text in Before
			AssertEqual(Text, After.Get(Relative, "<missing>"), "byte-identical after the move: " . Relative)
		AssertTrue(InStr(FileGetAttrib(Layout["new_config"] . "\readonly.txt"), "R"), "a read-only file keeps its attribute")
		AssertEqual("LOG", FileRead(Layout["root"] . "\logs\old.log", "UTF-8-RAW"), "the old logs merged into the root")
		AssertEqual("CACHE", FileRead(Layout["root"] . "\cache\blob.bin", "UTF-8-RAW"), "the old cache merged into the root")
		for Gone in [Layout["old_config"], Layout["old_local"], Layout["old_paths_dir"]]
			AssertFalse(FileExist(Gone), "the old folder is gone: " . Gone)
		Locator := FileRead(Layout["new_paths"], "UTF-8-RAW")
		AssertContains(Locator, Chr(34) . "ConfigDirPath" . Chr(34) . " = " . Chr(34) . StrReplace(Layout["new_config"], "\", "/") . "/" . Chr(34),
			"the quoted key now names the new folder (WFM-003)")
		AssertContains(Locator, "UnrelatedKey = " . Chr(34) . "kept as written" . Chr(34), "an unrelated key is kept as written")
		AssertEqual(OldLocator, FileRead(Layout["new_paths"] . AppDirsMigrationBackupSuffix(), "UTF-8-RAW"),
			"the previous paths.toml text is kept beside it")

		Again := LegacyFolderMigrationRun(Layout["new_paths"])
		AssertEqual(0, Again["moved"].Length + Again["backed_up"].Length + Again["kept"].Length, "a second boot moves nothing")
		AssertEqual("unchanged", Again["paths_file"], "a second boot leaves paths.toml alone")
	} finally {
		if FileExist(Layout["new_config"] . "\readonly.txt")
			FileSetAttrib("-R", Layout["new_config"] . "\readonly.txt")
		if FileExist(Layout["old_config"] . "\readonly.txt")
			FileSetAttrib("-R", Layout["old_config"] . "\readonly.txt")
		_PWRM_ResetProfile()
	}
}
Test("legacy folder migration receiving: a real old tree moves byte for byte and boot selects it (phys-w-receiving-migration-tree)",
	_PWRM_RealTreeMoves, true)

; 2. Windows refuses the folder rename: Everyone is denied DELETE on the old
; configuration folder and DELETE_CHILD on its parent. The data stays, paths.toml
; keeps naming the folder that holds it (WFM-001), boot selects that folder;
; once the ACEs are gone the next boot completes the move.
_PWRM_AclRefusedMoveKeepsTheLocator() {
	Layout := _PWRM_Layout()
	SplitPath(Layout["old_config"], , &OldConfigParent)
	Denied := []
	try {
		_PWRM_SeedOldProfile(Layout, _PWRM_ConfigText("acl"))
		ReceivingIcacls(Layout["old_config"], "/deny *S-1-1-0:(DE)")
		Denied.Push(Layout["old_config"])
		ReceivingIcacls(OldConfigParent, "/deny *S-1-1-0:(DC)")
		Denied.Push(OldConfigParent)

		Selected := _PWRM_Boot()

		AssertEqual(Layout["old_config"], Selected, "boot selects the folder that still holds the configuration")
		AssertEqual(_PWRM_ConfigText("acl"), FileRead(Selected . "\config.toml", "UTF-8-RAW"), "the configuration is intact")
		AssertFalse(FileExist(Layout["new_config"] . "\config.toml"), "nothing was published in the new folder")
		AssertContains(FileRead(Layout["new_paths"], "UTF-8-RAW"), StrReplace(Layout["old_config"], "\", "/") . "/",
			"paths.toml still names the old folder")
		Report := LegacyFolderMigrationRun(Layout["new_paths"])
		Kept := ""
		for Row in Report["kept"]
			if (Row["from"] = Layout["old_config"])
				Kept := Row
		AssertTrue(Kept is Map, "the refused rename is reported as kept")
		AssertEqual("rename_failed", Kept["reason"], "the native refusal is a rename failure")

		for Path in Denied
			ReceivingIcacls(Path, "/remove:d *S-1-1-0")
		Denied := []
		Selected := _PWRM_Boot()
		AssertEqual(Layout["new_config"], Selected, "with the ACEs gone the next boot completes")
		AssertEqual(_PWRM_ConfigText("acl"), FileRead(Selected . "\config.toml", "UTF-8-RAW"), "and the configuration followed")
	} finally {
		; A failed removal must surface: the profile cannot be deleted under a deny.
		for Path in Denied
			ReceivingIcacls(Path, "/remove:d *S-1-1-0")
		_PWRM_ResetProfile()
	}
}
Test("legacy folder migration receiving: a rename refused by an ACL keeps paths.toml naming the data (phys-w-receiving-migration-acl)",
	_PWRM_AclRefusedMoveKeepsTheLocator, true)

; The exit code of an old build that died inside its transition.
global PWRM_OLD_BUILD_DIED := 73

; Not a receiving case: the old build the journal scenario starts as a child
; runner in the same profile. It begins a real configuration transition on its
; own paths.toml with the production port, and its process dies at the crash
; point the scenario names, so nothing of it survives but the files.
_PWRM_OldBuildDiesInsideItsTransition() {
	global PWRM_OLD_BUILD_DIED
	CrashPoint := EnvGet("ERGOPTI_RECEIVING_OLD_BUILD_CRASH")
	if (CrashPoint == "")
		throw Error("Only the journal receiving scenario starts the old build.")
	Layout := _PWRM_Layout()
	Target := Layout["old_config"] . "\config.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Layout["old_paths"], Target])
	AssertTrue(Bundle is Object, "the old build owns its locator and target")
	Result := ConfigTransitionCommitOwned(Layout["old_paths"], [ConfigTransitionPresentTarget(Target, _PWRM_ConfigText("new"))],
		Bundle, ConfigTransitionProductionPort(), _PWRM_DieAt.Bind(CrashPoint))
	throw Error("The old build finished its transition (" . Result["status"] . "/" . Result["kind"] . ") instead of dying at "
		. CrashPoint . ".")
}
Test("legacy folder migration receiving helper: the old build dies inside its transition (phys-w-old-build-transition)",
	_PWRM_OldBuildDiesInsideItsTransition, true)

; The crash seam of the old build: its process ends at Point, after the
; effects before it, with no cleanup of any kind.
_PWRM_DieAt(Point, Reached) {
	global PWRM_OLD_BUILD_DIED
	if (Reached == Point)
		DllCall("Kernel32\ExitProcess", "UInt", PWRM_OLD_BUILD_DIED)
}

; Runs the old build in a child runner that inherits this isolated profile.
_PWRM_RunOldBuild(CrashPoint) {
	global PWRM_OLD_BUILD_DIED
	Scratch := ReceivingScratchDir("old-build")
	Saved := Map()
	for Name in ["ERGOPTI_RECEIVING_OLD_BUILD_CRASH", "ERGOPTI_AHK_RESULTS_FILE"]
		Saved[Name] := EnvGet(Name)
	try {
		EnvSet("ERGOPTI_RECEIVING_OLD_BUILD_CRASH", CrashPoint)
		; Its own receipt, so it never rewrites this runner's results file.
		EnvSet("ERGOPTI_AHK_RESULTS_FILE", Scratch . "\old-build.tap.txt")
		; /force: run_all.ahk is #SingleInstance Force, which would end this runner.
		ExitCode := RunWait('"' . A_AhkPath . '" /force /ErrorStdOut "' . A_ScriptDir . '\run_all.ahk" --interactive --only phys-w-old-build-transition',
			A_ScriptDir, "Hide")
	} finally {
		for Name, Value in Saved
			EnvSet(Name, Value)
	}
	Receipt := FileExist(Scratch . "\old-build.tap.txt") ? FileRead(Scratch . "\old-build.tap.txt", "UTF-8") : "<no receipt>"
	AssertEqual(PWRM_OLD_BUILD_DIED, ExitCode, "the old build died at " . CrashPoint . ": " . Receipt)
}

; 3. The old build died inside a real configuration transition on its own
; paths.toml, at CrashPoint. Boot must settle that journal beside the old
; locator before the migration moves anything, so no journal is left behind
; where the new boot no longer looks (WFM-004).
_PWRM_OldJournalIsSettledFirst(CrashPoint, ExpectedImage) {
	Layout := _PWRM_Layout()
	try {
		_PWRM_SeedOldProfile(Layout, _PWRM_ConfigText("old"))
		_PWRM_RunOldBuild(CrashPoint)
		Wal := ConfigTransitionWalPath(Layout["old_paths"])
		AssertTrue(FileExist(Wal), "positive control: the interrupted journal sits beside the old paths.toml")
		AssertEqual(_PWRM_ConfigText("new"), FileRead(Layout["old_config"] . "\config.toml", "UTF-8-RAW"),
			"positive control: the old build had already written its new image")

		Selected := _PWRM_Boot()

		AssertEqual(Layout["new_config"], Selected, "boot selects the moved configuration folder")
		AssertEqual(_PWRM_ConfigText(ExpectedImage), FileRead(Selected . "\config.toml", "UTF-8-RAW"),
			"the journal settled one whole image before the move")
		AssertFalse(FileExist(Wal), "no journal is left beside the old paths.toml")
		AssertFalse(FileExist(ConfigTransitionWalPath(Layout["new_paths"])), "none was carried beside the new one")
		AssertFalse(FileExist(Layout["old_paths_dir"]), "the old locator folder emptied and went away")
		Leftovers := []
		loop files, Layout["root"] . "\*", "FR"
			if InStr(A_LoopFileName, CONFIG_TRANSITION_ARTIFACT_TAG) || InStr(A_LoopFileName, CONFIG_TRANSITION_WAL_SUFFIX)
				Leftovers.Push(A_LoopFileFullPath)
		AssertEqual(0, Leftovers.Length, "no transition artifact moved with the folders")
	} finally _PWRM_ResetProfile()
}

for _PWRMCrash in [["target:new:1", "old"], ["phase:committed_new", "new"]]
	Test("legacy folder migration receiving: a transition interrupted at " . _PWRMCrash[1]
		. " beside the old paths.toml settles to the " . _PWRMCrash[2] . " image before the move (phys-w-receiving-migration-journal)",
		_PWRM_OldJournalIsSettledFirst.Bind(_PWRMCrash*), true)
