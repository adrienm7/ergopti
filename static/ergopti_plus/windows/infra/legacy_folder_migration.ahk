; infra/legacy_folder_migration.ahk

; ==============================================================================
; MODULE: Legacy Folder Migration (Windows)
; DESCRIPTION:
; Moves, once at boot, the folders of the builds before the single folder name
; into %LOCALAPPDATA%\Ergopti: the Roaming paths.toml, the default
; configuration folder %USERPROFILE%\.config\<old>, every entry of the old
; LocalAppData folder (logs, cache, control, updater, diagnostics) and the old
; managed Ollama folder. A paths.toml that named an old default folder is
; rewritten to the new one, after a backup of its previous text.
;
; FEATURES & RATIONALE:
; 1. Same Rules as Lua: an entry moves only when nothing exists at its
;    destination, a move is a rename, the emptied old folder is removed, and
;    paths.toml is backed up before its text changes. The shared vectors
;    (_shared/tests/corpus/paths/legacy_folder_migration_vectors.json) pin the
;    rewrite; _shared/lua/legacy_folder_migration.lua is the Lua twin.
; 2. Before paths.toml: infra/boot.ahk runs it before the configuration
;    transition recovery reads paths.toml, and before the logger opens its
;    folder; its lines are queued until LoggerInit.
; 3. Never in Tests: the startup smoke and the unit harness never call it, so
;    no test moves a real user folder.
; 4. Maintainer Machines Only: no build was published with the old folders
;    (project memory, 2026-09-23); this goes once his machines are moved.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================
; ===============================
; ======= 1/ Entry moves ========
; ===============================
; ===============================

; Moves one file or folder when its destination is free; reports the outcome.
; @param From {String} Old path.
; @param To {String} New path.
; @param Report {Map} Receives "moved" and "kept" rows.
LegacyFolderMoveEntry(From, To, Report) {
		Attributes := FileExist(From)
		if (Attributes == "")
				return
		if (FileExist(To) != "") {
				Report["kept"].Push(Map("from", From, "to", To, "reason", "destination_exists"))
				return
		}
		SplitPath(To, , &Parent)
		try {
				if (Parent != "" && !DirExist(Parent))
						DirCreate(Parent)
				if InStr(Attributes, "D")
						DirMove(From, To)
				else
						FileMove(From, To)
		} catch as MoveError {
				Report["kept"].Push(Map("from", From, "to", To, "reason", "rename_failed", "detail", MoveError.Message))
				return
		}
		Report["moved"].Push(Map("from", From, "to", To))
}

; Moves every entry of a folder into another one, then removes the old folder
; when nothing is left in it.
; @param FromDir {String} Old folder, without a trailing backslash.
; @param ToDir {String} New folder, without a trailing backslash.
; @param Report {Map} Receives "moved", "kept" and "removed" rows.
LegacyFolderMergeEntries(FromDir, ToDir, Report) {
		if !DirExist(FromDir)
				return
		Names := []
		loop files, FromDir . "\*", "FD"
				Names.Push(A_LoopFileName)
		for Name in Names
				LegacyFolderMoveEntry(FromDir . "\" . Name, ToDir . "\" . Name, Report)
		LegacyFolderRemoveIfEmpty(FromDir, Report)
}

; Removes a folder that holds nothing.
; @param Dir {String} Folder, without a trailing backslash.
; @param Report {Map} Receives the "removed" row.
LegacyFolderRemoveIfEmpty(Dir, Report) {
		if !DirExist(Dir)
				return
		loop files, Dir . "\*", "FD"
				return
		try {
				DirDelete(Dir, false)
		} catch as DeleteError {
				LoggerWarn("Boot", "The emptied legacy folder '{1}' could not be removed: {2}.", Dir, DeleteError.Message)
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

; Rewrites the paths.toml lines whose value is an old default folder.
; Mirrors rewrite_paths_text of _shared/lua/legacy_folder_migration.lua; the
; comparison ignores case, as Windows paths do.
; @param Text {String} paths.toml content.
; @param Rewrites {Array} Maps with "key", "old" (Array) and "new".
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
						if (Rule["key"] != Match[2] || Match[4] == "")
								continue
						for Old in Rule["old"] {
								if (LegacyFolderNormalize(Match[4]) != LegacyFolderNormalize(Old))
										continue
								RegExMatch(Match[4], "[\\/]+$", &Tail)
								Trailing := IsObject(Tail) ? Tail[0] : ""
								New := RTrim(Rule["new"], "\/") . Trailing
								; Keep the separator style of the line: forward slashes, or the
								; doubled backslashes of a TOML basic string.
								if InStr(Match[4], "/")
										New := StrReplace(New, "\", "/")
								else if InStr(Match[4], "\\")
										New := StrReplace(StrReplace(New, "\\", "\"), "\", "\\")
								if (New != Match[4]) {
										Replacement := Match[1] . Match[2] . Match[3] . '"' . New . '"' . Match[5]
										Changed := true
								}
								break
						}
				}
				Out .= Replacement
		}
		return Changed ? Out : ""
}

; Rewrites one paths.toml after keeping its previous text beside it.
; @param Path {String} paths.toml.
; @param Rewrites {Array} See LegacyFolderRewritePathsText.
; @returns {String} "absent", "unchanged", "rewritten" or "backup_refused".
LegacyFolderRewritePathsFile(Path, Rewrites) {
		if !FileExist(Path)
				return "absent"
		try Text := FileRead(Path, "UTF-8")
		catch
				return "backup_refused"
		Rewritten := LegacyFolderRewritePathsText(Text, Rewrites)
		if (Rewritten == "")
				return "unchanged"
		Backup := Path . AppDirsMigrationBackupSuffix()
		if FileExist(Backup)
				return "backup_refused"
		try {
				FileCopy(Path, Backup)
				File := FileOpen(Path, "w", "UTF-8-RAW")
				File.Write(Rewritten)
				File.Close()
		} catch
				return "backup_refused"
		return "rewritten"
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
		Report := Map("moved", [], "kept", [], "removed", [], "paths_file", "absent")
		Root := RTrim(AppFoldersRoot(), "\")
		LocalAppData := AppFoldersBase("LOCALAPPDATA")
		LegacyPaths := AppFoldersBase(AppDirsMigrationWindowsLegacyPathsFileBaseEnv()) . "\"
				. AppDirsMigrationWindowsLegacyPathsFileRelative()
		LegacyConfig := AppFoldersBase(AppDirsMigrationWindowsLegacyConfigBaseEnv()) . "\"
				. AppDirsMigrationWindowsLegacyConfigRelative()
		LegacyLocal := LocalAppData . "\" . AppDirsMigrationWindowsLegacyLocalFolder()
		NewConfig := RTrim(AppFoldersDefaultConfigDir(), "\")
		LegacyFolderMoveEntry(LegacyPaths, AppFoldersPathsFile(), Report)
		SplitPath(LegacyPaths, , &LegacyPathsDir)
		LegacyFolderRemoveIfEmpty(LegacyPathsDir, Report)
		LegacyFolderMoveEntry(LegacyConfig, NewConfig, Report)
		LegacyFolderMergeEntries(LegacyLocal, Root, Report)
		LegacyFolderMoveEntry(LocalAppData . "\" . AppDirsMigrationWindowsLegacyOllamaFolder(),
				AppFoldersManagedOllamaRoot(), Report)
		Rewrites := [
				Map("key", "ConfigDirPath", "old", [LegacyConfig], "new", NewConfig),
				Map("key", AppDirsLogsOverrideKey(), "old", [LegacyLocal . "\logs"], "new", RTrim(LoggerDefaultLogsDir(), "\"))
		]
		Report["paths_file"] := LegacyFolderRewritePathsFile(PathsFile, Rewrites)
		LegacyFolderLogReport(Report)
		return Report
}

; Logs a migration report; before LoggerInit the lines are queued.
; @param Report {Map} Report from LegacyFolderMigrationRun.
LegacyFolderLogReport(Report) {
		for Row in Report["moved"]
				LoggerInfo("Boot", "Moved legacy folder entry '{1}' to '{2}'.", Row["from"], Row["to"])
		for Row in Report["kept"]
				LoggerWarn("Boot", "Kept legacy folder entry '{1}': {2} at '{3}'.", Row["from"],
						Row["reason"] == "destination_exists" ? "an entry already exists" : "it could not be moved",
						Row["to"])
		for Dir in Report["removed"]
				LoggerInfo("Boot", "Removed the emptied legacy folder '{1}'.", Dir)
		if (Report["paths_file"] == "rewritten")
				LoggerInfo("Boot", "paths.toml now names the new default folders; its previous text is kept beside it.")
		else if (Report["paths_file"] == "backup_refused")
				LoggerWarn("Boot", "paths.toml still names an old default folder: its backup could not be written.")
}
