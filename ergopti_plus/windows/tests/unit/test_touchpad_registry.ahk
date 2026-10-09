; tests/unit/test_touchpad_registry.ahk

; ==============================================================================
; MODULE: Precision Touchpad Registry Owner Tests
; DESCRIPTION:
; F2: the Windows touchpad registry values come from one generated table, both
; writers read it, the prior values are backed up before the first write, and
; « Restaurer les gestes du pavé tactile Windows » puts them back exactly.
;
; ROOT CAUSE ENCODED:
; The in-process writer and the wizard's elevated PowerShell script each carried
; their own copy of every value name and number, and neither recorded what it
; overwrote: the user's own gesture settings were lost for good on the first
; configuration, with no way back from the menu.
;
; SCOPE: behavioural. The owner's I/O seams are injected, so every ordering is
; proven against a fake registry without touching the real one.
; ==============================================================================

#Requires AutoHotkey v2.0

global _TPR_Log := []
global _TPR_Files := Map()
global _TPR_Registry := Map()
global _TPR_ForeignType := ""
global _TPR_DeleteFails := false
global _TPR_CreateFails := false





; ================================
; ================================
; ======= 1/ Fake Registry =======
; ================================
; ================================

; Resets the fake registry key and files for one case.
_TPR_Reset(Initial) {
	global _TPR_Log, _TPR_Files, _TPR_Registry, _TPR_ForeignType, _TPR_DeleteFails, _TPR_CreateFails
	_TPR_Log := []
	_TPR_Files := Map()
	_TPR_Registry := Initial
	_TPR_ForeignType := ""
	_TPR_DeleteFails := false
	_TPR_CreateFails := false
}

; A backup path in a real temp folder: the owner creates its parent directory.
_TPR_Path() {
	return A_Temp . "\ergopti_tpr_" . DriverPid . "\touchpad_registry_backup.txt"
}

_TPR_Snapshot(Key, Names) {
	global _TPR_Log, _TPR_Registry, _TPR_ForeignType
	_TPR_Log.Push("snapshot")
	Result := Map()
	for _, Name in Names {
		if _TPR_Registry.Has(Name)
			Result[Name] := Map("type", _TPR_ForeignType != "" ? _TPR_ForeignType : "REG_DWORD",
				"value", _TPR_Registry[Name])
	}
	return Result
}

_TPR_Exists(Path) {
	global _TPR_Files
	return _TPR_Files.Has(Path)
}

_TPR_Create(Path, Text) {
	global _TPR_Files, _TPR_Log, _TPR_CreateFails
	if _TPR_CreateFails || _TPR_Files.Has(Path)
		return 0
	_TPR_Log.Push("backup")
	_TPR_Files[Path] := Text
	return 1
}

_TPR_Write(Key, Name, Value) {
	global _TPR_Registry, _TPR_Log
	_TPR_Log.Push("write " . Name)
	_TPR_Registry[Name] := Value
	return true
}

_TPR_Read(Path) {
	global _TPR_Files
	return _TPR_Files[Path]
}

_TPR_DeleteValue(Key, Name) {
	global _TPR_Registry, _TPR_Log, _TPR_DeleteFails
	if _TPR_DeleteFails
		return false
	_TPR_Log.Push("delete " . Name)
	if _TPR_Registry.Has(Name)
		_TPR_Registry.Delete(Name)
	return true
}

_TPR_DeleteFile(Path) {
	global _TPR_Files, _TPR_Log
	_TPR_Log.Push("remove backup")
	_TPR_Files.Delete(Path)
	return true
}

_TPR_Restart(OnDone) {
	global _TPR_Log
	_TPR_Log.Push("restart")
	return true
}

_TPR_RestoreSeams() {
	return Map("exists", _TPR_Exists, "read", _TPR_Read, "write", _TPR_Write,
		"delete_value", _TPR_DeleteValue, "delete_file", _TPR_DeleteFile,
		"restart", _TPR_Restart, "backup_path", _TPR_Path())
}

_TPR_Apply() {
	return TouchpadRegistryApply(_TPR_Write, _TPR_Snapshot, _TPR_Create, _TPR_Exists, _TPR_Path())
}

_TPR_Count(Prefix) {
	global _TPR_Log
	Count := 0
	for _, Event in _TPR_Log {
		if (SubStr(Event, 1, StrLen(Prefix)) == Prefix)
			Count += 1
	}
	return Count
}

; The user's own settings before Ergopti: the first written value is set to a
; personal number, every other one is absent.
_TPR_UserSettings() {
	Values := TouchpadRegistryData()["values"]
	return Map(Values[1]["name"], 1234)
}





; ===================================
; ===================================
; ======= 2/ Backup and Write =======
; ===================================
; ===================================

_TPR_BackupPrecedesTheFirstWrite() {
	global _TPR_Log, _TPR_Files, _TPR_Registry
	_TPR_Reset(_TPR_UserSettings())
	Values := TouchpadRegistryData()["values"]
	AssertTrue(_TPR_Apply(), "a backed-up configuration must be written")
	AssertEqual("snapshot", _TPR_Log[1], "the prior values are read first")
	AssertEqual("backup", _TPR_Log[2], "and saved before anything is written")
	AssertEqual(Values.Length, _TPR_Count("write "), "every generated value is written")
	Backup := _TPR_Files[_TPR_Path()]
	AssertContains(Backup, Values[1]["name"] . " dword 1234`n",
		"the user's own value is recorded with its number")
	AssertContains(Backup, Values[2]["name"] . " absent`n",
		"a value the user never had is recorded as absent")
	AssertEqual(Values[2]["value"], _TPR_Registry[Values[2]["name"]], "the generated value is live")
}
Test("touchpad registry: the prior values are backed up before the first write (touchpad-backup-first)",
	_TPR_BackupPrecedesTheFirstWrite)

_TPR_SecondConfigurationKeepsTheOriginalBackup() {
	global _TPR_Log, _TPR_Files
	_TPR_Reset(_TPR_UserSettings())
	AssertTrue(_TPR_Apply())
	First := _TPR_Files[_TPR_Path()]
	_TPR_Log := []
	AssertTrue(_TPR_Apply(), "a second configuration still writes")
	AssertEqual(0, _TPR_Count("backup"), "Ergopti's own values must never replace the user's backup")
	AssertEqual(First, _TPR_Files[_TPR_Path()], "the backup still holds the values from before Ergopti")
}
Test("touchpad registry: a later configuration keeps the original backup (touchpad-backup-once)",
	_TPR_SecondConfigurationKeepsTheOriginalBackup)

_TPR_NoBackupMeansNoWrite() {
	global _TPR_CreateFails, _TPR_ForeignType
	_TPR_Reset(_TPR_UserSettings())
	_TPR_CreateFails := true
	AssertFalse(_TPR_Apply(), "a configuration without a backup must be refused")
	AssertEqual(0, _TPR_Count("write "), "nothing may be written without a backup")

	_TPR_Reset(_TPR_UserSettings())
	_TPR_ForeignType := "REG_SZ"
	AssertFalse(_TPR_Apply(), "a value that could not be restored faithfully refuses the write")
	AssertEqual(0, _TPR_Count("write "), "no value may be overwritten when one cannot be backed up")
	AssertEqual(0, _TPR_Count("backup"), "and no partial backup is published")
}
Test("touchpad registry: no backup, no write (touchpad-backup-required)", _TPR_NoBackupMeansNoWrite)





; ==========================
; ==========================
; ======= 3/ Restore =======
; ==========================
; ==========================

_TPR_RestorePutsTheUserSettingsBack() {
	global _TPR_Log, _TPR_Files, _TPR_Registry
	_TPR_Reset(_TPR_UserSettings())
	AssertTrue(_TPR_Apply())
	_TPR_Log := []
	AssertEqual("restored", TouchpadRegistryRestore(0, _TPR_RestoreSeams()))
	Expected := _TPR_UserSettings()
	AssertEqual(Expected.Count, _TPR_Registry.Count, "values the user never had are deleted again")
	for Name, Value in Expected
		AssertEqual(Value, _TPR_Registry.Get(Name, ""), Name . " is back to the user's number")
	AssertFalse(_TPR_Files.Has(_TPR_Path()), "a consumed backup is removed so the next write backs up again")
	AssertEqual("restart", _TPR_Log[_TPR_Log.Length], "the touchpad restarts last, to reload its map")
}
Test("touchpad registry: restore puts the user's own values back (touchpad-restore-exact)",
	_TPR_RestorePutsTheUserSettingsBack)

_TPR_RestoreWithoutBackupChangesNothing() {
	global _TPR_Registry
	_TPR_Reset(Map())
	AssertEqual("no_backup", TouchpadRegistryRestore(0, _TPR_RestoreSeams()))
	AssertEqual(0, _TPR_Count("write ") + _TPR_Count("delete ") + _TPR_Count("restart"),
		"Ergopti never changed these settings, so nothing is touched")
}
Test("touchpad registry: no backup, nothing to restore (touchpad-restore-none)",
	_TPR_RestoreWithoutBackupChangesNothing)

_TPR_UnprovableBackupIsRefused() {
	global _TPR_Files, _TPR_Registry, _TPR_DeleteFails
	Header := TouchpadRegistryBackupHeader() . "`nkey " . TouchpadRegistryData()["key"] . "`n"
	for _, Text in ["garbage", Header, Header . "UnknownValue dword 1`n"] {
		_TPR_Reset(Map("kept", 1))
		_TPR_Files[_TPR_Path()] := Text
		AssertEqual("failed", TouchpadRegistryRestore(0, _TPR_RestoreSeams()),
			"a backup that does not match the generated table is refused")
		AssertEqual(0, _TPR_Count("write ") + _TPR_Count("delete "), "nothing is changed from it")
	}

	_TPR_Reset(_TPR_UserSettings())
	AssertTrue(_TPR_Apply())
	_TPR_DeleteFails := true
	AssertEqual("failed", TouchpadRegistryRestore(0, _TPR_RestoreSeams()))
	AssertTrue(_TPR_Files.Has(_TPR_Path()), "a failed restore keeps the backup for a retry")
}
Test("touchpad registry: an unprovable or failed restore keeps the backup (touchpad-restore-refusal)",
	_TPR_UnprovableBackupIsRefused)





; =============================
; =============================
; ======= 4/ One Source =======
; =============================
; =============================

_TPR_WizardScriptWritesTheGeneratedTable() {
	Data := TouchpadRegistryData()
	Script := _Onboarding_BuildGesturePsScript(A_Temp . "\ergopti_tpr.result")
	AssertContains(Script, "$Reg = '" . Data["powershell_key"] . "'", "the script targets the generated key")
	Lines := 0
	Pos := 1
	while (Pos := InStr(Script, "' = ", , Pos)) {
		Lines += 1
		Pos += 4
	}
	AssertEqual(Data["values"].Length, Lines, "the script writes exactly the generated values")
	for _, Entry in Data["values"]
		AssertContains(Script, "  '" . Entry["name"] . "' = " . Entry["value"] . "`r`n",
			"the script writes " . Entry["name"])
}
Test("touchpad registry: the wizard script writes the generated table (touchpad-one-source)",
	_TPR_WizardScriptWritesTheGeneratedTable)

_TPR_BothWritersGoThroughTheOwner() {
	Configure := _DriverFuncBody("GestureAutoConfigureRegistry")
	Assert(Configure != "", "the in-process writer must exist")
	AssertTrue(InStr(Configure, "TouchpadRegistryApply(") > 0,
		"the in-process writer must write through the backing-up owner")
	AssertEqual(0, InStr(Configure, "Reg_WriteDword"), "and never write a value of its own")
	Start := _DriverFuncBody("_Onboarding_StartGestureAuto")
	Assert(Start != "", "the wizard launcher must exist")
	BackupAt := InStr(Start, "TouchpadRegistryEnsureBackup(")
	RunAt := InStr(Start, "Run(")
	AssertTrue(BackupAt > 0 && RunAt > BackupAt,
		"the wizard must back up the values before its elevated script can overwrite them")
}
Test("touchpad registry: both writers go through the one owner (touchpad-one-owner)",
	_TPR_BothWritersGoThroughTheOwner)
