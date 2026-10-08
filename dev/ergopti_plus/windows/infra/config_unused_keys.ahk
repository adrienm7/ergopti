; infra/config_unused_keys.ahk

; ==============================================================================
; MODULE: Unused Configuration Keys
; DESCRIPTION:
; Lists the keys of config.toml that the boot loader reports as unknown or
; outdated and, on request, removes them after writing a byte-exact backup next
; to the file.
;
; FEATURES & RATIONALE:
; 1. One rule. A key is unused exactly when TomlConfigUnknownKind says so for
;    the manifest-built tree the boot loader applies the file onto, and a known
;    key is outdated exactly when TomlConfigOutdatedReason says its value is no
;    longer accepted. There is no second schema here, so the list matches the
;    unused-key and outdated-value warnings at startup.
;    Reserved sections the loader skips on purpose (``[_*]`` metadata and
;    ``[updater]``) and dynamic personal namespaces are never offered for
;    removal. Retired ``[ahk]`` sections are offered only for explicit cleanup.
; 2. Backup before change. The removal holds the config.toml write lease, copies
;    the exact current bytes to a new, never-overwritten
;    ``<name>.backup-<timestamp>.<ext>`` file and reads that copy back before any
;    update reaches the writer. A backup failure aborts with the file untouched.
; 3. The rewrite is a batch of deletions through the ordinary atomic TOML
;    writer: every other source record keeps its exact physical spelling.
;    An unknown section emptied by the removal loses its header too.
; ==============================================================================

; Caps the legacy text formatter; the shared WebView displays every key.
global CONFIG_UNUSED_KEYS_DISPLAY_LIMIT := 30

#Include ../ui/config_cleanup/init.ahk





; ============================
; ============================
; ======= 1/ Detection =======
; ============================
; ============================

; Retired ownership is a semantic segment, never a case-folded textual prefix.
_ConfigUnusedKeysRetiredSection(Section) {
	Parts := TOML_ParseKeyPath(Section, true)
	return Parts.Length > 0 && Parts[1] == "ahk"
}

; A privately emitted root preview owns only its exact native record and source.
; Pointer identity avoids a global receipt registry or an entry/receipt cycle.
class _ConfigUnusedKeysRetiredRootReceipt {
	__New(Entry, Path, Source) {
		this.EntryId := ObjPtr(Entry)
		this.Path := Path
		this.Source := Source
		this.Section := Entry["section"]
		this.Key := Entry["key"]
		this.Kind := Entry["kind"]
		this.Value := Entry["value"]
		this.Consumed := false
	}

	Accepts(Entry, Path, Source) {
		if this.Consumed || !(Entry is Map) || ObjPtr(Entry) != this.EntryId
				|| Entry.Count != 5 || Entry.CaseSense != "On" || !(Path is String) || !(Source is String)
				|| StrCompare(Path, this.Path, true) != 0 || !(Source == this.Source)
			return false
		for Name in ["section", "key", "kind", "value"] {
			if !Entry.Has(Name) || !(Entry[Name] is String)
					|| StrCompare(Entry[Name], this.%Name%, true) != 0
				return false
		}
		return this.Section == "ahk" && this.Key == "" && this.Kind == "section"
			&& _ConfigUnusedKeysRetiredSection(this.Section)
			&& TomlConfigSectionSkipKind(this.Section) == "obsolete"
			&& Entry.Has("retired_root_receipt")
			&& (Entry["retired_root_receipt"] is _ConfigUnusedKeysRetiredRootReceipt)
			&& ObjPtr(Entry["retired_root_receipt"]) == ObjPtr(this)
	}
}

; The existing typed source decides when a flat row cannot identify the retired
; namespace. A whole-root preview never grants an individual table-array slot.
_ConfigUnusedKeysNeedsRetiredRoot(Document, Records, Physical, Sections := unset) {
	for Record in Records {
		if !(Record.Path[1] == "ahk")
			continue
		if Record.NativeSection == "" || !_ConfigUnusedKeysRetiredSection(Record.NativeSection)
				|| _ConfigTomlArrayMember(Document, Record.Path)
				|| !TOML_SameValue(_TOML_ConfigPath(Record.NativeSection, Record.Key), Record.Path)
			return true
		if IsSet(Sections) && (!Sections.Has(Record.NativeSection)
				|| !Sections[Record.NativeSection].Has(Record.Key)
				|| !TOML_SameValue(Sections[Record.NativeSection][Record.Key], Record.Value))
			return true
	}
	for Record in Physical {
		if Record.Kind != "header" || !_ConfigUnusedKeysRetiredSection(Record.Section)
			continue
		Actual := _TOML_DocumentLookup(Document, TOML_ParseKeyPath(Record.Section, true))
		if SubStr(Trim(Record.Text), 1, 2) == "[["
				|| !Actual["found"] || !(Actual["value"] is Map)
			return true
	}
	return false
}

; Scans FilePath against SchemaTree (the manifest-built Features tree by
; default, the same tree boot applies the file onto). Returns a Map with
; "status" ("ok", "unreadable", "malformed" or "unsupported") and "keys", an
; Array of Maps carrying "section", "key", "kind" and rendered "value". An
; empty retired physical table has a private section_only Integer 1 marker:
; its preview owns that whole semantic section, never an empty-name leaf.
; A missing file is "ok" with no keys. Unaddressable retired root projections
; use one private, source-bound whole-root preview. No scan writes or changes
; boot/session persistence authority.
ConfigUnusedKeysFind(FilePath, SchemaTree := unset) {
	Keys := []
	Tree := IsSet(SchemaTree) ? SchemaTree : ManifestBuildFeaturesMap()
	if !FileExist(FilePath)
		return Map("status", "ok", "keys", Keys)
	Source := FSReadUtf8Exact(FilePath)
	if !(Source is String)
		return Map("status", "unreadable", "keys", Keys)
	try Document := TOML_ParseDocument(Source, &Records, &Physical)
	catch as Err {
		try LoggerWarn("ConfigUnusedKeys", "Cleanup cannot admit '{1}': {2}.", FilePath, Err.Message)
		return Map("status", "malformed", "keys", Keys)
	}
	Sections := _ParseTomlFileImpl(FilePath, false, false, Source, true, &DiscardedArrays)
	if TOML_ReadFailed(FilePath)
		return Map("status", "unreadable", "keys", Keys)
	if DiscardedArrays
		return Map("status", "malformed", "keys", Keys)
	; Only this already-retired root can release an unrepresentable flat view.
	; The complete source stays private; the page receives descriptive fields.
	RootPreview := _ConfigUnusedKeysNeedsRetiredRoot(Document, Records, Physical, Sections)
	if RootPreview {
		if !Document.Has("ahk") || !_ConfigUnusedKeysRetiredSection("ahk")
				|| TomlConfigSectionSkipKind("ahk") != "obsolete"
			return Map("status", "unsupported", "keys", [])
		Entry := Map()
		Entry.CaseSense := "On"
		Entry.Set("section", "ahk", "key", "", "kind", "section",
			"value", TOML_RenderValue(Document["ahk"]))
		Entry["retired_root_receipt"] := _ConfigUnusedKeysRetiredRootReceipt(Entry, FilePath, Source)
		Keys.Push(Entry)
	}
	for SectionPath, Entries in Sections {
		if SectionPath == ""
			continue
		Retired := _ConfigUnusedKeysRetiredSection(SectionPath)
		if Retired && RootPreview
			continue
		if !Retired && TomlConfigSectionSkipKind(SectionPath) != ""
			continue
		if Retired {
			Actual := _TOML_DocumentLookup(Document, TOML_ParseKeyPath(SectionPath, true))
			if !Actual["found"] || !(Actual["value"] is Map)
				return Map("status", "unsupported", "keys", [])
			if Entries.Count == 0 {
				Keys.Push(Map("section", SectionPath, "key", "", "kind", "section",
					"value", "{}", "section_only", 1))
				continue
			}
		}
		for Key, Value in Entries {
			Kind := Retired ? "section"
				: TomlConfigUnknownKind(Tree, SectionPath, Key, &ForeignOwner)
			if (Kind == "") {
				Native := Value is TOML_Bool ? Value.Value : Value
				if (TomlConfigOutdatedReason(Tree, SectionPath, Key, Native,
						TOML_RenderValue(Value), ForeignOwner) == "")
					continue
				Kind := "leaf"
			}
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

; A section marker is a typed, native preview identity, not an empty key.
_ConfigUnusedKeysSectionOnly(Entry) {
	if !Entry.Has("section_only")
		return false
	Marker := Entry["section_only"]
	if !(Marker is Integer) || Marker != 1 || Entry["kind"] != "section"
			|| Entry["key"] != "" || !_ConfigUnusedKeysRetiredSection(Entry["section"])
		throw ValueError("An empty retired section needs its exact native preview marker")
	return true
}

; Mirrors the semantic writer's exact segment and case identity.
_ConfigUnusedKeysUnderSection(Name, Section) {
	return _TOML_ConfigPathUnder(TOML_ParseKeyPath(Name, true),
		TOML_ParseKeyPath(Section, true))
}

; A whole section is removable only when every actual semantic source record
; beneath it was offered. An added child or case/literal twin cannot borrow
; another preview entry's ownership. Table-array flat projections still refuse;
; only an exact private retired-root receipt can own their complete namespace.
_ConfigUnusedKeysEmptiedSections(FilePath, Keys, Source := unset) {
	if !IsSet(Source)
		Source := FSReadUtf8Exact(FilePath)
	if !(Source is String)
		throw Error("the configuration file could not be read for section cleanup")
	Document := TOML_ParseDocument(Source, &Records, &Physical)
	WholeRoots := Map()
	for Entry in Keys {
		if !Entry.Has("retired_root_receipt")
			continue
		Receipt := Entry["retired_root_receipt"]
		if !(Receipt is _ConfigUnusedKeysRetiredRootReceipt) || !Receipt.Accepts(Entry, FilePath, Source)
			throw ValueError("The retired root preview is not its exact privately captured generation")
		WholeRoots[Entry["section"]] := true
	}
	if _ConfigUnusedKeysNeedsRetiredRoot(Document, Records, Physical) && !WholeRoots.Has("ahk")
		throw ValueError("A flat cleanup preview cannot own the complete retired root")
	Listed := Map(), ListedHeaders := Map(), Candidates := Map()
	Listed.CaseSense := "On"
	ListedHeaders.CaseSense := "On"
	Candidates.CaseSense := "On"
	for Entry in Keys {
		if Entry.Has("retired_root_receipt") {
			Candidates[Entry["section"]] := true
			continue
		}
		if !_ConfigUnusedKeysSectionOnly(Entry)
			Listed[_TOML_ConfigPathName(_TOML_ConfigPath(Entry["section"], Entry["key"]))] := true
		if (Entry["kind"] == "section") {
			Candidates[Entry["section"]] := true
			ListedHeaders[_TOML_ConfigPathName(TOML_ParseKeyPath(Entry["section"], true))] := true
		}
	}
	Emptied := []
	for Section in Candidates {
		if WholeRoots.Has(Section) {
			Emptied.Push(Section)
			continue
		}
		Covered := true
		Parts := TOML_ParseKeyPath(Section, true)
		for Record in Records {
			if !_TOML_ConfigPathUnder(Record.Path, Parts)
				continue
			if _ConfigTomlArrayMember(Document, Record.Path)
				throw Error("the cleanup preview cannot own table-array generations")
			if !Listed.Has(_TOML_ConfigPathName(Record.Path)) {
				Covered := false
				break
			}
		}
		if Covered {
			; An empty child table has no assignment record. Its exact header
			; must also have been offered before an ancestor can own its removal.
			for Record in Physical {
				if Record.Kind != "header"
					continue
				HeaderParts := TOML_ParseKeyPath(Record.Section, true)
				if _TOML_ConfigPathUnder(HeaderParts, Parts)
						&& !ListedHeaders.Has(_TOML_ConfigPathName(HeaderParts)) {
					Covered := false
					break
				}
			}
		}
		if Covered
			Emptied.Push(Section)
	}
	return Emptied
}

; Removes Keys (as returned by ConfigUnusedKeysFind) from FilePath. Returns a
; Map with "status" ("removed", "changed", "unreadable", "backup_failed" or
; "write_failed"), "backup" (the backup path) and "removed" (the key count).
; Only "removed" changes FilePath. BackupFn(Path, Content) and
; WriterFn(Path, Updates) are test seams for the backup creation and the TOML
; writer; both must return the Integer 1 on success.
ConfigUnusedKeysRemove(FilePath, Keys, Stamp := "", BackupFn := 0, WriterFn := 0, ExpectedSource := unset) {
	if !(Keys is Array) || Keys.Length == 0
		throw ValueError("ConfigUnusedKeysRemove needs at least one key to remove")
	if (Stamp == "")
		Stamp := FormatTime(A_Now, "yyyyMMdd-HHmmss")
	BackupPath := ConfigUnusedKeysBackupPath(FilePath, Stamp)
	WriteBackup := HasMethod(BackupFn, "Call") ? BackupFn : FSWriteCreateDurable
	; Unknown sections whose every key is removed go away with their header
	; instead of lingering as empty ``[section]`` lines.
	DropSections := [], SourceImage := ""
	CapturedKeys := Keys.Clone()
	RootEntries := []
	for Entry in CapturedKeys {
		if Entry.Has("retired_root_receipt")
			RootEntries.Push(Entry)
	}
	ValidateRootReceipts(Source) {
		if RootEntries.Length > 1
			throw ValueError("The complete retired root preview may be selected only once")
		if RootEntries.Length {
			if Keys.Length != CapturedKeys.Length
				throw ValueError("The retired root preview collection changed before cleanup publication")
			loop CapturedKeys.Length {
				if !(Keys[A_Index] is Map) || ObjPtr(Keys[A_Index]) != ObjPtr(CapturedKeys[A_Index])
					throw ValueError("The retired root preview collection lost its captured native record")
			}
		}
		for Entry in RootEntries {
			if !Entry.Has("retired_root_receipt")
				throw ValueError("The retired root preview lost its private source receipt")
			Receipt := Entry["retired_root_receipt"]
			if !(Receipt is _ConfigUnusedKeysRetiredRootReceipt) || !Receipt.Accepts(Entry, FilePath, Source)
				throw ValueError("The retired root preview changed before cleanup publication")
		}
	}
	WriteUpdates(Path, Updates) {
		; The existing semantic owner validates the exact backed-up generation
		; again before publication, including a foreign change during backup.
		return _TOML_BatchWriteImpl(Path, Updates, DropSections, "write",
			SourceImage, 1, true)
	}
	Publish := HasMethod(WriterFn, "Call") ? WriterFn : WriteUpdates
	Writer(Path, Updates) {
		ValidateRootReceipts(SourceImage)
		return Publish.Call(Path, Updates)
	}
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
		if IsSet(ExpectedSource) && !(Source == ExpectedSource) {
			Outcome := "changed"
			return { noop: true }
		}
		SourceImage := Source
		ValidateRootReceipts(Source)
		for Section in _ConfigUnusedKeysEmptiedSections(FilePath, Keys, Source)
			DropSections.Push(Section)
		for Entry in Keys {
			if !_ConfigUnusedKeysSectionOnly(Entry)
				continue
			Covered := false
			for Section in DropSections {
				if _ConfigUnusedKeysUnderSection(Entry["section"], Section) {
					Covered := true
					break
				}
			}
			if !Covered {
				Outcome := "changed"
				return { noop: true }
			}
		}
		Written := WriteBackup.Call(BackupPath, Source)
		if !((Written is Integer) && Written == 1)
				|| !FSUtf8ExactMatches(BackupPath, Source) {
			Outcome := "backup_failed"
			throw Error("the backup '" . BackupPath . "' could not be written and verified")
		}
		ValidateRootReceipts(Source)
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
	if Committed && Outcome != "changed" {
		for Entry in RootEntries
			Entry["retired_root_receipt"].Consumed := true
		Outcome := "removed"
		try LoggerSuccess("ConfigUnusedKeys",
			"Removed {1} unused key(s) from '{2}'; backup at '{3}'.",
			Keys.Length, FilePath, BackupPath)
	} else if (Outcome == "changed") {
		try LoggerWarn("ConfigUnusedKeys", "Cleanup deferred: '{1}' changed after the preview was opened.", FilePath)
	} else {
		try LoggerError("ConfigUnusedKeys",
			"Unused-key cleanup of '{1}' refused ({2}); the file was not changed.",
			FilePath, Outcome)
	}
	return Map("status", Outcome, "backup", BackupPath,
		"removed", Outcome == "removed" ? Keys.Length : 0)
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
	return ConfigUnusedKeysShow(ConfigurationFile)
}

/**
 * Offers the cleanup tool after startup only when a fresh scan finds unused keys.
 * @param {String} FilePath - The configuration file applied during startup.
 * @param {Func} ScanFn - Fresh unused-key collector.
 * @param {Func} ShowFn - Existing interactive cleanup workflow.
 * @returns {Boolean} Whether the cleanup workflow was offered.
 */
ConfigUnusedKeysOffer(FilePath, ScanFn := ConfigUnusedKeysFind, ShowFn := ConfigUnusedKeysShow) {
	Scan := ScanFn.Call(FilePath)
	if (Scan["status"] != "ok" || Scan["keys"].Length == 0)
		return false
	ShowFn.Call(FilePath)
	return true
}

/**
 * Opens the shared, scrollable preview for one configuration file.
 * @param {String} ConfigurationFile - The exact file inspected by the caller.
 * @returns {Boolean} Whether the preview opened.
 */
ConfigUnusedKeysShow(ConfigurationFile) {
	return ConfigCleanupWindow.Open(ConfigurationFile)
}
