; modules/gestures/touchpad_registry.ahk

; ==============================================================================
; MODULE: Precision Touchpad Registry Owner
; DESCRIPTION:
; The one owner of Ergopti's writes to the Windows Precision Touchpad registry
; key. Before the first write it backs up the prior value of every name it is
; about to write; it applies the generated value table; it gives the first-run
; wizard's elevated PowerShell script the same table; and it restores the
; backup on request (Configuration > « Restaurer les gestes du pavé tactile
; Windows »).
;
; FEATURES & RATIONALE:
; 1. One source: _generated/touchpad_registry.ahk, generated from
;    precision_touchpad_registry.toml, is the only list of names and values.
;    Neither writer spells a value name or a number of its own.
; 2. Backup before the first write: the backup file is created with
;    CREATE_NEW, so a later configuration can never replace the user's own
;    values with Ergopti's. An unreadable key or a value of an unexpected type
;    refuses the write instead of guessing what to restore.
; 3. Exact restore: a value that was absent is deleted, a DWORD rewritten. The
;    backup is removed only once every value was restored, so a failed restore
;    can be retried and the next configuration backs up the values then current.
; 4. Functions only, no top-level state: the first-run wizard calls this owner
;    before modules/gestures/init.ahk runs, when a top-level global of this
;    file would still be unset. Every I/O boundary is injectable so the unit
;    suite proves the ordering without touching the real registry.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Registry and Backup =======
; ======================================
; ======================================

; The logger tag of every touchpad registry line.
; @return {String}
TouchpadRegistryLogTag() {
	return "gestures.touchpad"
}

; The first line of a backup file; a different line is refused, never guessed.
; @return {String}
TouchpadRegistryBackupHeader() {
	return "ergopti-touchpad-registry-backup 1"
}

; Where the backup of the user's own values lives, beside the driver config.
; @return {String} Absolute backup path.
TouchpadRegistryBackupPath() {
	global _ConfigDir, _AhkSubDir
	return _ConfigDir . _AhkSubDir . "touchpad_registry_backup.txt"
}

; Strictly probes a HKEY_CURRENT_USER key: only "not found" means absent. The
; native probe goes through the SystemControl adapter so this module adds no
; direct OS call to the purity ratchet.
; @param Key {String} Full key path under HKEY_CURRENT_USER.
; @return {Boolean} True when the key exists; throws on any other failure.
_TouchpadRegistryKeyExists(Key) {
	static ROOT := "HKEY_CURRENT_USER\"
	if (SubStr(Key, 1, StrLen(ROOT)) != ROOT)
		throw ValueError("The touchpad key must live under " . ROOT)
	return SystemControl().CurrentUserKeyExists(SubStr(Key, StrLen(ROOT) + 1))
}

; Reads the current value of each of the given names, with its registry type.
; Registry names are case-insensitive, so the match is too; results are keyed
; by the canonical spelling the caller passed.
; @param Key {String} Registry key path.
; @param Names {Array} Value names to read.
; @return {Map} name => Map("type", <REG_* type>, "value", <DWORD or "">).
TouchpadRegistrySnapshot(Key, Names) {
	Wanted := Map()
	Wanted.CaseSense := "Off"
	for _, Name in Names
		Wanted[Name] := Name
	Values := Map()
	if !_TouchpadRegistryKeyExists(Key)
		return Values
	Loop Reg, Key, "V" {
		if Wanted.Has(A_LoopRegName)
			Values[Wanted[A_LoopRegName]] := Map("type", A_LoopRegType,
				"value", A_LoopRegType == "REG_DWORD" ? RegRead() : "")
	}
	return Values
}

; Builds the backup text of the values Ergopti is about to overwrite.
; @param Data {Map} TouchpadRegistryData().
; @param Snapshot {Map} TouchpadRegistrySnapshot() of the key.
; @return {String} Backup content; throws on a value that is not a DWORD.
_TouchpadRegistryBackupText(Data, Snapshot) {
	Text := TouchpadRegistryBackupHeader() . "`n" . "key " . Data["key"] . "`n"
	for _, Entry in Data["values"] {
		Name := Entry["name"]
		if !Snapshot.Has(Name) {
			Text .= Name . " absent`n"
			continue
		}
		Current := Snapshot[Name]
		if (Current["type"] != "REG_DWORD")
			throw ValueError("Touchpad value " . Name . " is a " . Current["type"]
				. ", not a REG_DWORD, so it could not be restored faithfully.")
		Text .= Name . " dword " . Integer(Current["value"]) . "`n"
	}
	return Text
}

; The value names Ergopti writes, in write order.
; @param Data {Map} TouchpadRegistryData().
; @return {Array}
_TouchpadRegistryNames(Data) {
	Names := []
	for _, Entry in Data["values"]
		Names.Push(Entry["name"])
	return Names
}

; Backs up the prior value of every name Ergopti writes, once: an existing
; backup is the user's own values from before the first write and is kept.
; @param SnapshotFn {Func|0} Reads the key, fn(Key, Names) (TouchpadRegistrySnapshot).
; @param CreateFn {Func|0} Create-only durable writer (FSWriteCreateDurable).
; @param ExistsFn {Func|0} Strict existence probe (FSStrictExists).
; @param BackupPath {String} Backup file; empty selects TouchpadRegistryBackupPath().
; @return {Boolean} True when a backup exists afterwards; false blocks every write.
TouchpadRegistryEnsureBackup(SnapshotFn := 0, CreateFn := 0, ExistsFn := 0, BackupPath := "") {
	Tag := TouchpadRegistryLogTag()
	Path := BackupPath != "" ? BackupPath : TouchpadRegistryBackupPath()
	Snapshot := HasMethod(SnapshotFn, "Call") ? SnapshotFn : TouchpadRegistrySnapshot
	Create := HasMethod(CreateFn, "Call") ? CreateFn : FSWriteCreateDurable
	Exists := HasMethod(ExistsFn, "Call") ? ExistsFn : FSStrictExists
	try {
		if Exists.Call(Path) {
			LoggerDebug(Tag, "Keeping the touchpad backup of the values from before Ergopti's first write.")
			return true
		}
		Data := TouchpadRegistryData()
		Text := _TouchpadRegistryBackupText(Data, Snapshot.Call(Data["key"], _TouchpadRegistryNames(Data)))
		SplitPath(Path, , &Directory)
		FSEnsureDirectoryStrict(Directory)
		if (Create.Call(Path, Text) != 1) {
			; A concurrent owner may have created it between the probe and the create
			if Exists.Call(Path)
				return true
			LoggerError(Tag, "The touchpad backup '{1}' could not be created.", Path)
			return false
		}
		LoggerInfo(Tag, "Backed up {1} touchpad value(s) to '{2}' before the first write.",
			Data["values"].Length, Path)
		return true
	} catch as Err {
		LoggerError(Tag, "The touchpad values could not be backed up: {1}.", Err.Message)
		return false
	}
}





; ==============================
; ==============================
; ======= 2/ The Writers =======
; ==============================
; ==============================

; Writes every generated value, after the backup. Used by the tray action and
; the deferred first-boot configuration; the wizard's elevated script reads
; the same table through TouchpadRegistryPowerShellValues().
; @param WriteFn {Func|0} DWORD writer, fn(Key, Name, Value) (Reg_WriteDword).
; @param SnapshotFn, CreateFn, ExistsFn, BackupPath: forwarded to the backup.
; @return {Boolean} True only when the backup exists and every value was written.
TouchpadRegistryApply(WriteFn := 0, SnapshotFn := 0, CreateFn := 0, ExistsFn := 0, BackupPath := "") {
	Tag := TouchpadRegistryLogTag()
	LoggerStart(Tag, "Writing the Precision Touchpad gesture values…")
	if !TouchpadRegistryEnsureBackup(SnapshotFn, CreateFn, ExistsFn, BackupPath) {
		LoggerError(Tag, "No touchpad value was written: the prior values are not backed up.")
		return false
	}
	Write := HasMethod(WriteFn, "Call") ? WriteFn : Reg_WriteDword
	Data := TouchpadRegistryData()
	Failed := 0
	for _, Entry in Data["values"] {
		if !Write.Call(Data["key"], Entry["name"], Entry["value"])
			Failed += 1
	}
	if Failed {
		LoggerError(Tag, "{1} of {2} touchpad value(s) could not be written.",
			Failed, Data["values"].Length)
		return false
	}
	LoggerSuccess(Tag, "{1} touchpad value(s) written.", Data["values"].Length)
	return true
}

; The registry key in PowerShell drive syntax, for the wizard's elevated script.
; @return {String}
TouchpadRegistryPowerShellKey() {
	return TouchpadRegistryData()["powershell_key"]
}

; The body of the wizard script's value hashtable: one "  'Name' = value" line
; per generated value, CRLF-terminated. Value names are plain identifiers
; (validated by the generator), so no quoting is needed.
; @return {String}
TouchpadRegistryPowerShellValues() {
	Lines := ""
	for _, Entry in TouchpadRegistryData()["values"]
		Lines .= "  '" . Entry["name"] . "' = " . Entry["value"] . "`r`n"
	return Lines
}





; ==============================
; ==============================
; ======= 3/ The Restore =======
; ==============================
; ==============================

; Parses a backup file against the current generated table.
; @param Text {String} Backup content.
; @param Data {Map} TouchpadRegistryData().
; @return {Array} Maps ("name", "absent", "value") in write order; throws when invalid.
_TouchpadRegistryParseBackup(Text, Data) {
	Lines := StrSplit(RTrim(StrReplace(Text, "`r", ""), "`n"), "`n")
	if (Lines.Length < 2 || Lines[1] != TouchpadRegistryBackupHeader())
		throw ValueError("the backup header is not " . TouchpadRegistryBackupHeader())
	if (Lines[2] != "key " . Data["key"])
		throw ValueError("the backup names another registry key")
	Recorded := Map()
	Index := 3
	while (Index <= Lines.Length) {
		Parts := StrSplit(Lines[Index], " ")
		if (Parts.Length == 2 && Parts[2] == "absent")
			Entry := Map("name", Parts[1], "absent", true, "value", 0)
		else if (Parts.Length == 3 && Parts[2] == "dword" && RegExMatch(Parts[3], "^\d{1,10}$")
				&& Integer(Parts[3]) <= 0xFFFFFFFF)
			Entry := Map("name", Parts[1], "absent", false, "value", Integer(Parts[3]))
		else
			throw ValueError("malformed backup line " . Index)
		if Recorded.Has(Entry["name"])
			throw ValueError("the backup records " . Entry["name"] . " twice")
		Recorded[Entry["name"]] := Entry
		Index += 1
	}
	Ordered := []
	for _, Value in Data["values"] {
		if !Recorded.Has(Value["name"])
			throw ValueError("the backup does not record " . Value["name"])
		Ordered.Push(Recorded.Delete(Value["name"]))
	}
	for Name in Recorded
		throw ValueError("the backup records " . Name . ", which Ergopti never writes")
	return Ordered
}

; Restores the values backed up before Ergopti's first write, removes the
; backup, then restarts the touchpad so its driver reloads them.
; @param OnDone {Func|0} Touchpad-restart completion, fn(Ok).
; @param Io {Map|0} Test seams, each optional: exists, read, write,
;   delete_value, delete_file, restart, backup_path.
; @return {String} "restored", "no_backup" or "failed".
TouchpadRegistryRestore(OnDone := 0, Io := 0) {
	Tag := TouchpadRegistryLogTag()
	Seams := Io is Map ? Io : Map()
	Path := Seams.Get("backup_path", "") != "" ? Seams["backup_path"] : TouchpadRegistryBackupPath()
	Exists := Seams.Get("exists", FSStrictExists)
	Read := Seams.Get("read", FSReadStrict)
	Write := Seams.Get("write", Reg_WriteDword)
	DeleteValue := Seams.Get("delete_value", Reg_DeleteValue)
	DeleteFile := Seams.Get("delete_file", FSDelete)
	Restart := Seams.Get("restart", GestureRestartTouchpadDevice)
	LoggerStart(Tag, "Restoring the Windows touchpad gestures…")
	try {
		if !Exists.Call(Path) {
			LoggerSuccess(Tag, "No touchpad backup: Ergopti never changed these settings.")
			return "no_backup"
		}
		Data := TouchpadRegistryData()
		Entries := _TouchpadRegistryParseBackup(Read.Call(Path), Data)
	} catch as Err {
		LoggerError(Tag, "The touchpad backup could not be read: {1}. Nothing was changed.", Err.Message)
		return "failed"
	}
	Failed := 0
	for _, Entry in Entries {
		Ok := Entry["absent"]
			? DeleteValue.Call(Data["key"], Entry["name"])
			: Write.Call(Data["key"], Entry["name"], Entry["value"])
		if !Ok
			Failed += 1
	}
	if Failed {
		LoggerError(Tag, "{1} of {2} touchpad value(s) could not be restored; the backup is kept for a retry.",
			Failed, Entries.Length)
		return "failed"
	}
	if !DeleteFile.Call(Path) {
		LoggerError(Tag, "The touchpad values were restored but the backup '{1}' could not be removed.", Path)
		return "failed"
	}
	; The driver caches its gesture map: without the PnP restart the restored
	; values only take effect at the next sign-in.
	if !Restart.Call(OnDone)
		LoggerError(Tag, "The touchpad values were restored but the touchpad could not be restarted; they apply at the next sign-in.")
	LoggerSuccess(Tag, "{1} touchpad value(s) restored.", Entries.Length)
	return "restored"
}

; Configuration > « Restaurer les gestes du pavé tactile Windows ». A failure
; is already an ERROR, which the shared error UI surfaces.
; @return {Boolean} True when the values were restored.
TouchpadRegistryRestoreFromMenu(*) {
	if A_IsSuspended {
		LoggerWarn(TouchpadRegistryLogTag(), "Ignoring the touchpad restore while suspended.")
		return false
	}
	Result := TouchpadRegistryRestore()
	if (Result == "no_backup") {
		NotifierSend(t("notify.touchpad.no_backup"), Map("level", "info"))
		return false
	}
	if (Result != "restored")
		return false
	NotifierSend(t("notify.touchpad.restored"), Map("level", "success"))
	; The Ergopti slots are no longer configured: refresh the gesture status rows
	GestureSystemRequestRefresh()
	return true
}
