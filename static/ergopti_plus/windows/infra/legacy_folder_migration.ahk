; infra/legacy_folder_migration.ahk

; ==============================================================================
; MODULE: Legacy Folder Migration (Windows)
; DESCRIPTION:
; Moves, once at boot, the folders of the builds before the single folder name
; into %LOCALAPPDATA%\Ergopti: the Roaming paths.toml, the default
; configuration folder %USERPROFILE%\.config\<old>, every entry of the old
; LocalAppData folder (logs, cache, control, updater, diagnostics) and the old
; managed Ollama folders (the first build's, then the protected sibling), each
; into %LOCALAPPDATA%\Ergopti\ollama. A paths.toml that named an old default folder is
; rewritten to the new one, after a backup of its previous text, only when
; that folder actually moved; when the file cannot follow, the configuration
; folder moves back.
;
; FEATURES & RATIONALE:
; 1. Same Rules as Lua: a move is a rename that never overwrites. An empty
;    destination folder gives way; an entry whose destination holds something
;    goes to <root>\<backup folder>\ instead, so every old folder empties and is
;    removed and the migration has nothing to do at the next boot. paths.toml
;    is backed up before its text changes. The shared vectors
;    (_shared/tests/corpus/paths/legacy_folder_migration_vectors.json) pin both;
;    _shared/lua/legacy_folder_migration.lua is the Lua twin.
; 2. Before paths.toml: infra/boot.ahk runs it before the configuration
;    transition recovery reads paths.toml, and before the logger opens its
;    folder; its lines are queued until LoggerInit.
; 3. Never in Tests: the startup smoke and the unit harness never call it, so
;    no test moves a real user folder.
; 4. Maintainer Machines Only: no build was published with the old folders
;    (project memory, 2026-09-23); this goes once his machines are moved.
; ==============================================================================

#Requires AutoHotkey v2.0

; The suffix of the private stage files the paths.toml publication renames.
global LEGACY_FOLDER_STAGE_SUFFIX := ".migration-stage"
; Why paths.toml still names an old folder, for its warning (PATHS_FILE_REFUSALS
; of _shared/lua/legacy_folder_migration.lua).
global LEGACY_FOLDER_PATHS_REFUSALS := Map(
		"read_failed", "it could not be read",
		"backup_taken", "its backup name already holds other text",
		"backup_refused", "its backup could not be written",
		"write_refused", "its new text could not be written (the backup beside it holds the previous text)")





; ===============================
; ===============================
; ======= 1/ Entry moves ========
; ===============================
; ===============================

; Renames one file or folder to a free path after creating its parent.
; @param From {String} Old path.
; @param To {String} New path, known to be free.
; @returns {String} "" when renamed, else the error message.
LegacyFolderRenameInto(From, To) {
		SplitPath(To, , &Parent)
		try {
				if (Parent != "" && !DirExist(Parent))
						DirCreate(Parent)
				if InStr(FileExist(From), "D")
						DirMove(From, To)
				else if !FSMove(From, To)
						throw Error("The file could not be renamed.")
		} catch as MoveError {
				return MoveError.Message
		}
		return ""
}

; Whether a path is a folder that holds nothing.
; @param Dir {String}
; @returns {Boolean}
LegacyFolderIsEmptyDir(Dir) {
		if !DirExist(Dir)
				return false
		loop files, Dir . "\*", "FD"
				return false
		return true
}

; Moves one old entry into its backup slot, its destination being taken.
; Mirrors back_up_entry of _shared/lua/legacy_folder_migration.lua.
; @param From {String} Old path.
; @param To {String} The taken destination.
; @param Backup {String} Path the old entry takes.
; @param Report {Map} Receives a "backed_up" or a "kept" row.
LegacyFolderBackUpEntry(From, To, Backup, Report) {
		if (FileExist(Backup) != "") {
				Report["kept"].Push(Map("from", From, "to", Backup, "reason", "backup_exists"))
				return
		}
		Failure := LegacyFolderRenameInto(From, Backup)
		if (Failure == "")
				Report["backed_up"].Push(Map("from", From, "to", Backup, "taken", To))
		else if (FileExist(Backup) != "")
				; The slot was taken between the check and the move, which never
				; replaces: what arrived there stays.
				Report["kept"].Push(Map("from", From, "to", Backup, "reason", "backup_exists"))
		else
				Report["kept"].Push(Map("from", From, "to", Backup, "reason", "rename_failed", "detail", Failure))
}

; Moves one file or folder to its destination; when the destination holds
; something, moves it into the backup slot instead. Mirrors move_entry of
; _shared/lua/legacy_folder_migration.lua. DirMove and FSMove never replace an
; existing destination, so one that appears after the check fails the move and
; the old entry goes to its backup like any taken name.
; @param From {String} Old path.
; @param To {String} New path.
; @param Backup {String} Path the old entry takes when To is taken.
; @param Report {Map} Receives "moved", "backed_up" and "kept" rows.
LegacyFolderMoveEntry(From, To, Backup, Report) {
		if (FileExist(From) == "")
				return
		if (FileExist(To) != "") {
				; An empty folder created ahead of the migration holds no data.
				Freed := false
				if LegacyFolderIsEmptyDir(To) {
						try {
								DirDelete(To, false)
								Freed := true
						}
				}
				if !Freed {
						LegacyFolderBackUpEntry(From, To, Backup, Report)
						return
				}
		}
		Failure := LegacyFolderRenameInto(From, To)
		if (Failure == "")
				Report["moved"].Push(Map("from", From, "to", To))
		else if (FileExist(To) != "")
				LegacyFolderBackUpEntry(From, To, Backup, Report)
		else
				Report["kept"].Push(Map("from", From, "to", To, "reason", "rename_failed", "detail", Failure))
}

; Moves every entry of a folder into another one (a taken name goes to the
; backup folder), then removes the old folder when nothing is left in it.
; @param FromDir {String} Old folder, without a trailing backslash.
; @param ToDir {String} New folder, without a trailing backslash.
; @param BackupDir {String} Folder receiving the entries whose name is taken.
; @param Report {Map} Receives "moved", "backed_up", "kept" and "removed" rows.
LegacyFolderMergeEntries(FromDir, ToDir, BackupDir, Report) {
		if !DirExist(FromDir)
				return
		; A loop files over a folder it cannot open yields nothing, as if the
		; folder were empty; the strict listing throws, and the refusal is kept.
		Names := []
		try {
				for Directories in [false, true] {
						for Path in FSListDirectoryStrict(FromDir, Directories) {
								SplitPath(Path, &Name)
								Names.Push(Name)
						}
				}
		} catch as ListError {
				Report["kept"].Push(Map("from", FromDir, "to", ToDir, "reason", "list_failed", "detail", ListError.Message))
				return
		}
		for Name in Names
				LegacyFolderMoveEntry(FromDir . "\" . Name, ToDir . "\" . Name, BackupDir . "\" . Name, Report)
		LegacyFolderRemoveIfEmpty(FromDir, Report)
}

; Removes a folder that holds nothing.
; @param Dir {String} Folder, without a trailing backslash.
; @param Report {Map} Receives the "removed" row, or a "kept" row on failure.
LegacyFolderRemoveIfEmpty(Dir, Report) {
		if !LegacyFolderIsEmptyDir(Dir)
				return
		try {
				DirDelete(Dir, false)
		} catch as DeleteError {
				Report["kept"].Push(Map("from", Dir, "to", Dir, "reason", "remove_failed", "detail", DeleteError.Message))
				return
		}
		Report["removed"].Push(Dir)
}





; =====================================
; =====================================
; ======= 2/ paths.toml rewrite =======
; =====================================
; =====================================

; Normalizes a folder spelling for comparison: one backslash separator, no
; trailing separator, TOML-escaped backslashes undone.
; @param Value {String}
; @returns {String}
LegacyFolderNormalize(Value) {
		Value := StrReplace(StrReplace(Value, "\\", "\"), "/", "\")
		return RTrim(Value, "\")
}

; The new value of one locator, or "" when the rule does not name it. Mirrors
; rebased of _shared/lua/legacy_folder_migration.lua: the old folder itself
; becomes "new", a folder below it the same folder below "under" (where the old
; folder went; "new" by default). The comparison ignores case, as Windows paths
; do, and the result keeps the separator style of the value.
; @param Value {String} Current value, as spelled in the line.
; @param Rule {Map} "old" (Array), "new" and an optional "under".
; @returns {String}
LegacyFolderRebased(Value, Rule) {
		if (Value == "")
				return ""
		Current := LegacyFolderNormalize(Value)
		; The trailing separators, spelled like the rest before the style below.
		RegExMatch(Value, "[\\/]+$", &Tail)
		Trailing := IsObject(Tail) ? StrReplace(StrReplace(Tail[0], "\\", "\"), "/", "\") : ""
		New := ""
		for Old in Rule["old"] {
				OldFolder := LegacyFolderNormalize(Old)
				if (Current = OldFolder) {
						New := LegacyFolderNormalize(Rule["new"]) . Trailing
						break
				}
				Prefix := OldFolder . "\"
				if (OldFolder != "" && StrLen(Current) > StrLen(Prefix) && SubStr(Current, 1, StrLen(Prefix)) = Prefix) {
						Base := Rule.Has("under") ? Rule["under"] : Rule["new"]
						New := LegacyFolderNormalize(Base) . SubStr(Current, StrLen(OldFolder) + 1) . Trailing
						break
				}
		}
		if (New == "")
				return ""
		; Keep the separator style of the line: forward slashes, or the doubled
		; backslashes of a TOML basic string.
		if InStr(Value, "/")
				New := StrReplace(New, "\", "/")
		else if InStr(Value, "\\")
				New := StrReplace(New, "\", "\\")
		return New
}

; Rewrites the paths.toml lines whose value is an old default folder or a
; folder below one. Mirrors rewrite_paths_text of
; _shared/lua/legacy_folder_migration.lua.
; @param Text {String} paths.toml content.
; @param Rewrites {Array} Maps with "key", "old" (Array), "new" and an optional "under".
; @returns {String} The new text, or "" when nothing changed.
LegacyFolderRewritePathsText(Text, Rewrites) {
		Changed := false
		Out := ""
		Lines := StrSplit(Text, "`n")
		for Index, Line in Lines {
				if (Index > 1)
						Out .= "`n"
				if !RegExMatch(Line, '^(\s*)(\w+)(\s*=\s*)"([^"]*)"(.*)$', &Match) {
						Out .= Line
						continue
				}
				Replacement := Line
				for Rule in Rewrites {
						if (Rule["key"] != Match[2])
								continue
						New := LegacyFolderRebased(Match[4], Rule)
						if (New == "")
								continue
						if (New != Match[4]) {
								Replacement := Match[1] . Match[2] . Match[3] . '"' . New . '"' . Match[5]
								Changed := true
						}
						break
				}
				Out .= Replacement
		}
		return Changed ? Out : ""
}

; Rewrites one paths.toml after keeping its previous text beside it. Mirrors
; rewrite_paths_file of _shared/lua/legacy_folder_migration.lua: both files are
; written to a private stage and renamed into place (the backup with a
; no-replace move, paths.toml with an atomic replace), so a refused or partial
; write leaves paths.toml exactly as it was. A backup holding the current text,
; left by an interrupted boot, is reused; one holding other text is kept.
; @param Path {String} paths.toml.
; @param Rewrites {Array} See LegacyFolderRewritePathsText.
; @returns {String} "absent", "unchanged", "rewritten", or the refusal
;   "read_failed", "backup_taken", "backup_refused" or "write_refused".
LegacyFolderRewritePathsFile(Path, Rewrites) {
		if !FileExist(Path)
				return "absent"
		try Text := FSReadStrict(Path)
		catch
				return "read_failed"
		Rewritten := LegacyFolderRewritePathsText(Text, Rewrites)
		if (Rewritten == "")
				return "unchanged"
		Backup := Path . AppDirsMigrationBackupSuffix()
		if FileExist(Backup) {
				try BackupText := FSReadStrict(Backup)
				catch
						return "backup_taken"
				if (BackupText !== Text)
						return "backup_taken"
		} else {
				; The stage names are written by this migration alone.
				Stage := Backup . LEGACY_FOLDER_STAGE_SUFFIX
				if FileExist(Stage)
						FSDelete(Stage)
				if !FSCopyCreateVerified(Path, Stage) || !FSAtomicMoveCreate(Stage, Backup) {
						FSDelete(Stage)
						return "backup_refused"
				}
		}
		Stage := Path . LEGACY_FOLDER_STAGE_SUFFIX
		if FileExist(Stage)
				FSDelete(Stage)
		if !FSWriteCreateDurable(Stage, Rewritten) || !FSAtomicMoveReplace(Stage, Path) {
				FSDelete(Stage)
				return "write_refused"
		}
		return "rewritten"
}

; The report row of one old folder, as LegacyFolderOutcomeKind names it.
; @param Report {Map} Report of the moves.
; @param Source {String} Absolute old folder.
; @param Kind {VarRef} Receives "moved", "backed_up", "kept" or "".
; @returns {Map|String} The row, or "" when the folder has none.
LegacyFolderOutcomeOf(Report, Source, &Kind) {
		for Name in ["moved", "backed_up", "kept"] {
				for Row in Report[Name] {
						; Windows paths ignore case: = rather than ==.
						if (LegacyFolderNormalize(Row["from"]) = LegacyFolderNormalize(Source)) {
								Kind := Name
								return Row
						}
				}
		}
		Kind := ""
		return ""
}

; Keeps the rewrites whose old folder did not stay where it was. Mirrors
; settle_rewrites: a refused move keeps the data in the folder paths.toml names.
; @param Rules {Array} Maps with "key", "old", "new" and an optional "source".
; @param Report {Map} Report of the moves.
; @returns {Array} The rewrites for LegacyFolderRewritePathsText.
LegacyFolderSettleRewrites(Rules, Report) {
		Settled := []
		for Rule in Rules {
				if Rule.Has("source") {
						Row := LegacyFolderOutcomeOf(Report, Rule["source"], &Kind)
						if (Kind == "kept")
								continue
						if (Kind == "moved" || Kind == "backed_up") {
								; A folder chosen below the old one is where its ancestor went.
								Settled.Push(Map("key", Rule["key"], "old", Rule["old"], "new", Rule["new"], "under", Row["to"]))
								continue
						}
				}
				Settled.Push(Rule)
		}
		return Settled
}

; Rewrites paths.toml from what moved; when it cannot, moves each "restorable"
; folder back to the old path the file still names, so boot never selects an
; empty folder while the user's one sits elsewhere. Mirrors publish_paths_file.
; @param PathsFile {String} paths.toml.
; @param Rules {Array} Maps with "key", "old", "new", "source", "restorable".
; @param Report {Map} Receives "paths_file" and the "restored" rows.
LegacyFolderPublishPathsFile(PathsFile, Rules, Report) {
		Report["paths_file"] := LegacyFolderRewritePathsFile(PathsFile, LegacyFolderSettleRewrites(Rules, Report))
		if !LEGACY_FOLDER_PATHS_REFUSALS.Has(Report["paths_file"])
				return
		for Rule in Rules {
				if !(Rule.Has("restorable") && Rule["restorable"])
						continue
				Row := LegacyFolderOutcomeOf(Report, Rule["source"], &Kind)
				if (Kind != "moved" && Kind != "backed_up")
						continue
				Failure := LegacyFolderRenameInto(Row["to"], Row["from"])
				if (Failure == "")
						Report["restored"].Push(Map("from", Row["to"], "to", Row["from"]))
				else
						Report["kept"].Push(Map("from", Row["to"], "to", Row["from"], "reason", "restore_failed",
								"detail", Failure))
		}
}





; ===============================
; ===============================
; ======= 3/ Boot entry =========
; ===============================
; ===============================

; Runs the migration of the current user and queues its log lines.
; @param PathsFile {String} The paths.toml boot is about to read.
; @returns {Map} Report with "moved", "kept", "removed" and "paths_file".
LegacyFolderMigrationRun(PathsFile) {
		Report := Map("moved", [], "backed_up", [], "kept", [], "removed", [], "restored", [], "paths_file", "absent")
		Root := RTrim(AppFoldersRoot(), "\")
		; An old entry whose destination is taken goes to
		; <root>\<backup folder>\<its path below its environment folder>.
		Backup := Root . "\" . AppDirsMigrationBackupFolder()
		LocalAppData := AppFoldersBase("LOCALAPPDATA")
		LegacyPaths := AppFoldersBase(AppDirsMigrationWindowsLegacyPathsFileBaseEnv()) . "\"
				. AppDirsMigrationWindowsLegacyPathsFileRelative()
		LegacyConfig := AppFoldersBase(AppDirsMigrationWindowsLegacyConfigBaseEnv()) . "\"
				. AppDirsMigrationWindowsLegacyConfigRelative()
		LegacyLocal := LocalAppData . "\" . AppDirsMigrationWindowsLegacyLocalFolder()
		NewConfig := RTrim(AppFoldersDefaultConfigDir(), "\")
		LegacyFolderMoveEntry(LegacyPaths, AppFoldersPathsFile(),
				Backup . "\" . AppDirsMigrationWindowsLegacyPathsFileRelative(), Report)
		SplitPath(LegacyPaths, , &LegacyPathsDir)
		LegacyFolderRemoveIfEmpty(LegacyPathsDir, Report)
		LegacyFolderMoveEntry(LegacyConfig, NewConfig, Backup . "\" . AppDirsMigrationWindowsLegacyConfigRelative(), Report)
		LegacyFolderMergeEntries(LegacyLocal, Root, Backup . "\" . AppDirsMigrationWindowsLegacyLocalFolder(), Report)
		; A rename keeps the runtime folder's protected ACL and file identity, which
		; its root-owner.json receipt records; the second old folder, when the first
		; one already moved, goes to the backup.
		for LegacyOllama in AppDirsMigrationWindowsLegacyOllamaFolders()
				LegacyFolderMoveEntry(LocalAppData . "\" . LegacyOllama, AppFoldersManagedOllamaRoot(),
						Backup . "\" . LegacyOllama, Report)
		; The configuration folder moves in one rename, so a locator that cannot
		; follow it gets it back; the logs folder only follows.
		Rules := [
				Map("key", "ConfigDirPath", "old", [LegacyConfig], "new", NewConfig, "source", LegacyConfig,
						"restorable", true),
				Map("key", AppDirsLogsOverrideKey(), "old", [LegacyLocal . "\logs"], "new", RTrim(LoggerDefaultLogsDir(), "\"),
						"source", LegacyLocal . "\logs")
		]
		LegacyFolderPublishPathsFile(PathsFile, Rules, Report)
		LegacyFolderLogReport(Report)
		return Report
}

; Logs a migration report; before LoggerInit the lines are queued.
; @param Report {Map} Report from LegacyFolderMigrationRun.
LegacyFolderLogReport(Report) {
		for Row in Report["moved"]
				LoggerInfo("Boot", "Moved legacy folder entry '{1}' to '{2}'.", Row["from"], Row["to"])
		for Row in Report["backed_up"]
				LoggerWarn("Boot", "Moved legacy folder entry '{1}' to the backup '{2}': '{3}' is already taken.",
						Row["from"], Row["to"], Row["taken"])
		; The reason phrases of KEPT_REASONS in _shared/lua/legacy_folder_migration.lua.
		Reasons := Map("backup_exists", "a backup already exists", "list_failed", "its folder could not be listed",
				"remove_failed", "its emptied folder could not be removed",
				"restore_failed", "it could not be moved back to the folder paths.toml names")
		for Row in Report["kept"]
				LoggerWarn("Boot", "Kept legacy folder entry '{1}': {2} at '{3}' ({4}).", Row["from"],
						Reasons.Has(Row["reason"]) ? Reasons[Row["reason"]] : "it could not be moved",
						Row["to"], Row.Has("detail") ? Row["detail"] : Row["reason"])
		for Dir in Report["removed"]
				LoggerInfo("Boot", "Removed the emptied legacy folder '{1}'.", Dir)
		if (Report["paths_file"] == "rewritten")
				LoggerInfo("Boot", "paths.toml now names the new default folders; its previous text is kept beside it.")
		else if LEGACY_FOLDER_PATHS_REFUSALS.Has(Report["paths_file"])
				LoggerWarn("Boot", "paths.toml still names an old default folder: {1}.",
						LEGACY_FOLDER_PATHS_REFUSALS[Report["paths_file"]])
		for Row in Report["restored"]
				LoggerWarn("Boot", "Moved '{1}' back to '{2}', the folder paths.toml still names.", Row["from"], Row["to"])
}
