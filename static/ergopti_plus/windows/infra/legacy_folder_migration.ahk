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
;    _shared/settings/engine/migration/legacy_folder_migration_core.lua is the Lua twin.
; 2. Before paths.toml: infra/boot.ahk runs it before the configuration
;    transition recovery reads paths.toml, and before the logger opens its
;    folder; its lines are queued until LoggerInit. A transition journal the
;    old build left beside its own paths.toml is recovered there first.
; 3. Never in Tests: the startup smoke and the unit harness never call it, so
;    no test moves a real user folder.
; 4. Maintainer Machines Only: no build was published with the old folders
;    (project memory, 2026-09-23); this goes once his machines are moved.
; ==============================================================================

#Requires AutoHotkey v2.0

; The suffix of the private stage files the paths.toml publication renames.
global LEGACY_FOLDER_STAGE_SUFFIX := ".migration-stage"
; Why paths.toml still names an old folder, for its warning (PATHS_FILE_REFUSALS
; of _shared/settings/engine/migration/legacy_folder_migration_core.lua).
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
; Mirrors back_up_entry of _shared/settings/engine/migration/legacy_folder_migration_core.lua.
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
; _shared/settings/engine/migration/legacy_folder_migration_core.lua. DirMove and FSMove never replace an
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

; Reads one single-line TOML string at Pos of Line, as the boot TOML reader
; does: a literal string as written, a basic string with its escapes decoded.
; Mirrors read_string of _shared/settings/engine/migration/legacy_folder_migration_core.lua.
; @param Line {String}
; @param Pos {Integer} Position of the opening quote.
; @param Value {VarRef} Receives the decoded value.
; @param After {VarRef} Receives the position after the closing quote.
; @param Kind {VarRef} Receives "basic" or "literal".
; @returns {Boolean} False when no valid string starts there.
LegacyFolderReadTomlString(Line, Pos, &Value, &After, &Kind) {
		static Escapes := Map("b", "`b", "t", "`t", "n", "`n", "f", "`f", "r", "`r", '"', '"', "\", "\")
		Quote := SubStr(Line, Pos, 1)
		if (Quote == "'") {
				Close := InStr(Line, "'", true, Pos + 1)
				if !Close
						return false
				Value := SubStr(Line, Pos + 1, Close - Pos - 1), After := Close + 1, Kind := "literal"
				return true
		}
		if (Quote != '"')
				return false
		Value := "", Index := Pos + 1
		while (Index <= StrLen(Line)) {
				Char := SubStr(Line, Index, 1)
				if (Char == '"') {
						After := Index + 1, Kind := "basic"
						return true
				}
				if (Char != "\") {
						Value .= Char, Index += 1
						continue
				}
				Letter := SubStr(Line, Index + 1, 1)
				if Escapes.Has(Letter) {
						Value .= Escapes[Letter], Index += 2
						continue
				}
				if (Letter !== "u" && Letter !== "U")
						return false
				Width := (Letter == "u") ? 4 : 8
				Hex := SubStr(Line, Index + 2, Width)
				if !RegExMatch(Hex, "^[0-9A-Fa-f]{" . Width . "}$")
						return false
				Code := Integer("0x" . Hex)
				if (Code > 0x10FFFF || (Code >= 0xD800 && Code <= 0xDFFF))
						return false
				Value .= Chr(Code), Index += 2 + Width
		}
		return false
}

; Spells a value as a TOML string of the kind it replaces; a literal string
; cannot hold a quote or a control character, so such a value becomes basic.
; Mirrors spell_string of _shared/settings/engine/migration/legacy_folder_migration_core.lua.
; @param Value {String}
; @param Kind {String} "basic" or "literal".
; @returns {String}
LegacyFolderSpellTomlString(Value, Kind) {
		if (Kind == "literal" && !RegExMatch(Value, "['\x00-\x1F\x7F]"))
				return "'" . Value . "'"
		Out := ""
		loop parse Value {
				Code := Ord(A_LoopField)
				if (A_LoopField == "\" || A_LoopField == '"')
						Out .= "\" . A_LoopField
				else if (Code == 8)
						Out .= "\b"
				else if (Code == 9)
						Out .= "\t"
				else if (Code == 10)
						Out .= "\n"
				else if (Code == 12)
						Out .= "\f"
				else if (Code == 13)
						Out .= "\r"
				else if (Code < 0x20 || Code == 0x7F)
						Out .= Format("\u{:04X}", Code)
				else
						Out .= A_LoopField
		}
		return '"' . Out . '"'
}

; Splits one `key = "value"` line of paths.toml as the boot TOML reader reads
; it: a bare or quoted key, and a basic or literal single-line string.
; Mirrors parse_assignment of _shared/settings/engine/migration/legacy_folder_migration_core.lua.
; @param Line {String}
; @returns {Map|String} "indent", "key", "key_text", "spacing", "value", "kind"
;   and "rest", or "" when the line is not such an assignment.
LegacyFolderParseAssignment(Line) {
		RegExMatch(Line, "^\s*", &Indent)
		Pos := Indent.Len + 1
		if RegExMatch(Line, "\G[A-Za-z0-9_-]+", &Bare, Pos) {
				Key := Bare[0], KeyText := Bare[0], After := Pos + Bare.Len
		} else {
				if !LegacyFolderReadTomlString(Line, Pos, &Key, &After, &KeyKind)
						return ""
				KeyText := SubStr(Line, Pos, After - Pos)
		}
		if !RegExMatch(Line, "\G\s*=\s*", &Spacing, After)
				return ""
		if !LegacyFolderReadTomlString(Line, After + Spacing.Len, &Value, &ValueAfter, &Kind)
				return ""
		return Map("indent", Indent[0], "key", Key, "key_text", KeyText, "spacing", Spacing[0], "value", Value,
				"kind", Kind, "rest", SubStr(Line, ValueAfter))
}

; The new value of one locator, or "" when the rule does not name it. Mirrors
; rebased of _shared/settings/engine/migration/legacy_folder_migration_core.lua: the old folder itself
; becomes "new", a folder below it the same folder below "under" (where the old
; folder went; "new" by default). The comparison ignores case, as Windows paths
; do, and the result keeps the separator style of the value.
; @param Value {String} Current value, decoded.
; @param Rule {Map} "old" (Array), "new" and the optional "under" and "renamed".
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
		; A custom folder named like the old one becomes its parent's folder named
		; after the application (renamed_folder of the Lua core).
		if (New == "" && Rule.Has("renamed")) {
				Folder := LegacyFolderRenamedFolder(Current, Rule["renamed"])
				if (Folder != "")
						New := Folder . Trailing
		}
		if (New == "")
				return ""
		; Keep the separator style of the value; the string spelling doubles a
		; backslash of a basic string.
		if InStr(Value, "/")
				New := StrReplace(New, "\", "/")
		return New
}

; The folder a custom locator names in place of Renamed["from"]: the same
; parent, with the folder named Renamed["to"]. Only a folder whose last name is
; the old one is renamed, or its Renamed["to"] subfolder (the logger appends one
; to a folder not named after the application); any other folder is kept.
; Mirrors renamed_folder of _shared/settings/engine/migration/legacy_folder_migration_core.lua,
; ignoring case as Windows paths do.
; @param Folder {String} Normalized folder, without a trailing separator.
; @param Renamed {Map} "from" and "to" folder names.
; @returns {String} The new folder, or "" when the rule does not name it.
LegacyFolderRenamedFolder(Folder, Renamed) {
		SplitPath(Folder, &Leaf, &Parent)
		if (Leaf = Renamed["to"])
				SplitPath(Parent, &Leaf, &Parent)
		if (Leaf != Renamed["from"] || Parent == "")
				return ""
		return Parent . "\" . Renamed["to"]
}

; The value of one paths.toml key, or "" when no line assigns it. Mirrors
; paths_value of the Lua core.
; @param Text {String} paths.toml content.
; @param Key {String}
; @returns {String}
LegacyFolderPathsValue(Text, Key) {
		for Line in StrSplit(Text, "`n") {
				Parts := LegacyFolderParseAssignment(Line)
				if (Parts is Map) && Parts["key"] == Key
						return Parts["value"]
		}
		return ""
}

; The custom logs folder named like the old application folder that a
; LogsDirPath names, or "" (custom_legacy_logs of the macOS migration). The old
; default LocalAppData folder is not custom: it merges into the root.
; @param Value {String} The LogsDirPath value.
; @param LegacyLocal {String} The old LocalAppData folder.
; @returns {String} The old-named folder, without a trailing separator.
LegacyFolderCustomLegacyLogs(Value, LegacyLocal) {
		Folder := LegacyFolderNormalize(Value)
		if (Folder == "" || !LoggerIsAbsoluteFolder(Folder))
				return ""
		SplitPath(Folder, &Leaf, &Parent)
		if (Leaf = AppDirsFolderName()) {
				Folder := Parent
				SplitPath(Folder, &Leaf)
		}
		if (Leaf != AppDirsMigrationWindowsLegacyLocalFolder() || Folder = LegacyFolderNormalize(LegacyLocal))
				return ""
		return Folder
}

; The merge of a custom old-named logs folder: the logger wrote into its
; application-named subfolder, whose entries move to the renamed folder; the
; entries of the custom folder itself are the user's and stay.
; @param Custom {String} Folder from LegacyFolderCustomLegacyLogs.
; @param Backup {String} The migration backup folder of the root.
; @returns {Map} "from", "to" and "backup" folders.
LegacyFolderCustomLogsStep(Custom, Backup) {
		SplitPath(Custom, , &Parent)
		; The backup keeps the custom folder's path below it, its drive colon and
		; share prefix dropped.
		Below := RegExReplace(RegExReplace(Custom, "^\\+", ""), "^([A-Za-z]):", "$1")
		return Map("from", Custom . "\" . AppDirsFolderName(), "to", Parent . "\" . AppDirsFolderName(),
				"backup", Backup . "\custom-logs\" . Below . "\" . AppDirsFolderName())
}

; Rewrites the paths.toml lines whose value is an old default folder or a
; folder below one, reading quoted keys, literal strings and escapes as the
; boot TOML reader does. Mirrors rewrite_paths_text of
; _shared/settings/engine/migration/legacy_folder_migration_core.lua.
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
				Parts := LegacyFolderParseAssignment(Line)
				if !(Parts is Map) {
						Out .= Line
						continue
				}
				Replacement := Line
				for Rule in Rewrites {
						if (Rule["key"] !== Parts["key"])
								continue
						New := LegacyFolderRebased(Parts["value"], Rule)
						if (New == "")
								continue
						if (New !== Parts["value"]) {
								Replacement := Parts["indent"] . Parts["key_text"] . Parts["spacing"]
										. LegacyFolderSpellTomlString(New, Parts["kind"]) . Parts["rest"]
								Changed := true
						}
						break
				}
				Out .= Replacement
		}
		return Changed ? Out : ""
}

; Rewrites one paths.toml after keeping its previous text beside it. Mirrors
; rewrite_paths_file of _shared/settings/engine/migration/legacy_folder_migration_core.lua: both files are
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
								Moved := Map("key", Rule["key"], "old", Rule["old"], "new", Rule["new"], "under", Row["to"])
								if Rule.Has("renamed")
										Moved["renamed"] := Rule["renamed"]
								Settled.Push(Moved)
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
		; A transition the old build left beside its paths.toml is settled in
		; place before anything moves: its journal names the old locator and
		; folders, and once paths.toml left, boot recovery would only look beside
		; the new one. Quarantine throws, as it does at boot.
		if (FileExist(LegacyPaths) != "")
				ConfigTransitionRecoverAtBootOrThrow(LegacyPaths)
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
		; A custom logs folder named like the old application folder is renamed
		; after the new one, as on macOS and Linux (the shared « renamed » rule).
		Custom := ""
		if FileExist(PathsFile) {
				try Custom := LegacyFolderCustomLegacyLogs(
						LegacyFolderPathsValue(FSReadStrict(PathsFile), AppDirsLogsOverrideKey()), LegacyLocal)
		}
		if (Custom != "") {
				Step := LegacyFolderCustomLogsStep(Custom, Backup)
				LegacyFolderMergeEntries(Step["from"], Step["to"], Step["backup"], Report)
				Rules.Push(Map("key", AppDirsLogsOverrideKey(), "old", [],
						"renamed", Map("from", AppDirsMigrationWindowsLegacyLocalFolder(), "to", AppDirsFolderName()),
						"source", Step["from"]))
		}
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
		; The reason phrases of KEPT_REASONS in _shared/settings/engine/migration/legacy_folder_migration_core.lua.
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
