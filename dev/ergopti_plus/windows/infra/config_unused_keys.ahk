; infra/config_unused_keys.ahk

; ==============================================================================
; MODULE: Unused Configuration Keys
; DESCRIPTION:
; Lists the keys of config.toml that the boot loader reports as unknown and, on
; request, removes them after writing a byte-exact backup next to the file.
;
; FEATURES & RATIONALE:
; 1. One rule. A key is unused exactly when TomlConfigUnknownKind says so for
;    the manifest-built tree the boot loader applies the file onto. There is no
;    second schema here, so the list matches the "unknown leaf" and "unknown
;    section path" errors of the boot log. Sections the loader skips on purpose
;    (``[_*]`` metadata, ``[updater]``, the obsolete ``[ahk.*]`` silo) and the
;    dynamic personal namespaces are never offered for removal.
; 2. Backup before change. The removal holds the config.toml write lease, copies
;    the exact current bytes to a new, never-overwritten
;    ``<name>.backup-<timestamp>.<ext>`` file and reads that copy back before any
;    update reaches the writer. A backup failure aborts with the file untouched.
; 3. The rewrite is a batch of deletions through the ordinary atomic TOML
;    writer: every other key keeps its value, in the writer's canonical layout.
;    An unknown section emptied by the removal loses its header too.
; ==============================================================================

; The confirmation dialog lists at most this many keys; the rest are counted.
global CONFIG_UNUSED_KEYS_DISPLAY_LIMIT := 30





; ============================
; ============================
; ======= 1/ Detection =======
; ============================
; ============================

; Scans FilePath against SchemaTree (the manifest-built Features tree by
; default, the same tree boot applies the file onto). Returns a Map with
; "status" ("ok", "unreadable" or "malformed") and "keys", an Array of Maps
; carrying "section", "key", "kind" (TomlConfigUnknownKind's "section" or
; "leaf") and "value" (the value rendered as a TOML literal). A missing file is
; "ok" with no keys: there is nothing to clean.
ConfigUnusedKeysFind(FilePath, SchemaTree := unset) {
	Keys := []
	Tree := IsSet(SchemaTree) ? SchemaTree : ManifestBuildFeaturesMap()
	Sections := TOML_ParseFreshFileTyped(FilePath, &DiscardedArrays)
	if TOML_ReadFailed(FilePath)
		return Map("status", "unreadable", "keys", Keys)
	if DiscardedArrays
		return Map("status", "malformed", "keys", Keys)
	for SectionPath, Entries in Sections {
		if (SectionPath == "" || TomlConfigSectionSkipKind(SectionPath) != "")
			continue
		for Key, Value in Entries {
			Kind := TomlConfigUnknownKind(Tree, SectionPath, Key)
			if (Kind == "")
				continue
			Keys.Push(Map("section", SectionPath, "key", Key, "kind", Kind,
				"value", TOML_RenderValue(Value)))
		}
	}
	return Map("status", "ok", "keys", Keys)
}

; One "[section] key = value" line per key, capped at
; CONFIG_UNUSED_KEYS_DISPLAY_LIMIT with a localized count of the remainder.
ConfigUnusedKeysDescribe(Keys) {
	global CONFIG_UNUSED_KEYS_DISPLAY_LIMIT
	Lines := ""
	for Index, Entry in Keys {
		if (Index > CONFIG_UNUSED_KEYS_DISPLAY_LIMIT) {
			Lines .= "`n" . Format(t("dialog.unused_keys.more"),
				Keys.Length - CONFIG_UNUSED_KEYS_DISPLAY_LIMIT)
			break
		}
		Lines .= (Index > 1 ? "`n" : "") . "[" . Entry["section"] . "] "
			. TOML_RenderKey(Entry["key"]) . " = " . Entry["value"]
	}
	return Lines
}





; ==========================
; ==========================
; ======= 2/ Removal =======
; ==========================
; ==========================

; ``config.toml`` + "20260922-041500" -> ``config.backup-20260922-041500.toml``
; in the same directory, so the copy sits next to the file it protects.
ConfigUnusedKeysBackupPath(FilePath, Stamp) {
	SplitPath(FilePath, , &Dir, &Ext, &NameNoExt)
	return Dir . "\" . NameNoExt . ".backup-" . Stamp . (Ext != "" ? "." . Ext : "")
}

; Mirrors TOML_BatchWrite's ExactSectionPrefixes match, which compares without
; case: a prefix drops the section itself and every dotted child.
_ConfigUnusedKeysUnderSection(Name, Section) {
	return Name = Section || InStr(Name, Section . ".") == 1
}

; Unknown-path sections (kind "section") that the removal leaves without a
; single key, including every dotted child section. Coverage uses the writer's
; own case-insensitive match, so a known ``[layout]`` can never be dropped along
; with an unknown ``[Layout]``. A section that still holds a key outside Keys
; (added after the scan) keeps its header and that key.
_ConfigUnusedKeysEmptiedSections(FilePath, Keys) {
	Parsed := TOML_ParseFreshFileTyped(FilePath, &DiscardedArrays)
	if TOML_ReadFailed(FilePath) || DiscardedArrays
		throw Error("the configuration file could not be parsed for section cleanup")
	Listed := Map()
	Candidates := Map()
	for Entry in Keys {
		Listed[Entry["section"] . "`n" . Entry["key"]] := true
		if (Entry["kind"] == "section")
			Candidates[Entry["section"]] := true
	}
	Emptied := []
	for Section in Candidates {
		Covered := true
		for Name, Entries in Parsed {
			if !_ConfigUnusedKeysUnderSection(Name, Section)
				continue
			for Key in Entries {
				if !Listed.Has(Name . "`n" . Key) {
					Covered := false
					break
				}
			}
			if !Covered
				break
		}
		if Covered
			Emptied.Push(Section)
	}
	return Emptied
}

; Removes Keys (as returned by ConfigUnusedKeysFind) from FilePath. Returns a
; Map with "status" ("removed", "unreadable", "backup_failed" or
; "write_failed"), "backup" (the backup path) and "removed" (the key count).
; Only "removed" changes FilePath. BackupFn(Path, Content) and
; WriterFn(Path, Updates) are test seams for the backup creation and the TOML
; writer; both must return the Integer 1 on success.
ConfigUnusedKeysRemove(FilePath, Keys, Stamp := "", BackupFn := 0, WriterFn := 0) {
	if !(Keys is Array) || Keys.Length == 0
		throw ValueError("ConfigUnusedKeysRemove needs at least one key to remove")
	if (Stamp == "")
		Stamp := FormatTime(A_Now, "yyyyMMdd-HHmmss")
	BackupPath := ConfigUnusedKeysBackupPath(FilePath, Stamp)
	WriteBackup := HasMethod(BackupFn, "Call") ? BackupFn : FSWriteCreateDurable
	; Unknown sections whose every key is removed go away with their header
	; instead of lingering as empty ``[section]`` lines.
	DropSections := []
	Writer := HasMethod(WriterFn, "Call") ? WriterFn
		: (Path, Updates) => TOML_BatchWrite(Path, Updates, DropSections)
	Outcome := "write_failed"
	try LoggerStart("ConfigUnusedKeys", "Removing {1} unused key(s) from '{2}'…",
		Keys.Length, FilePath)

	; Runs under the write lease, so the backup holds exactly the bytes the
	; writer is about to replace. Throwing refuses the whole transaction.
	BuildPlan() {
		Source := FSReadUtf8Exact(FilePath)
		if !(Source is String) {
			Outcome := "unreadable"
			throw Error("the configuration file could not be read")
		}
		Written := WriteBackup.Call(BackupPath, Source)
		if !((Written is Integer) && Written == 1)
				|| !FSUtf8ExactMatches(BackupPath, Source) {
			Outcome := "backup_failed"
			throw Error("the backup '" . BackupPath . "' could not be written and verified")
		}
		for Section in _ConfigUnusedKeysEmptiedSections(FilePath, Keys)
			DropSections.Push(Section)
		; A key inside a dropped section needs no deletion of its own, and the
		; writer would recreate the section as an empty header to delete it.
		Updates := []
		for Entry in Keys {
			Dropped := false
			for Section in DropSections {
				if _ConfigUnusedKeysUnderSection(Entry["section"], Section) {
					Dropped := true
					break
				}
			}
			if !Dropped
				Updates.Push({ Section: Entry["section"], Key: Entry["key"], Delete: 1 })
		}
		Outcome := "write_failed"
		return { updates: Updates }
	}

	; The caller explains the outcome in its own dialog; the generic persistence
	; notification would say the same thing a second time.
	Committed := ConfigCommitBuilt(FilePath, "the unused configuration key cleanup",
		BuildPlan, Writer, (*) => 0)
	if Committed {
		Outcome := "removed"
		try LoggerSuccess("ConfigUnusedKeys",
			"Removed {1} unused key(s) from '{2}'; backup at '{3}'.",
			Keys.Length, FilePath, BackupPath)
	} else {
		try LoggerError("ConfigUnusedKeys",
			"Unused-key cleanup of '{1}' refused ({2}); the file was not changed.",
			FilePath, Outcome)
	}
	return Map("status", Outcome, "backup", BackupPath,
		"removed", Committed ? Keys.Length : 0)
}





; ==============================
; ==============================
; ======= 3/ Menu action =======
; ==============================
; ==============================

; Tray action: lists the unused keys of the live config.toml, asks before
; removing them, and reports the backup path or the reason nothing changed.
ShowUnusedConfigKeysCleanup(*) {
	global ConfigurationFile
	Title := t("dialog.unused_keys.title")
	try LoggerStart("ConfigUnusedKeys", "Checking '{1}' for unused keys…",
		ConfigurationFile)
	Scan := ConfigUnusedKeysFind(ConfigurationFile)
	if (Scan["status"] != "ok") {
		try LoggerError("ConfigUnusedKeys",
			"Unused-key check of '{1}' aborted: the file is {2}.",
			ConfigurationFile, Scan["status"])
		MsgBox(Format(t("dialog.unused_keys.failed"),
			t("dialog.unused_keys.reason.unreadable")), Title, "Iconx")
		return false
	}
	Keys := Scan["keys"]
	if (Keys.Length == 0) {
		try LoggerSuccess("ConfigUnusedKeys", "No unused keys in '{1}'.",
			ConfigurationFile)
		MsgBox(Format(t("dialog.unused_keys.none"), ConfigurationFile), Title,
			"Iconi")
		return true
	}
	Answer := MsgBox(Format(t("dialog.unused_keys.confirm"), Keys.Length,
		ConfigurationFile, ConfigUnusedKeysDescribe(Keys)), Title,
		"YesNo Icon? Default2")
	try LoggerSuccess("ConfigUnusedKeys",
		"Found {1} unused key(s) in '{2}'; removal {3}.", Keys.Length,
		ConfigurationFile, Answer == "Yes" ? "confirmed" : "declined")
	if (Answer != "Yes")
		return true

	Result := ConfigUnusedKeysRemove(ConfigurationFile, Keys)
	switch Result["status"] {
		case "removed":
			MsgBox(Format(t("dialog.unused_keys.done"), Result["removed"],
				Result["backup"]), Title, "Iconi")
			return true
		case "backup_failed":
			Reason := t("dialog.unused_keys.reason.backup")
		case "unreadable":
			Reason := t("dialog.unused_keys.reason.unreadable")
		default:
			Reason := t("dialog.unused_keys.reason.write")
	}
	MsgBox(Format(t("dialog.unused_keys.failed"), Reason), Title, "Iconx")
	return false
}
