; modules/updater/config_backup.ahk

; ==============================================================================
; MODULE: Updater / Configuration Backup
; DESCRIPTION:
; The Windows port of _shared/lua/updater/config_backup.lua: the timestamped
; backup of the whole user configuration that a release install from the
; Versions window makes before anything is downloaded, and the restore of such
; a backup. The rules (which files, where, what name) are the config_backup
; block of _shared/modules/updater/defaults.json, read at run time.
;
; FEATURES & RATIONALE:
; 1. The whole configuration: every file of the configuration folder whose
;    extension the rules list (config.toml, the tap-hold and layer files, the
;    personal hotstrings and shortcuts, the JSON settings), in every subfolder
;    but the excluded top-level ones (the backups themselves, the metrics
;    data). A reparse point (link, junction) is never walked.
; 2. Verified and complete, or nothing: every copy is created byte for byte and
;    compared with its source; the manifest is written last, create-only, so a
;    folder without one is an interrupted backup that is never restored.
; 3. Restore backs up first: the configuration it replaces becomes a
;    pre-restore backup, then every copy is checked present before the first
;    file is written back, each through an atomic replace.
; 4. Paths are relative to the configuration folder, never absolute, and a
;    manifest path that climbs out of it is refused.
; ==============================================================================

global CONFIG_BACKUP_SCHEMA_VERSION := 1





; ==================================
; ==================================
; ======= 1/ Rules and Paths =======
; ==================================
; ==================================

; Reads and validates the config_backup block of the shared updater defaults.
; @param Defaults {Map|Integer} Decoded defaults.json; read from the shared tree when 0.
; @returns {Map} folder, manifest, kinds (Map), extensions (Array), excluded (Map).
; @throws {Error} When the block is missing or invalid.
ConfigBackup_Rules(Defaults := 0) {
	global _SharedDir
	if !IsObject(Defaults)
		Defaults := JsonParse(FSReadStrict(_SharedDir . "\modules\updater\defaults.json"))
	if !(Defaults is Map) || !Defaults.Has("config_backup") || !(Defaults["config_backup"] is Map)
		throw Error("updater defaults declare no config_backup block")
	Block := Defaults["config_backup"]
	for _, Key in ["folder", "manifest"] {
		if !Block.Has(Key) || !_ConfigBackup_IsName(Block[Key])
			throw Error("config_backup needs a folder and a manifest name")
	}
	Kinds := Block.Has("kinds") ? Block["kinds"] : 0
	if !(Kinds is Map) || !Kinds.Has("pre_install") || !Kinds.Has("pre_restore")
			|| !_ConfigBackup_IsName(Kinds["pre_install"]) || !_ConfigBackup_IsName(Kinds["pre_restore"])
			|| Kinds["pre_install"] == Kinds["pre_restore"]
		throw Error("config_backup needs two distinct kind prefixes")
	Extensions := []
	if !Block.Has("include_extensions") || !(Block["include_extensions"] is Array)
			|| Block["include_extensions"].Length == 0
		throw Error("config_backup lists no extension")
	for _, Extension in Block["include_extensions"] {
		if !(Extension is String) || !RegExMatch(Extension, "^\.[A-Za-z0-9]+$")
			throw Error("config_backup has an invalid extension")
		Extensions.Push(StrLower(Extension))
	}
	Excluded := Map()
	Excluded.CaseSense := "Off"
	if Block.Has("exclude_dirs") && Block["exclude_dirs"] is Array {
		for _, Dir in Block["exclude_dirs"] {
			if !_ConfigBackup_IsName(Dir)
				throw Error("config_backup has an invalid excluded folder")
			Excluded[Dir] := true
		}
	}
	; Backing the backups up would copy every earlier backup into each new one.
	if !Excluded.Has(Block["folder"])
		throw Error("config_backup must exclude its own folder")
	return Map("folder", Block["folder"], "manifest", Block["manifest"],
		"kinds", Map("pre_install", Kinds["pre_install"], "pre_restore", Kinds["pre_restore"]),
		"extensions", Extensions, "excluded", Excluded)
}

_ConfigBackup_IsName(Value) {
	return (Value is String) && Value != "" && Value != "." && Value != ".."
		&& !InStr(Value, "/") && !InStr(Value, "\")
}

; Whether a manifest path stays inside the configuration folder: relative,
; "/"-separated, with no empty, "." or ".." segment and no drive or stream.
; @param Relative {String}
; @returns {Boolean}
ConfigBackup_IsContained(Relative) {
	if !(Relative is String) || Relative == "" || SubStr(Relative, 1, 1) == "/"
			|| InStr(Relative, "\") || InStr(Relative, ":")
		return false
	for _, Segment in StrSplit(Relative, "/") {
		if (Segment == "" || Segment == "." || Segment == "..")
			return false
	}
	return true
}

_ConfigBackup_Join(Dir, Relative) {
	return RTrim(Dir, "\/") . "\" . StrReplace(Relative, "/", "\")
}

_ConfigBackup_Included(Rules, Name) {
	Lower := StrLower(Name)
	for _, Extension in Rules["extensions"] {
		if (StrLen(Lower) > StrLen(Extension) && SubStr(Lower, -StrLen(Extension)) == Extension)
			return true
	}
	return false
}

; Wall-clock time of a backup, in UTC.
; @returns {Map} stamp "YYYYMMDD-HHMMSS", iso "YYYY-MM-DDTHH:MM:SSZ".
ConfigBackup_Clock() {
	Now := A_NowUTC
	return Map("stamp", FormatTime(Now, "yyyyMMdd") . "-" . FormatTime(Now, "HHmmss"),
		"iso", FormatTime(Now, "yyyy-MM-dd") . "T" . FormatTime(Now, "HH:mm:ss") . "Z")
}





; =========================
; =========================
; ======= 2/ Backup =======
; =========================
; =========================

; Collects the configuration files the rules include, as "/"-separated paths
; relative to the folder.
; @returns {Array}
_ConfigBackup_Walk(ConfigDir, Rules) {
	Files := []
	Pending := [""]
	while (Pending.Length > 0) {
		Relative := Pending.RemoveAt(1)
		Dir := (Relative == "") ? RTrim(ConfigDir, "\/") : _ConfigBackup_Join(ConfigDir, Relative)
		for _, Path in FSListDirectoryStrict(Dir, true) {
			SplitPath(Path, &Name)
			if FSIsReparsePoint(Path) {
				try LoggerWarn("ConfigBackup", "Backup skips '{1}': a link is never walked.", Path)
				continue
			}
			if (Relative == "" && Rules["excluded"].Has(Name))
				continue
			Pending.Push(Relative == "" ? Name : Relative . "/" . Name)
		}
		for _, Path in FSListDirectoryStrict(Dir, false) {
			SplitPath(Path, &Name)
			if _ConfigBackup_Included(Rules, Name)
				Files.Push(Relative == "" ? Name : Relative . "/" . Name)
		}
	}
	return Files
}

; Makes one backup of the whole configuration.
; @param ConfigDir {String} The configuration folder.
; @param Kind {String} "pre_install" or "pre_restore".
; @param Tag {String} Release installed after the backup ("" for a restore).
; @param FromVersion {String} The running build.
; @param Rules {Map|Integer} ConfigBackup_Rules() result, read when 0.
; @param ClockFn {Func|Integer} Test seam replacing ConfigBackup_Clock.
; @returns {Map} id, path, kind, created_at, tag, from_version, files.
; @throws {Error} When any file cannot be read or copied: nothing is complete.
ConfigBackup_Create(ConfigDir, Kind, Tag := "", FromVersion := "", Rules := 0, ClockFn := 0) {
	if !IsObject(Rules)
		Rules := ConfigBackup_Rules()
	if !Rules["kinds"].Has(Kind)
		throw ValueError("Unknown configuration backup kind '" . Kind . "'.")
	try LoggerStart("ConfigBackup", "Backing up the configuration ({1})…", Kind)
	Time := IsObject(ClockFn) ? ClockFn.Call() : ConfigBackup_Clock()
	Files := _ConfigBackup_Walk(ConfigDir, Rules)
	Folder := _ConfigBackup_Join(ConfigDir, Rules["folder"])
	FSEnsureDirectoryStrict(Folder)
	Id := Rules["kinds"][Kind] . "-" . Time["stamp"]
	SafeTag := RegExReplace(Tag, "[^A-Za-z0-9._-]")
	if (SafeTag != "")
		Id .= "-" . SafeTag
	; Two backups within one second get distinct folders.
	Base := Id
	Suffix := 1
	while FSExists(Folder . "\" . Id) {
		Suffix += 1
		Id := Base . "-" . Suffix
	}
	BackupPath := Folder . "\" . Id
	FSEnsureDirectoryStrict(BackupPath)
	FilesJson := []
	for _, Relative in Files {
		Copy := _ConfigBackup_Join(BackupPath, "config/" . Relative)
		SplitPath(Copy, , &CopyDir)
		FSEnsureDirectoryStrict(CopyDir)
		if !FSCopyCreateVerified(_ConfigBackup_Join(ConfigDir, Relative), Copy)
			throw Error("Configuration backup failed copying '" . Relative . "' to '" . Copy . "'.")
		FilesJson.Push('{"root":"config","path":' . JsonStringLiteral(Relative) . "}")
	}
	Manifest := "{"
		. '"schema_version":' . CONFIG_BACKUP_SCHEMA_VERSION
		. ',"id":' . JsonStringLiteral(Id)
		. ',"kind":' . JsonStringLiteral(Kind)
		. ',"created_at":' . JsonStringLiteral(Time["iso"])
		. ',"tag":' . JsonStringLiteral(Tag)
		. ',"from_version":' . JsonStringLiteral(FromVersion)
		. ',"files":[' . _ConfigBackup_JoinArray(FilesJson) . "]}"
	if !FSWriteCreateDurable(BackupPath . "\" . Rules["manifest"], Manifest)
		throw Error("Configuration backup failed writing its manifest in '" . BackupPath . "'.")
	try LoggerSuccess("ConfigBackup", "Configuration backed up to {1} ({2} file(s)).", BackupPath, Files.Length)
	return Map("id", Id, "path", BackupPath, "kind", Kind, "created_at", Time["iso"], "tag", Tag,
		"from_version", FromVersion, "files", Files)
}

_ConfigBackup_JoinArray(Items) {
	Text := ""
	for Index, Item in Items
		Text .= (Index > 1 ? "," : "") . Item
	return Text
}





; =====================================
; =====================================
; ======= 3/ Latest and Restore =======
; =====================================
; =====================================

; Reads and validates one backup's manifest.
; @returns {Map|Integer} The record, or 0 when the backup is incomplete or invalid.
_ConfigBackup_Load(ConfigDir, Id, Rules) {
	if !(Id is String) || !ConfigBackup_IsContained(Id) || InStr(Id, "/")
		return 0
	BackupPath := _ConfigBackup_Join(ConfigDir, Rules["folder"] . "/" . Id)
	ManifestPath := BackupPath . "\" . Rules["manifest"]
	if !FSExists(ManifestPath)
		return 0
	try Record := JsonParse(FSReadStrict(ManifestPath))
	catch
		return 0
	if !(Record is Map) || !Record.Has("schema_version") || Record["schema_version"] != CONFIG_BACKUP_SCHEMA_VERSION
			|| !Record.Has("id") || Record["id"] != Id || !Record.Has("kind") || !Rules["kinds"].Has(Record["kind"])
			|| !Record.Has("files") || !(Record["files"] is Array)
		return 0
	Files := []
	for _, File in Record["files"] {
		if !(File is Map) || !File.Has("root") || File["root"] != "config" || !File.Has("path")
				|| !ConfigBackup_IsContained(File["path"])
			return 0
		Files.Push(File["path"])
	}
	return Map("id", Id, "path", BackupPath, "kind", Record["kind"],
		"created_at", Record.Has("created_at") ? Record["created_at"] : "",
		"tag", Record.Has("tag") ? Record["tag"] : "",
		"from_version", Record.Has("from_version") ? Record["from_version"] : "",
		"files", Files)
}

; The newest complete backup of one kind.
; @returns {Map|Integer} The record, or 0 when there is none.
ConfigBackup_Latest(ConfigDir, Kind, Rules := 0) {
	if !IsObject(Rules)
		Rules := ConfigBackup_Rules()
	Folder := _ConfigBackup_Join(ConfigDir, Rules["folder"])
	Prefix := Rules["kinds"][Kind] . "-"
	Best := 0
	for _, Path in FSListDirectoryStrict(Folder, true) {
		SplitPath(Path, &Name)
		if (SubStr(Name, 1, StrLen(Prefix)) != Prefix)
			continue
		Record := _ConfigBackup_Load(ConfigDir, Name, Rules)
		if !IsObject(Record) || Record["kind"] != Kind
			continue
		if !IsObject(Best) || StrCompare(Record["created_at"], Best["created_at"]) > 0
				|| (Record["created_at"] == Best["created_at"] && StrCompare(Record["id"], Best["id"]) > 0)
			Best := Record
	}
	return Best
}

; Puts a backup back: backs the current configuration up first, checks every
; copy is present, then replaces each file atomically.
; @returns {Map} ok (Boolean), reason ("missing", "backup", "write" or ""),
;   pre (the pre-restore record, or 0).
ConfigBackup_Restore(ConfigDir, Id, Rules := 0, ClockFn := 0) {
	if !IsObject(Rules)
		Rules := ConfigBackup_Rules()
	try LoggerStart("ConfigBackup", "Restoring the configuration backup {1}…", Id)
	Record := _ConfigBackup_Load(ConfigDir, Id, Rules)
	if !IsObject(Record) {
		try LoggerError("ConfigBackup", "Restore refused: backup '{1}' is incomplete or invalid.", Id)
		return Map("ok", false, "reason", "missing", "pre", 0)
	}
	for _, Relative in Record["files"] {
		if !FSExists(_ConfigBackup_Join(Record["path"], "config/" . Relative)) {
			try LoggerError("ConfigBackup", "Restore refused: '{1}' is missing from the backup.", Relative)
			return Map("ok", false, "reason", "missing", "pre", 0)
		}
	}
	try Pre := ConfigBackup_Create(ConfigDir, "pre_restore", "", Record["from_version"], Rules, ClockFn)
	catch as Err {
		try LoggerError("ConfigBackup", "Restore refused: the current configuration could not be backed up ({1}).", Err.Message)
		return Map("ok", false, "reason", "backup", "pre", 0)
	}
	for _, Relative in Record["files"] {
		Target := _ConfigBackup_Join(ConfigDir, Relative)
		SplitPath(Target, , &TargetDir)
		try FSEnsureDirectoryStrict(TargetDir)
		catch as Err {
			try LoggerError("ConfigBackup", "Restore failed creating '{1}': {2}; the replaced configuration is in {3}.",
				TargetDir, Err.Message, Pre["path"])
			return Map("ok", false, "reason", "write", "pre", Pre)
		}
		if !FSCopyReplaceAtomic(_ConfigBackup_Join(Record["path"], "config/" . Relative), Target) {
			try LoggerError("ConfigBackup", "Restore failed writing '{1}'; the replaced configuration is in {2}.",
				Target, Pre["path"])
			return Map("ok", false, "reason", "write", "pre", Pre)
		}
	}
	try LoggerSuccess("ConfigBackup", "Configuration restored from {1} ({2} file(s)).", Record["path"], Record["files"].Length)
	return Map("ok", true, "reason", "", "pre", Pre)
}
