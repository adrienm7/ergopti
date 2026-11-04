; tests/unit/ui/webview/test_changelog_restore_authority.ahk

; The native page and timer ports are passive. Backup creation, the public
; restore click, default full-state collection, native disk writes and terminal
; generation settlement all execute their genuine production implementations.
_CRAW_Restore(Mode, Path) {
	global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL, _ConfigDir
	SavedLevel := LOGGER_MIN_LEVEL, SavedDir := _ConfigDir
	SplitPath(Path, , &Cfg)
	BackupLevel := LOGGER_DEFAULT_LEVEL == "DEBUG" ? "INFO" : "DEBUG"
	RuntimeLevel := LOGGER_DEFAULT_LEVEL
	Eval := _CLW_Eval, Scheduler := TimerArmOneShotMs, Restore := ConfigBackup_Restore
	Scripts := [], Scheduled := [], RestoreResult := 0, Bundle := 0, Generation := 0
	RecordEval(Self, Js, Context := 0, NotifyFn := 0) {
		Scripts.Push(Js)
		return true
	}
	RecordSchedule(Self, Callback, Delay) {
		AssertTrue(HasMethod(Callback, "Call"))
		Scheduled.Push({callback: Callback, delay: Delay})
		return true
	}
	RecordRestore(Self, ConfigDir, Id, Rules := 0, ClockFn := 0) {
		AssertEqual(0, A_IsCritical, "the physical restore remains interruptible")
		Restore.DeleteProp("Call")
		RestoreResult := Restore.Call(ConfigDir, Id, Rules, ClockFn)
		return RestoreResult
	}
	for Observer in [Eval, Scheduler, Restore]
		AssertFalse(Observer.HasOwnProp("Call"), "the fixture cannot detach a foreign observer")
	try {
		AssertFalse(ReleaseInstall_Busy(), "the actual installer must admit this restore click")
		AssertFalse(_ConfigWriteTerminalIsActive(), "the fixture cannot borrow an older transition")
		_ConfigDir := Cfg
		LOGGER_MIN_LEVEL := BackupLevel
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, _CFGFS_Timer), "the genuine default writer records the selected backup's semantic logger level")
		Rules := ConfigBackup_Rules()
		Backup := ConfigBackup_Create(Cfg, "pre_install", "", "", Rules,
			() => Map("stamp", "20261028-200600", "iso", "2026-10-28T19:06:00Z"))
		Expected := FSReadUtf8Exact(Path)
		LOGGER_MIN_LEVEL := RuntimeLevel
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, _CFGFS_Timer), "the actual live runtime and disk must genuinely differ from the backup")
		AssertFalse(Expected == FSReadUtf8Exact(Path))
		if Mode == "pending" || Mode == "dirty-pending" {
			if Mode == "dirty-pending"
				LOGGER_MIN_LEVEL := "ERROR"
			Generation := _ConfigFullSaveRequest(true)
			AssertTrue(Generation > 0 && _ConfigFullSaveHasPending())
		}
		Eval.DefineProp("Call", {Call: RecordEval})
		Scheduler.DefineProp("Call", {Call: RecordSchedule})
		Restore.DefineProp("Call", {Call: RecordRestore})
		_CLW_RestoreBackup(Backup["id"])
		AssertTrue(RestoreResult is Map && RestoreResult["ok"], "the actual public restore click reaches the real backup consumer")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "the chosen backup initially reaches the actual configuration path")
		AssertFalse(_ConfigFullSaveHasPending(), "every earlier accepted RAM obligation settles before the selected backup is restored")
		PreSnapshot := ConfigTomlDecodeSnapshot(FSReadUtf8Exact(RestoreResult["pre"]["path"] . "\config\config.toml")).Cache
		PreLevel := IniCacheGet(PreSnapshot, ConfigKey.SCRIPT, ConfigLeaf.LOG_LEVEL, LOGGER_DEFAULT_LEVEL)
		AssertEqual(Mode == "dirty-pending" ? "ERROR" : RuntimeLevel, PreLevel,
			"the pre-restore backup includes the latest actually accepted RAM value")
		AssertEqual(0, _ConfigFullSaveRequest(true), "the page answer delay cannot admit a fresh stale-RAM save")
		AssertEqual(1, Scheduled.Length)
		AssertEqual(400, Scheduled[1].delay, "the page's existing answer delay is unchanged")
		AssertEqual(2, Scripts.Length)
		AssertContains(Scripts[2], '"phase":"restored"')
		Bundle := _ConfigWriteLeaseState().terminal
		if !(Bundle is Object)
			Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path), "the actual terminal issuer must own the selected configuration")
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, 0, _CFGFS_Timer), "the genuine pending generation settlement permits the promised restart")
		Semantic := ConfigTomlDecodeSnapshot(FSReadUtf8Exact(Path)).Cache
		ActualLevel := IniCacheGet(Semantic, ConfigKey.SCRIPT, ConfigLeaf.LOG_LEVEL, LOGGER_DEFAULT_LEVEL)
		_TestPrint("# RESTORE_CLICK_TERMINAL mode=" . Mode . " logger_level=" . ActualLevel
			. " backup_level=" . BackupLevel . " bytes_preserved=" . (Expected == FSReadUtf8Exact(Path)))
		AssertEqual(BackupLevel, ActualLevel, "the next logger must read the selected backup level, not the previous runtime level")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "terminal settlement cannot overwrite the selected backup with old RAM")
		_CRAW_AssertLoggerLevel(Path, BackupLevel)
	} finally {
		for Observer in [Eval, Scheduler, Restore]
			if Observer.HasOwnProp("Call")
				Observer.DeleteProp("Call")
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		if Generation > 0
			_ConfigFullSaveRejectExact(Generation)
		LOGGER_MIN_LEVEL := SavedLevel
		_ConfigDir := SavedDir
	}
}
for Mode in ["healthy", "pending", "dirty-pending"]
	Test("Changelog restore authority: actual click and terminal default writer " . Mode . " (changelog-restore-authority)",
		_CFGFS_DurableDebtFixture.Bind(_CRAW_Restore.Bind(Mode)))

_CRAW_LoggerDone(State, Code, Output, ErrorText) {
	State.calls += 1, State.code := Code, State.output := Output, State.error_text := ErrorText
}

; This is a genuine cold LoggerInit against an independently copied native
; source. No logger producer or configuration read API answers for production.
_CRAW_AssertLoggerLevel(Path, ExpectedLevel) {
	global _DriverDir
	static Serial := 0
	Root := A_Temp . "\ergopti-restored-logger-" . A_ScriptHwnd . "-" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {calls: 0, code: -1, output: "", error_text: ""}, Handle := 0, Retired := false
	try {
		_EDOT_Assets(Root)
		Input := Root . "\config\absent.toml"
		FileCopy(Path, Input, false)
		AssertTrue(FSSameBytes(Path, Input), "the independent cold logger reads every exact restored byte")
		Source := _EDOT_Source(Root)
		Footer := "#Include " . _DriverDir . "\tests\fixtures\error_dialog_startup_owner_body.ahk`n"
		AssertTrue(SubStr(Source, StrLen(Source) - StrLen(Footer) + 1) == Footer)
		Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
		Source := StrReplace(Source, "OnError(_EDOS_BootError)`n", "")
		Source := RegExReplace(Source, "m)^_EDOS_Phase\([^\r\n]*\)\r?\n", "")
		Source .= "#Include " . _DriverDir . "\tests\fixtures\changelog_restore_logger_body.ahk`n"
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Source))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, ExpectedLevel], _CRAW_LoggerDone.Bind(State))
		AssertTrue(Handle.start(), "the actual isolated logger component starts")
		Started := A_TickCount
		while State.calls == 0 && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.calls, "the exact cold logger must acknowledge one native completion")
		AssertEqual(0, State.code, "the genuine LOGGER_MIN_LEVEL must match the selected backup: " . State.output . " " . State.error_text)
		AssertFalse(RegExMatch(State.output . State.error_text, "m)^.*: ==> Warning:"), "the genuine cold logger include graph must compile without warnings")
		AssertContains(State.output, "RESTORED_LOGGER_LEVEL=" . ExpectedLevel)
	} finally {
		if IsObject(Handle) {
			if State.calls == 0
				Handle.requestTerminate()
			Ack := Handle.terminate()
			Retired := (Ack is Integer) && Ack == 1
		} else
			Retired := true
		AssertTrue(Retired, "the actual native child must retire before its private files are removed")
		if Retired && DirExist(Root)
			DirDelete(Root, true)
	}
}

_CRAW_LifecycleSource(Root) {
	global _DriverDir
	Source := _EDOT_Source(Root)
	Footer := "#Include " . _DriverDir . "\tests\fixtures\error_dialog_startup_owner_body.ahk`n"
	AssertTrue(SubStr(Source, StrLen(Source) - StrLen(Footer) + 1) == Footer)
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	Source := StrReplace(Source, "OnError(_EDOS_BootError)", "OnError(_CRAWC_Error)")
	Source := RegExReplace(Source, "m)^_EDOS_Phase\([^\r\n]*\)\r?\n", "")
	for Symbol in ["ConfigBackup_Restore", "ReleaseInstall_Busy", "_ConfigFullSaveSettleTerminal", "TimerArmOneShotMs", "ProgramActions_Stop", "ReloadPreservingSuspend", "NotifierSend", "_CLW_RestoreBackup"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "the restore component requires the genuine whole owner: " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	Source .= "#Include " . _DriverDir . "\tests\test_framework.ahk`n"
		. "#Include " . _DriverDir . "\tests\unit\infra\lifecycle\test_reload_terminal_pending.ahk`n"
		. "global _CRAWC_SchemaVersion := " . ConfigMigrateCurrentVersion() . "`n"
	return Source . "#Include " . _DriverDir . "\tests\fixtures\changelog_restore_lifecycle_body.ahk`n"
}

_CRAW_LifecycleComponent() {
	static Serial := 0
	Root := A_Temp . "\ergopti-restored-lifecycle-" . A_ScriptHwnd . "-" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {calls: 0, code: -1, output: "", error_text: ""}, Handle := 0, Retired := false
	try {
		_EDOT_Assets(Root)
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _CRAW_LifecycleSource(Root)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script], _CRAW_LoggerDone.Bind(State))
		AssertTrue(Handle.start(), "the genuine reload lifecycle component starts")
		Started := A_TickCount
		while State.calls == 0 && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.calls, "the whole lifecycle component acknowledges one native completion")
		AssertEqual(0, State.code, "whole reload lifecycle failed: " . State.output . " " . State.error_text)
		AssertFalse(RegExMatch(State.output . State.error_text, "m)^.*: ==> Warning:"), "the genuine whole lifecycle include graph must compile without warnings")
		for CaseMode in ["missing", "write-refusal", "timer-throw", "timer-false", "sync-refusal", "async-refusal", "duplicate-timer", "stale-timer", "inline-then-throw", "reentrant-launch"]
			AssertContains(State.output, "RESTORE_LIFECYCLE_CASE_PASS=" . CaseMode . "`n")
		AssertContains(State.output, "RESTORE_LIFECYCLE_ALL_PASS=10")
		_TestPrint("# RESTORE_LIFECYCLE_NATIVE_RECEIPT " . StrReplace(Trim(State.output, "`r`n"), "`n", " | "))
	} finally {
		if IsObject(Handle) {
			if State.calls == 0
				Handle.requestTerminate()
			Ack := Handle.terminate()
			Retired := (Ack is Integer) && Ack == 1
		} else
			Retired := true
		AssertTrue(Retired, "the genuine lifecycle child must retire before its private files")
		if Retired && DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("Changelog restore authority: whole native reload owner and retained recovery (changelog-restore-authority-native-lifecycle)", _CRAW_LifecycleComponent)


_CRAW_SettlementFailure(Path) {
	global LOGGER_MIN_LEVEL, _ConfigDir
	SavedLevel := LOGGER_MIN_LEVEL, SavedDir := _ConfigDir
	SplitPath(Path, , &Cfg)
	Eval := _CLW_Eval, Restore := ConfigBackup_Restore, Timer := TimerArmOneShotMs
	Scripts := [], RestoreCalls := 0, RestoreTimers := 0, Lock := -1
	RecordEval(Self, Js, Context := 0, NotifyFn := 0) {
		Scripts.Push(Js)
		return true
	}
	RecordRestore(Self, ConfigDir, Id, Rules := 0, ClockFn := 0) {
		RestoreCalls += 1
		Restore.DeleteProp("Call")
		return Restore.Call(ConfigDir, Id, Rules, ClockFn)
	}
	RecordTimer(Self, Callback, Delay) {
		RestoreTimers += 1
		return true
	}
	for Observer in [Eval, Restore, Timer]
		AssertFalse(Observer.HasOwnProp("Call"))
	try {
		AssertFalse(_ConfigFullSaveHasPending())
		AssertFalse(_ConfigFullSaveCoordinator().timer_armed)
		_ConfigDir := Cfg
		Rules := ConfigBackup_Rules()
		Backup := ConfigBackup_Create(Cfg, "pre_install", "", "", Rules,
			() => Map("stamp", "20261028-203000", "iso", "2026-10-28T19:30:00Z"))
		Before := FSReadUtf8Exact(Path)
		LOGGER_MIN_LEVEL := SavedLevel == "ERROR" ? "DEBUG" : "ERROR"
		Generation := _ConfigFullSaveRequest(true)
		AssertTrue(Generation > 0 && _ConfigFullSaveHasPending())
		Lock := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000,
			"UInt", 1, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		AssertTrue(Lock != -1, "a genuine foreign native reader denies the writer's destination replacement")
		Eval.DefineProp("Call", {Call: RecordEval})
		Restore.DefineProp("Call", {Call: RecordRestore})
		Timer.DefineProp("Call", {Call: RecordTimer})
		AssertFalse(_CLW_RestoreBackup(Backup["id"]))
		AssertEqual(0, RestoreCalls, "a refused genuine full-save settlement precedes every backup restore effect")
		AssertEqual(0, RestoreTimers)
		AssertEqual(1, Scripts.Length)
		AssertContains(Scripts[1], '"phase":"failed"')
		AssertEqual(Before, FSReadUtf8Exact(Path), "neither the pending writer nor the selected restore may change the protected native target")
		AssertTrue(_ConfigFullSaveHasPending(), "the actual accepted RAM intent survives the refusal")
		AssertFalse(_ConfigWriteTerminalIsActive(), "a pre-publication refusal releases the exact terminal barrier")
		AssertFalse(ConfigTransitionRetainedBarrier())
		AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Lock, "Int"))
		Lock := -1
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer), "the same real pending default writer can succeed after the physical obstruction retires")
		AssertFalse(_ConfigFullSaveHasPending())
		Semantic := ConfigTomlDecodeSnapshot(FSReadUtf8Exact(Path)).Cache
		AssertEqual(LOGGER_MIN_LEVEL, IniCacheGet(Semantic, ConfigKey.SCRIPT, ConfigLeaf.LOG_LEVEL, LOGGER_DEFAULT_LEVEL))
	} finally {
		for Observer in [Eval, Restore, Timer]
			if Observer.HasOwnProp("Call")
				Observer.DeleteProp("Call")
		if Lock != -1
			AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Lock, "Int"))
		; The fixture began with no pending timer and owns this exact newly
		; armed deferred callback, including a successful drain's stale wakeup.
		SetTimer(_SaveFullConfigDeferred, 0)
		LOGGER_MIN_LEVEL := SavedLevel, _ConfigDir := SavedDir
	}
}
Test("Changelog restore authority: real pending writer refusal precedes publication and remains recoverable (changelog-restore-settlement-failure)",
	_CFGFS_DurableDebtFixture.Bind(_CRAW_SettlementFailure))
