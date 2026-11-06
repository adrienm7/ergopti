; tests/unit/modules/gestures/test_touchpad_registry.ahk

; ==============================================================================
; MODULE: Precision Touchpad Registry Owner Tests
; DESCRIPTION:
; F2: the Windows touchpad registry values come from one generated table, both
; writers read it, the prior values are backed up before the first write, and
; the Gestures « Tout effacer » puts them back exactly (or the Windows factory
; defaults when no backup exists).
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
	return TouchpadRegistryApply(_TPR_Write, _TPR_Snapshot, _TPR_Create, _TPR_Exists, _TPR_Path(), _TPR_Read)
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

; Without a backup the restore once changed nothing, so a clear left the
; touchpad sending Ergopti's shortcuts. It now writes the Windows factory
; defaults: each family enable gets its shipped value, every other name goes.
_TPR_RestoreWithoutBackupWritesTheFactoryDefaults() {
	global _TPR_Registry, _TPR_Log
	Data := TouchpadRegistryData()
	Factory := Data["factory_defaults"]
	AssertEqual(4, Factory.Count, "each gesture family has a shipped value")
	; A profile Ergopti configured without leaving a backup (it was deleted).
	Configured := Map()
	for _, Entry in Data["values"]
		Configured[Entry["name"]] := Entry["value"]
	_TPR_Reset(Configured)
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try Result := TouchpadRegistryRestore(0, _TPR_RestoreSeams())
	finally LoggerSetTestSink(0)
	AssertEqual("factory_defaults", Result)
	AssertEqual(Factory.Count, _TPR_Registry.Count, "only the family enables remain")
	for Name, Value in Factory
		AssertEqual(Value, _TPR_Registry.Get(Name, ""), Name . " holds its Windows default")
	AssertEqual(Factory.Count, _TPR_Count("write "), "only the shipped values are written")
	AssertEqual(Data["values"].Length - Factory.Count, _TPR_Count("delete "),
		"every other value Ergopti writes is deleted")
	AssertEqual(0, _TPR_Count("remove backup"), "there is no backup to remove")
	AssertEqual("restart", _TPR_Log[_TPR_Log.Length], "the touchpad restarts last, to reload its map")
	Logged := ""
	for Line in Lines
		Logged .= Line . "`n"
	AssertContains(Logged, "No touchpad backup: restoring the Windows factory defaults.",
		"the log says which path ran")
}
Test("touchpad registry: no backup, the Windows factory defaults (touchpad-restore-factory)",
	_TPR_RestoreWithoutBackupWritesTheFactoryDefaults)

_TPR_RestoreLogsTheBackupPath() {
	_TPR_Reset(_TPR_UserSettings())
	AssertTrue(_TPR_Apply())
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try AssertEqual("restored", TouchpadRegistryRestore(0, _TPR_RestoreSeams()))
	finally LoggerSetTestSink(0)
	Logged := ""
	for Line in Lines
		Logged .= Line . "`n"
	AssertContains(Logged, "Restoring the touchpad values backed up in", "the log names the backup path")
	AssertEqual(0, InStr(Logged, "factory defaults"), "a backed-up restore writes no factory default")
}
Test("touchpad registry: a backup is restored, not the factory defaults (touchpad-restore-path-logged)",
	_TPR_RestoreLogsTheBackupPath)

; The clear tells the user which values came back; an unknown result is a bug.
_TPR_ClearToSystemNotifiesEachPath() {
	for _, Expected in [["restored", "notify.touchpad.restored"],
			["factory_defaults", "notify.touchpad.factory_defaults"], ["failed", ""]] {
		Shown := []
		Result := TouchpadRegistryClearToSystem(((R) => () => R)(Expected[1]),
			(Message, Opts) => (Shown.Push(Message), true))
		AssertEqual(Expected[1], Result)
		if (Expected[2] == "")
			AssertEqual(0, Shown.Length, "a failure is already an ERROR, not a success notice")
		else {
			AssertEqual(1, Shown.Length)
			AssertEqual(t(Expected[2]), Shown[1])
		}
	}
	Threw := false
	try TouchpadRegistryClearToSystem(() => "no_backup", (*) => true)
	catch ValueError
		Threw := true
	AssertTrue(Threw, "a result the clear does not know is refused")
	Threw := false
	try TouchpadRegistryClearFromScope(Map())
	catch ValueError
		Threw := true
	AssertTrue(Threw, "a scope clear without its touchpad port fails instead of skipping the touchpad")
}
Test("touchpad registry: the clear says which values came back (touchpad-clear-notice)",
	_TPR_ClearToSystemNotifiesEachPath)

; The Configuration row was merged into the Gestures clear (maintainer, 2026-11-03).
_TPR_NoConfigurationRestoreRow() {
	Body := _DriverFuncBody("_MI_BuildConfigurationMenu")
	Assert(Body != "", "the Configuration builder must exist")
	AssertEqual(0, InStr(Body, "Touchpad"), "Configuration no longer dispatches a touchpad restore")
	for _, Entry in _MM_GetManifestRoot()["configuration_menu"]
		AssertFalse(Entry.Get("id", "") == "restore_touchpad_gestures", "Configuration declares no touchpad row")
	Clear := _DriverFuncBody("_GES_ApplyScope")
	Assert(Clear != "", "the Gestures scope owner must exist")
	AssertTrue(InStr(Clear, "TouchpadRegistryClearFromScope(") > 0, "the Gestures clear restores the touchpad")
}
Test("touchpad registry: the restore lives in the Gestures clear (gestures-clear-restores-touchpad)",
	_TPR_NoConfigurationRestoreRow)

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

; Regression (AHK-008 / WG-002): an existing backup that Restore would refuse
; must not authorize the destructive apply.
_TPR_UnrestorableExistingBackupBlocksApply() {
	global _TPR_Files
	Header := TouchpadRegistryBackupHeader() . "`nkey " . TouchpadRegistryData()["key"] . "`n"
	for _, Text in ["garbage", Header, Header . "UnknownValue dword 1`n"] {
		_TPR_Reset(Map("kept", 1))
		_TPR_Files[_TPR_Path()] := Text
		AssertFalse(_TPR_Apply(), "an unrestorable existing backup refuses the apply")
		AssertEqual(0, _TPR_Count("write "), "no value is written over unrecoverable originals")
		AssertEqual(Text, _TPR_Files[_TPR_Path()], "the existing backup is never replaced")
	}
}
Test("touchpad registry: an existing unrestorable backup blocks every write (WG-002)",
	_TPR_UnrestorableExistingBackupBlocksApply)

; Regression (AHK-007 / WG-001): the onboarding worker must not report success
; when the device restart is absent or refused, like the tray restart worker.
_TPR_OnboardingWorkerFailsWithoutRestart() {
	Script := _GestureRestartBuildPsScript(A_Temp . "\ergopti_tpr.result")
	AssertContains(Script, "$devs.Count -eq 0", "no matching device is a failure")
	AssertFalse(InStr(Script, "PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue"),
		"PnP operations must not swallow their failures")
	AssertContains(Script, "Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop")
	AssertContains(Script, "Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop")
	AssertContains(Script, "finally {", "a disabled device is re-enabled when a later step fails")
	Start := _DriverFuncBody("_Onboarding_StartGestureAuto")
	Assert(Start != "", "the wizard launcher must exist")
	AssertTrue(InStr(Start, "_GestureRestartBuildPsScript(") > 0,
		"the wizard launches the tray's restart worker, with its outcome contract")
}
Test("touchpad registry: onboarding worker fails when the device restart is absent or refused (WG-001)",
	_TPR_OnboardingWorkerFailsWithoutRestart)





; =============================
; =============================
; ======= 4/ One Source =======
; =============================
; =============================

; Regression (AHK-009 / WG-003): HKCU in an elevated worker is the hive of the
; account that answered UAC. A standard user typing an administrator's
; credentials had that administrator's touchpad configured while the backup held
; their own. The wizard must write in process and elevate only the restart.
_TPR_WizardElevatesOnlyTheRestart() {
	Script := _GestureRestartBuildPsScript(A_Temp . "\ergopti_tpr.result")
	for Needle in ["HKCU", "HKEY_", "PrecisionTouchPad", "ItemProperty", "Registry::"]
		AssertEqual(0, InStr(Script, Needle), "the elevated worker touches no per-user registry: " . Needle)
	Start := _DriverFuncBody("_Onboarding_StartGestureAuto")
	Assert(Start != "", "the wizard launcher must exist")
	ApplyAt := InStr(Start, "TouchpadRegistryApply(")
	RunAt := InStr(Start, "Run(")
	AssertTrue(ApplyAt > 0 && RunAt > ApplyAt,
		"the wizard writes the values in the resident process before elevating the restart")
	AssertEqual(0, InStr(Start, "_Onboarding_BuildGesturePsScript"), "no elevated registry writer remains")
}
Test("touchpad registry: the wizard writes as the signed-in user, elevates only the restart (WG-003)",
	_TPR_WizardElevatesOnlyTheRestart)

_TPR_BothWritersGoThroughTheOwner() {
	Configure := _DriverFuncBody("GestureAutoConfigureRegistry")
	Assert(Configure != "", "the in-process writer must exist")
	AssertTrue(InStr(Configure, "TouchpadRegistryApply(") > 0,
		"the in-process writer must write through the backing-up owner")
	AssertEqual(0, InStr(Configure, "Reg_WriteDword"), "and never write a value of its own")
	Start := _DriverFuncBody("_Onboarding_StartGestureAuto")
	Assert(Start != "", "the wizard launcher must exist")
	AssertTrue(InStr(Start, "TouchpadRegistryApply(") > 0,
		"the wizard writes through the backing-up owner")
	AssertEqual(0, InStr(Start, "Reg_WriteDword"), "and never writes a value of its own")
}
Test("touchpad registry: both writers go through the one owner (touchpad-one-owner)",
	_TPR_BothWritersGoThroughTheOwner)

#Include test_gesture_powershell_path_encoding.ahk
