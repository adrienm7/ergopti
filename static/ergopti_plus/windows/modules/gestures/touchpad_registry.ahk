; modules/gestures/touchpad_registry.ahk

; ==============================================================================
; MODULE: Precision Touchpad Registry Owner
; DESCRIPTION:
; The one owner of Ergopti's writes to the Windows Precision Touchpad registry
; key. Before the first write it backs up the prior value of every name it is
; about to write; it applies the generated value table, in the resident
; process for the tray action and the first-run wizard alike; and the Gestures
; and global « Tout effacer » restore the backup, or the Windows factory
; defaults when there is none.
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
;    Without a backup the generated factory_defaults are written instead, and
;    every other name Ergopti writes is deleted; the log says which path ran.
; 4. Functions only, no top-level state: the first-run wizard calls this owner
;    before modules/gestures/init.ahk runs, when a top-level global of this
;    file would still be unset. Every I/O boundary is injectable so the unit
;    suite proves the ordering without touching the real registry.
; 5. An isolated profile never reaches the machine: a startup smoke or a live
;    check boots beside the user's own driver and shares the signed-in user's
;    HKCU, so its key, snapshot and device restart are its profile's private
;    file instead, whatever port the caller passed. On 2026-11-11 a live check's
;    Gestures « Tout effacer » found no backup in its fresh profile and reset the
;    maintainer's own gesture settings to the Windows factory values.
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
; @param ReadFn {Func|0} Strict file reader, fn(Path) (FSReadStrict).
; @return {Boolean} True when a restorable backup exists afterwards; false blocks every write.
TouchpadRegistryEnsureBackup(SnapshotFn := 0, CreateFn := 0, ExistsFn := 0, BackupPath := "", ReadFn := 0) {
	Tag := TouchpadRegistryLogTag()
	Path := BackupPath != "" ? BackupPath : TouchpadRegistryBackupPath()
	Snapshot := _TouchpadRegistryIsolate(Map("snapshot",
		HasMethod(SnapshotFn, "Call") ? SnapshotFn : TouchpadRegistrySnapshot))["snapshot"]
	Create := HasMethod(CreateFn, "Call") ? CreateFn : FSWriteCreateDurable
	Exists := HasMethod(ExistsFn, "Call") ? ExistsFn : FSStrictExists
	Read := HasMethod(ReadFn, "Call") ? ReadFn : FSReadStrict
	try {
		if Exists.Call(Path) {
			; A kept backup is immutable but must be restorable: an unreadable or
			; malformed one would authorize writes that Restore later refuses to undo.
			_TouchpadRegistryParseBackup(Read.Call(Path), TouchpadRegistryData())
			LoggerDebug(Tag, "Keeping the touchpad backup of the values from before Ergopti's first write.")
			return true
		}
		Data := TouchpadRegistryData()
		Text := _TouchpadRegistryBackupText(Data, Snapshot.Call(Data["key"], _TouchpadRegistryNames(Data)))
		SplitPath(Path, , &Directory)
		FSEnsureDirectoryStrict(Directory)
		if (Create.Call(Path, Text) != 1) {
			; A concurrent owner may have created it between the probe and the create
			if Exists.Call(Path) {
				_TouchpadRegistryParseBackup(Read.Call(Path), TouchpadRegistryData())
				return true
			}
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

; Writes every generated value, after the backup. Used by the tray action, the
; deferred first-boot configuration and the first-run wizard, always in the
; resident process: an elevated writer would target the HKCU of whichever
; account answered the UAC prompt, not the signed-in user's (WG-003).
; @param WriteFn {Func|0} DWORD writer, fn(Key, Name, Value) (Reg_WriteDword).
; @param SnapshotFn, CreateFn, ExistsFn, BackupPath: forwarded to the backup.
; @return {Boolean} True only when the backup exists and every value was written.
TouchpadRegistryApply(WriteFn := 0, SnapshotFn := 0, CreateFn := 0, ExistsFn := 0, BackupPath := "", ReadFn := 0) {
	Tag := TouchpadRegistryLogTag()
	LoggerStart(Tag, "Writing the Precision Touchpad gesture values…")
	Write := _TouchpadRegistryIsolate(Map("write",
		HasMethod(WriteFn, "Call") ? WriteFn : Reg_WriteDword), true)["write"]
	if !TouchpadRegistryEnsureBackup(SnapshotFn, CreateFn, ExistsFn, BackupPath, ReadFn) {
		LoggerError(Tag, "No touchpad value was written: the prior values are not backed up.")
		return false
	}
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

; The values a fresh Windows profile holds, in the shape of a parsed backup:
; each family enable gets its shipped value, every other name is absent.
; @param Data {Map} TouchpadRegistryData().
; @return {Array} Maps ("name", "absent", "value") in write order.
_TouchpadRegistryFactoryEntries(Data) {
	Factory := Data["factory_defaults"]
	Entries := []
	for _, Value in Data["values"] {
		Name := Value["name"]
		Entries.Push(Factory.Has(Name)
			? Map("name", Name, "absent", false, "value", Factory[Name])
			: Map("name", Name, "absent", true, "value", 0))
	}
	return Entries
}

; Puts the touchpad back to its system state, then restarts it so its driver
; reloads the values: the values backed up before Ergopti's first write when
; that backup exists (it is removed afterwards), the Windows factory defaults
; otherwise.
; @param OnDone {Func|0} Touchpad-restart completion, fn(Ok).
; @param Io {Map|0} Test seams, each optional: exists, read, write,
;   delete_value, delete_file, restart, backup_path. In an isolated profile the
;   write, delete_value and restart ports are the private key's (section 4).
; @return {String} "restored" (from the backup), "factory_defaults" or "failed".
TouchpadRegistryRestore(OnDone := 0, Io := 0) {
	Tag := TouchpadRegistryLogTag()
	Seams := Io is Map ? Io : Map()
	Path := Seams.Get("backup_path", "") != "" ? Seams["backup_path"] : TouchpadRegistryBackupPath()
	Exists := Seams.Get("exists", FSStrictExists)
	Read := Seams.Get("read", FSReadStrict)
	DeleteFile := Seams.Get("delete_file", FSDelete)
	LoggerStart(Tag, "Restoring the Windows touchpad gestures…")
	Machine := _TouchpadRegistryIsolate(Map("write", Seams.Get("write", Reg_WriteDword),
		"delete_value", Seams.Get("delete_value", Reg_DeleteValue),
		"restart", Seams.Get("restart", GestureRestartTouchpadDevice)), true)
	Write := Machine["write"]
	DeleteValue := Machine["delete_value"]
	Restart := Machine["restart"]
	try {
		Data := TouchpadRegistryData()
		FromBackup := Exists.Call(Path)
		if FromBackup {
			Entries := _TouchpadRegistryParseBackup(Read.Call(Path), Data)
			LoggerInfo(Tag, "Restoring the touchpad values backed up in '{1}'.", Path)
		} else {
			Entries := _TouchpadRegistryFactoryEntries(Data)
			LoggerInfo(Tag, "No touchpad backup: restoring the Windows factory defaults.")
		}
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
		LoggerError(Tag, FromBackup
			? "{1} of {2} touchpad value(s) could not be restored; the backup is kept for a retry."
			: "{1} of {2} touchpad value(s) could not be reset to the Windows factory defaults.",
			Failed, Entries.Length)
		return "failed"
	}
	if FromBackup && !DeleteFile.Call(Path) {
		LoggerError(Tag, "The touchpad values were restored but the backup '{1}' could not be removed.", Path)
		return "failed"
	}
	; The driver caches its gesture map: without the PnP restart the restored
	; values only take effect at the next sign-in.
	if !Restart.Call(OnDone)
		LoggerError(Tag, "The touchpad values were restored but the touchpad could not be restarted; they apply at the next sign-in.")
	LoggerSuccess(Tag, FromBackup ? "{1} touchpad value(s) restored from the backup."
		: "{1} touchpad value(s) reset to the Windows factory defaults.", Entries.Length)
	return FromBackup ? "restored" : "factory_defaults"
}

; The system half of the Gestures and global « Tout effacer » on Windows: the
; touchpad goes back to the values from before Ergopti, or to the Windows
; factory defaults without a backup, and the user is told which. A failure is
; already an ERROR, which the shared error UI surfaces.
; @param RestoreFn {Func} The restore, fn() returning TouchpadRegistryRestore's result.
; @param NotifyFn {Func|0} Notifier, fn(Message, Opts) (NotifierSend).
; @return {String} The restore's result.
TouchpadRegistryClearToSystem(RestoreFn, NotifyFn := 0) {
	if !HasMethod(RestoreFn, "Call")
		throw TypeError("The touchpad clear requires its restore owner.")
	Notify := HasMethod(NotifyFn, "Call") ? NotifyFn : NotifierSend
	Result := RestoreFn.Call()
	if (Result == "restored")
		Notify.Call(t("notify.touchpad.restored"), Map("level", "success"))
	else if (Result == "factory_defaults")
		Notify.Call(t("notify.touchpad.factory_defaults"), Map("level", "success"))
	else if (Result != "failed")
		throw ValueError("Unknown touchpad restore result: " . String(Result))
	; No status refresh here: the clear reloads the driver, and a refused clear
	; leaves the open-time check (GestureSystemOnInitPopup) to see the change.
	return Result
}

; The touchpad clear a scope option map carries. The tray passes
; TouchpadRegistryRestore; tests pass a fake, so a scope test can never reach
; the real registry, and a caller that forgot it fails instead of skipping it.
; @param Options {Map} Scope options with "touchpad_restore" (and an optional
;   "touchpad_notify").
; @return {String} The restore's result.
TouchpadRegistryClearFromScope(Options) {
	if !(Options is Map) || !Options.Has("touchpad_restore")
		throw ValueError("A clear to the system behaviour requires its touchpad_restore port.")
	return TouchpadRegistryClearToSystem(Options["touchpad_restore"], Options.Get("touchpad_notify", 0))
}





; ===================================
; ===================================
; ======= 4/ Isolated Profile =======
; ===================================
; ===================================

; The first line of the private key file; a different line is refused.
; @return {String}
TouchpadRegistryPrivateHeader() {
	return "ergopti-touchpad-private-key 1"
}

; The file that stands for the machine's touchpad key in an isolated profile,
; or "" for a real one. ERGOPTI_STARTUP_SMOKE_DIR already moves the paths, logs
; and configuration of a startup smoke or a live check into its scratch folder
; (infra/boot.ahk); the touchpad key follows, so the harness can read it there.
; @return {String} Absolute path, or "" when the driver owns the real profile.
TouchpadRegistryPrivatePath() {
	global _DriverStartupSmokeDir
	if !IsSet(_DriverStartupSmokeDir) || _DriverStartupSmokeDir == ""
		return ""
	return _DriverStartupSmokeDir . "\touchpad_registry_private.txt"
}

; Replaces the machine ports of an isolated profile with its private key's.
; A caller's own port is replaced too: every port here names the machine's key
; or device, which an isolated driver must never reach.
; @param Ports {Map} Any of snapshot, write, delete_value, restart.
; @param Announce {Boolean} Logs once which key the writes of this call reach.
; @return {Map} The ports to use, the given ones for a real profile.
_TouchpadRegistryIsolate(Ports, Announce := false) {
	Path := TouchpadRegistryPrivatePath()
	if (Path == "")
		return Ports
	Private := Map("snapshot", _TouchpadRegistryPrivateSnapshot.Bind(Path),
		"write", _TouchpadRegistryPrivateWrite.Bind(Path),
		"delete_value", _TouchpadRegistryPrivateDelete.Bind(Path),
		"restart", TouchpadRegistrySkipsDeviceRestart)
	Isolated := Map()
	for Name in Ports {
		if !Private.Has(Name)
			throw ValueError("The touchpad owner has no private port named " . Name . ".")
		Isolated[Name] := Private[Name]
	}
	if Announce
		LoggerInfo(TouchpadRegistryLogTag(),
			"Isolated profile: the touchpad values go to the private key '{1}', never to the machine's.", Path)
	return Isolated
}

; Refuses a key other than the generated one: the private file stands for it only.
; @param Key {String} Registry key path a port was given.
_TouchpadRegistryPrivateRequireKey(Key) {
	if (Key != TouchpadRegistryData()["key"])
		throw ValueError("The private touchpad key stands for " . TouchpadRegistryData()["key"] . " only.")
}

; Reads the private key; an absent file is the key of a fresh profile.
; @param Path {String} TouchpadRegistryPrivatePath().
; @return {Map} name => DWORD, case-insensitive like registry names; throws when invalid.
_TouchpadRegistryPrivateLoad(Path) {
	Values := Map()
	Values.CaseSense := "Off"
	if !FSStrictExists(Path)
		return Values
	Lines := StrSplit(RTrim(StrReplace(FSReadStrict(Path), "`r", ""), "`n"), "`n")
	if (Lines.Length < 2 || Lines[1] != TouchpadRegistryPrivateHeader()
			|| Lines[2] != "key " . TouchpadRegistryData()["key"])
		throw ValueError("the private touchpad key '" . Path . "' has no valid header")
	Index := 3
	while (Index <= Lines.Length) {
		Parts := StrSplit(Lines[Index], " ")
		if !(Parts.Length == 3 && Parts[2] == "dword" && RegExMatch(Parts[3], "^\d{1,10}$")
				&& Integer(Parts[3]) <= 0xFFFFFFFF)
			throw ValueError("malformed private touchpad key line " . Index)
		Values[Parts[1]] := Integer(Parts[3])
		Index += 1
	}
	return Values
}

; Writes the whole private key back.
; @param Path {String} TouchpadRegistryPrivatePath().
; @param Values {Map} name => DWORD.
_TouchpadRegistryPrivateSave(Path, Values) {
	Text := TouchpadRegistryPrivateHeader() . "`n" . "key " . TouchpadRegistryData()["key"] . "`n"
	for Name, Value in Values
		Text .= Name . " dword " . Value . "`n"
	SplitPath(Path, , &Directory)
	FSEnsureDirectoryStrict(Directory)
	if !FSWriteDurable(Path, Text)
		throw Error("the private touchpad key '" . Path . "' could not be written")
}

; TouchpadRegistrySnapshot's contract, over the private key.
; @return {Map} name => Map("type", "REG_DWORD", "value", <DWORD>).
_TouchpadRegistryPrivateSnapshot(Path, Key, Names) {
	_TouchpadRegistryPrivateRequireKey(Key)
	Stored := _TouchpadRegistryPrivateLoad(Path)
	Values := Map()
	for _, Name in Names {
		if Stored.Has(Name)
			Values[Name] := Map("type", "REG_DWORD", "value", Stored[Name])
	}
	return Values
}

; Reg_WriteDword's contract, over the private key.
; @return {Boolean} True once the value is stored; a failure is logged.
_TouchpadRegistryPrivateWrite(Path, Key, Name, Value) {
	try {
		_TouchpadRegistryPrivateRequireKey(Key)
		Values := _TouchpadRegistryPrivateLoad(Path)
		Values[Name] := Integer(Value)
		_TouchpadRegistryPrivateSave(Path, Values)
		return true
	} catch as Err {
		LoggerError(TouchpadRegistryLogTag(), "The private touchpad value {1} could not be written: {2}.",
			Name, Err.Message)
		return false
	}
}

; Reg_DeleteValue's contract, over the private key: an absent value is deleted already.
; @return {Boolean} True once the value is absent; a failure is logged.
_TouchpadRegistryPrivateDelete(Path, Key, Name) {
	try {
		_TouchpadRegistryPrivateRequireKey(Key)
		Values := _TouchpadRegistryPrivateLoad(Path)
		if Values.Has(Name)
			Values.Delete(Name)
		_TouchpadRegistryPrivateSave(Path, Values)
		return true
	} catch as Err {
		LoggerError(TouchpadRegistryLogTag(), "The private touchpad value {1} could not be deleted: {2}.",
			Name, Err.Message)
		return false
	}
}

; An isolated profile never restarts the touchpad device: the machine's key did
; not change, and the elevated worker would disable and re-enable the real
; touchpad behind a UAC prompt. Every launcher of that worker asks here first.
; @param OnDone {Func|0} Restart completion, fn(Ok); it still arrives, with true.
; @return {Boolean} True when the profile is isolated, so the caller launches nothing.
TouchpadRegistrySkipsDeviceRestart(OnDone := 0) {
	if (TouchpadRegistryPrivatePath() == "")
		return false
	LoggerInfo(TouchpadRegistryLogTag(), "Isolated profile: the touchpad device is not restarted.")
	if HasMethod(OnDone, "Call")
		SetTimer(() => OnDone.Call(true), -1)
	return true
}
