; tests/unit/infra/config/migration/test_legacy_folder_migration.ahk

; ==============================================================================
; MODULE: Legacy Folder Migration Vectors Replay (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/paths/legacy_folder_migration_vectors.json
; through infra/legacy_folder_migration.ahk. macOS and Linux replay the same
; file through _shared/lua/legacy_folder_migration.lua, so the three drivers
; move, back up and refuse the same entries and rewrite paths.toml the same
; way. The moves run on a private tree under A_Temp, never on a user folder.
; ==============================================================================

#Requires AutoHotkey v2.0

_LFM_Corpus() {
	static Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\paths\legacy_folder_migration_vectors.json", "UTF-8"))
	return Corpus
}

; The vector path "/h/a/b" under the private tree.
_LFM_Local(Root, Path) {
	return Root . StrReplace(RTrim(Path, "/"), "/", "\")
}

; Every file and folder below Root, spelled as the vectors spell them.
; A_LoopFilePath keeps Root as spelled; A_LoopFileFullPath expands a short
; 8.3 A_Temp (C:\Users\RUNNER~1 on CI), which shifted the prefix cut.
_LFM_Snapshot(Root, &Files, &Dirs) {
	Files := Map(), Dirs := Map()
	loop files, Root . "\*", "FDR" {
		Path := StrReplace(SubStr(A_LoopFilePath, StrLen(Root) + 1), "\", "/")
		if InStr(A_LoopFileAttrib, "D")
			Dirs[Path . "/"] := true
		else
			Files[Path] := true
	}
}

_LFM_ReplayMove(Row, Index) {
	Root := A_Temp . "\ergopti_test_legacy_folder_migration_" . A_TickCount . "_" . Index
	DirCreate(Root)
	try {
		for Path in Row["tree"] {
			LocalPath := _LFM_Local(Root, Path)
			if (SubStr(Path, -1) == "/") {
				DirCreate(LocalPath)
			} else {
				SplitPath(LocalPath, , &Parent)
				DirCreate(Parent)
				FileAppend("", LocalPath)
			}
		}
		Report := Map("moved", [], "backed_up", [], "kept", [], "removed", [])
		for Step in Row["plan"] {
			if Step.Has("from") {
				LegacyFolderMoveEntry(_LFM_Local(Root, Step["from"]), _LFM_Local(Root, Step["to"]),
					_LFM_Local(Root, Step["backup"]), Report)
				continue
			}
			if !Step.Has("entries") {
				LegacyFolderMergeEntries(_LFM_Local(Root, Step["from_dir"]), _LFM_Local(Root, Step["to_dir"]),
					_LFM_Local(Root, Step["backup_dir"]), Report)
				continue
			}
			; The macOS-only named merge: the Windows plan never names entries,
			; so the replay moves them one by one, as the Lua core does.
			for Name in Step["entries"]
				LegacyFolderMoveEntry(_LFM_Local(Root, Step["from_dir"] . "/" . Name),
					_LFM_Local(Root, Step["to_dir"] . "/" . Name), _LFM_Local(Root, Step["backup_dir"] . "/" . Name), Report)
			LegacyFolderRemoveIfEmpty(_LFM_Local(Root, Step["from_dir"]), Report)
		}
		_LFM_Snapshot(Root, &Files, &Dirs)
		Expected := Map()
		for Path in Row["after"] {
			Expected[Path] := true
			if (SubStr(Path, -1) == "/")
				Assert(Dirs.Has(Path), Row["name"] . ": folder " . Path . " exists")
			else
				Assert(Files.Has(Path), Row["name"] . ": file " . Path . " exists")
		}
		; A real tree keeps the parent folders the in-memory one leaves implicit,
		; so files are compared both ways and folders only one way.
		for Path in Files
			Assert(Expected.Has(Path), Row["name"] . ": no stray file " . Path)
		for Step in Row["plan"] {
			Old := (Step.Has("from") ? Step["from"] : Step["from_dir"]) . "/"
			AssertEqual(Expected.Has(Old) ? 1 : 0, Dirs.Has(Old) ? 1 : 0, Row["name"] . ": the old folder " . Old)
		}
		AssertEqual(Row["moved"], Report["moved"].Length, Row["name"] . ": moved")
		AssertEqual(Row["backed_up"], Report["backed_up"].Length, Row["name"] . ": backed up")
		AssertEqual(Row["removed"], Report["removed"].Length, Row["name"] . ": removed")
		Reasons := ""
		for Kept in Report["kept"]
			Reasons .= (Reasons == "" ? "" : ",") . Kept["reason"]
		Want := ""
		for Reason in Row["kept_reasons"]
			Want .= (Want == "" ? "" : ",") . Reason
		AssertEqual(Want, Reasons, Row["name"] . ": kept reasons")
	} finally {
		DirDelete(Root, true)
	}
}

_LFM_EveryMoveVectorReplays() {
	Corpus := _LFM_Corpus()
	AssertEqual(9, Corpus["moves"].Length, "complete move vectors, or this replay proves nothing")
	for Index, Row in Corpus["moves"]
		_LFM_ReplayMove(Row, Index)
}
Test("legacy folder migration: every shared move vector replays on a private tree (legacy-folder-migration-moves)",
	_LFM_EveryMoveVectorReplays)

_LFM_EveryPathsTextVectorReplays() {
	Corpus := _LFM_Corpus()
	AssertEqual(4, Corpus["paths_text"].Length, "complete paths.toml vectors")
	for Row in Corpus["paths_text"] {
		Rewrites := []
		for Rule in Row["rewrites"]
			Rewrites.Push(Map("key", Rule["key"], "old", Rule["old"], "new", Rule["new"]))
		Expected := Row["expected"] == JSON_NULL ? "" : Row["expected"]
		AssertEqual(Expected, LegacyFolderRewritePathsText(Row["text"], Rewrites), Row["name"])
	}
}
Test("legacy folder migration: every shared paths.toml vector replays (legacy-folder-migration-paths)",
	_LFM_EveryPathsTextVectorReplays)

_LFM_RewriteKeepsTheBackup() {
	Root := A_Temp . "\ergopti_test_legacy_folder_paths_" . A_TickCount
	DirCreate(Root)
	try {
		Path := Root . "\paths.toml"
		FileAppend('ConfigDirPath = "C:/old/"`n', Path, "UTF-8-RAW")
		Rewrites := [Map("key", "ConfigDirPath", "old", ["C:/old"], "new", "C:/new")]
		AssertEqual("rewritten", LegacyFolderRewritePathsFile(Path, Rewrites))
		AssertEqual('ConfigDirPath = "C:/old/"`n', FileRead(Path . AppDirsMigrationBackupSuffix(), "UTF-8"),
			"the backup holds the previous text")
		AssertEqual('ConfigDirPath = "C:/new/"`n', FileRead(Path, "UTF-8"), "the file names the new folder")
		FileDelete(Path)
		FileAppend('ConfigDirPath = "C:/old/"`n', Path, "UTF-8-RAW")
		AssertEqual("backup_refused", LegacyFolderRewritePathsFile(Path, Rewrites), "an existing backup is never replaced")
		AssertEqual('ConfigDirPath = "C:/old/"`n', FileRead(Path, "UTF-8"), "nothing rewritten without a backup")
		AssertEqual("absent", LegacyFolderRewritePathsFile(Root . "\none.toml", Rewrites))
	} finally {
		DirDelete(Root, true)
	}
}
Test("legacy folder migration: paths.toml is backed up before it is rewritten (legacy-folder-migration-backup)",
	_LFM_RewriteKeepsTheBackup)

; A folder the user cannot list is a refusal, not an empty folder: loop files
; yielded nothing over it, so its entries were silently left behind. The deny
; ACE (Everyone, list folder) is removed again before the tree is deleted.
_LFM_UnlistableFolderIsReported() {
	Root := A_Temp . "\ergopti_test_legacy_folder_list_" . A_TickCount
	DirCreate(Root . "\old")
	DirCreate(Root . "\new")
	FileAppend("LEGACY", Root . "\old\storage.json")
	try {
		AssertEqual(0, RunWait('icacls "' . Root . '\old" /deny *S-1-1-0:(RD)', , "Hide"), "the deny ACE is set")
		Report := Map("moved", [], "backed_up", [], "kept", [], "removed", [])
		LegacyFolderMergeEntries(Root . "\old", Root . "\new", Root . "\new\bak\old", Report)
		AssertEqual(1, Report["kept"].Length, "the refusal is reported")
		AssertEqual("list_failed", Report["kept"][1]["reason"], "not read as an empty folder")
		AssertEqual(0, Report["moved"].Length + Report["removed"].Length, "nothing moved or removed")
	} finally {
		RunWait('icacls "' . Root . '\old" /remove:d *S-1-1-0', , "Hide")
		DirDelete(Root, true)
	}
}
Test("legacy folder migration: an unlistable folder is reported, not read as empty (legacy-folder-migration-list-refused)",
	_LFM_UnlistableFolderIsReported)

; Boot runs the migration before anything reads paths.toml, and never under
; the startup smoke, which must not touch the real user folders.
_LFM_BootRunsItFirstAndNeverUnderTheSmoke() {
	Source := _DriverFileSource("boot.ahk")
	RunAt := InStr(Source, "LegacyFolderMigrationRun(_PathsFile)")
	Assert(RunAt > 0, "boot runs the migration")
	Assert(RunAt < InStr(Source, "ConfigTransitionRecoverAtBootOrThrow(_PathsFile)"), "before the transition recovery")
	Assert(RunAt < InStr(Source, "ReadPathsToml(_PathsFile)"), "before paths.toml is read")
	Guard := SubStr(Source, 1, RunAt - 1)
	Assert(RegExMatch(Guard, 'if \(_DriverStartupSmokeDir == ""\)\s*$'), "guarded by the startup smoke check")
}
Test("legacy folder migration: boot runs it before paths.toml, never under the smoke (legacy-folder-migration-boot-order)",
	_LFM_BootRunsItFirstAndNeverUnderTheSmoke)

; The whole Windows plan on a private profile: the three base variables point
; at a temp tree for the call only, so the real AppData is never read or moved.
; Both old managed Ollama folders land in the root's ollama folder, the second
; one in the backup, and every old folder is gone afterwards.
_LFM_WindowsPlanMovesEveryOldFolderOnAPrivateProfile() {
	Profile := A_Temp . "\ergopti_test_legacy_folder_plan_" . A_TickCount
	Saved := Map()
	for Name in ["LOCALAPPDATA", "APPDATA", "USERPROFILE"]
		Saved[Name] := EnvGet(Name)
	try {
		Local_ := Profile . "\Local", Roaming := Profile . "\Roaming", Home := Profile . "\Home"
		for Path in [Local_ . "\" . AppDirsMigrationWindowsLegacyLocalFolder() . "\logs",
			Roaming . "\" . StrReplace(AppDirsMigrationWindowsLegacyPathsFileRelative(), "\paths.toml", ""),
			Home . "\" . AppDirsMigrationWindowsLegacyConfigRelative()]
			DirCreate(Path)
		FileAppend("a", Local_ . "\" . AppDirsMigrationWindowsLegacyLocalFolder() . "\logs\old.log")
		FileAppend('ConfigDirPath = ""`n', Roaming . "\" . AppDirsMigrationWindowsLegacyPathsFileRelative())
		FileAppend("x", Home . "\" . AppDirsMigrationWindowsLegacyConfigRelative() . "\config.toml")
		Ollama := AppDirsMigrationWindowsLegacyOllamaFolders()
		AssertEqual(2, Ollama.Length, "the first build's folder and the protected sibling")
		for Index, Name in Ollama {
			DirCreate(Local_ . "\" . Name . "\versions")
			FileAppend(Index, Local_ . "\" . Name . "\versions\v" . Index)
		}
		EnvSet("LOCALAPPDATA", Local_), EnvSet("APPDATA", Roaming), EnvSet("USERPROFILE", Home)
		Root := RTrim(AppFoldersRoot(), "\")
		Report := LegacyFolderMigrationRun(AppFoldersPathsFile())
		Managed := AppFoldersManagedOllamaRoot()
		AssertEqual(Root . "\" . AppDirsWindowsManagedOllamaFolderName(), Managed, "the managed runtime is inside the root")
		Assert(FileExist(Managed . "\versions\v1"), "the first old runtime folder became the managed root")
		Backup := Root . "\" . AppDirsMigrationBackupFolder() . "\" . Ollama[2]
		Assert(FileExist(Backup . "\versions\v2"), "the second old runtime folder went to the backup")
		Assert(FileExist(Root . "\logs\old.log"), "the old LocalAppData entries merged into the root")
		Assert(FileExist(AppFoldersPathsFile()), "the Roaming paths.toml moved into the root")
		Assert(FileExist(RTrim(AppFoldersDefaultConfigDir(), "\") . "\config.toml"), "the old configuration folder moved")
		for Name in Ollama
			Assert(!FileExist(Local_ . "\" . Name), "the old runtime folder " . Name . " is gone")
		Assert(!FileExist(Local_ . "\" . AppDirsMigrationWindowsLegacyLocalFolder()), "the old LocalAppData folder is gone")
		AssertEqual(1, Report["backed_up"].Length, "one entry backed up")
		AssertEqual(0, Report["kept"].Length, "nothing left behind")
		Again := LegacyFolderMigrationRun(AppFoldersPathsFile())
		AssertEqual(0, Again["moved"].Length + Again["backed_up"].Length + Again["kept"].Length,
			"a second boot has nothing to move")
	} finally {
		for Name, Value in Saved
			EnvSet(Name, Value)
		if DirExist(Profile)
			DirDelete(Profile, true)
	}
}
Test("legacy folder migration: the Windows plan moves both old Ollama folders on a private profile (legacy-folder-migration-windows-plan)",
	_LFM_WindowsPlanMovesEveryOldFolderOnAPrivateProfile)
