; tests/fixtures/changelog_restore_lifecycle_body.ahk

; Whole production reload, restore and terminal owners execute unchanged.
; Only JS display, native process effects, notices and timer effects are ports.
_CRAWC_Error(Failure, ErrorMode) {
	FileAppend("RESTORE_LIFECYCLE_ERROR " . Failure.Message . "`n" . Failure.Stack . "`n", "*")
	ExitApp(1)
}

_CRAW_Lifecycle(Mode, Path) {
	global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL, _ConfigDir, _ConfigTransitionRetainedBarrier, _CRAWC_SchemaVersion
	global _UserProgramEntries, _UserProgramAcquiring, _UserProgramPollOwner, _UserProgramGeneration, _UserProgramPaused
	SavedLevel := LOGGER_MIN_LEVEL, SavedDir := _ConfigDir, SavedRetained := _ConfigTransitionRetainedBarrier
	SavedProgramsGeneration := _UserProgramGeneration, SavedProgramsPaused := _UserProgramPaused
	SplitPath(Path, , &Cfg)
	Eval := _CLW_Eval, Scheduler := TimerArmOneShotMs, Launcher := LifecycleLaunchSuccessor, PortOwner := ReloadSuccessorPort, _CRAW_NoticePort := NotifierSend
	Scripts := [], Scheduled := [], Launches := 0, _CRAW_NoticeCalls := 0, Bundle := 0, NewBundle := 0, Port := _RTP_NewPort()
	BackupLevel := LOGGER_DEFAULT_LEVEL == "DEBUG" ? "INFO" : "DEBUG"
	RecordEval(Self, Js, Context := 0, NotifyFn := 0) {
		Scripts.Push(Js)
		return true
	}
	RecordSchedule(Self, Callback, Delay) {
		Scheduled.Push({callback: Callback, delay: Delay})
		if Mode == "timer-throw"
			throw Error("")
		if Mode == "timer-false"
			return false
		if Mode == "inline-then-throw" {
			AssertTrue(Callback.Call(), "the exact reload handoff genuinely completes before the scheduler observer raises")
			throw Error("Injected observer error after inline native-boundary completion.")
		}
		return true
	}
	Launch(Self) {
		Launches += 1
		AssertEqual(0, A_IsCritical, "native successor admission stays outside the RAM-only state transition")
		if Mode == "reentrant-launch" && Launches == 1
			AssertFalse(Scheduled[1].callback.Call(), "a reentrant retained callback cannot borrow in-progress launch authority")
		if Mode == "sync-refusal" && Launches == 1
			throw Error("Injected native successor launch refusal.")
		return Map("pid", RTP_FAKE_SUCCESSOR_PID)
	}
	GetPort(Self) {
		return Port
	}
	SuppressNativeNotice(Self, Text, Options := 0) {
		AssertEqual(0, A_IsCritical, "native refusal reporting stays outside the RAM-only transition")
		_CRAW_NoticeCalls += 1
		return true
	}
	for Observer in [Eval, Scheduler, Launcher, PortOwner, _CRAW_NoticePort]
		AssertFalse(Observer.HasOwnProp("Call"), "the fixture cannot remove another callback port")
	try {
		AssertFalse(ReleaseInstall_Busy())
		AssertFalse(_ConfigWriteTerminalIsActive())
		AssertFalse(ReloadTerminalHandoffPending())
		AssertFalse(IsObject(SavedRetained))
		AssertEqual(0, _UserProgramEntries.Count)
		AssertFalse(IsObject(_UserProgramAcquiring) || IsObject(_UserProgramPollOwner))
		AssertFalse(A_IsSuspended, "the component does not borrow real suspended input ownership")
		_ConfigDir := Cfg
		LOGGER_MIN_LEVEL := BackupLevel
		Header := "[_meta]`nschema_version = " . _CRAWC_SchemaVersion . "`n[script]`n"
		AssertTrue(FSWriteCreateDurable(Path, Header . 'log_level = "' . BackupLevel . '"' . "`n"))
		Rules := ConfigBackup_Rules()
		Backup := ConfigBackup_Create(Cfg, "pre_install", "", "", Rules,
			() => Map("stamp", "20261028-202000", "iso", "2026-10-28T19:20:00Z"))
		Expected := FSReadUtf8Exact(Path)
		LOGGER_MIN_LEVEL := LOGGER_DEFAULT_LEVEL
		AssertTrue(FSWriteDurable(Path, Header . 'log_level = "' . LOGGER_DEFAULT_LEVEL . '"' . "`n"))
		Current := FSReadUtf8Exact(Path)
		if Mode == "write-refusal"
			AssertTrue(FSWriteCreateDurable(Path . ".ergopti-restore.tmp", "foreign stage`n"))
		Eval.DefineProp("Call", {Call: RecordEval})
		Scheduler.DefineProp("Call", {Call: RecordSchedule})
		Launcher.DefineProp("Call", {Call: Launch})
		PortOwner.DefineProp("Call", {Call: GetPort})
		_CRAW_NoticePort.DefineProp("Call", {Call: SuppressNativeNotice})
		Result := _CLW_RestoreBackup(Mode == "missing" ? "missing-backup-id" : Backup["id"])
		if Mode == "missing" {
			AssertFalse(Result)
			AssertFalse(_ConfigWriteTerminalIsActive(), "ordinary pre-publication refusal releases its exact owner")
			AssertFalse(ConfigTransitionRetainedBarrier())
			AssertEqual(Current, FSReadUtf8Exact(Path))
			AssertEqual(0, Scheduled.Length)
			return
		}
		Bundle := _ConfigWriteLeaseState().terminal
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		if Mode == "write-refusal" {
			AssertFalse(Result)
			AssertEqual(Current, FSReadUtf8Exact(Path))
			AssertEqual("foreign stage`n", FSReadUtf8Exact(Path . ".ergopti-restore.tmp"))
			AssertEqual(0, Scheduled.Length)
		} else {
			AssertEqual(Expected, FSReadUtf8Exact(Path))
			AssertEqual(1, Scheduled.Length)
		}
		if Mode == "timer-throw" || Mode == "timer-false" || Mode == "write-refusal" {
			AssertFalse(Result)
			AssertEqual(Bundle, ConfigTransitionRetainedBarrier())
			AssertEqual(0, Launches)
			if Scheduled.Length
				AssertFalse(Scheduled[1].callback.Call(), "a rejected timer cannot later transfer its bundle")
		} else if Mode == "stale-timer" {
			AssertTrue(Result)
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
			NewBundle := _ConfigWriteTerminalTryAcquire([Path])
			AssertTrue(_ConfigWriteTerminalOwnsExact(NewBundle, Path))
			AssertFalse(Scheduled[1].callback.Call())
			AssertEqual(0, Launches)
			AssertTrue(_ConfigWriteTerminalOwnsExact(NewBundle, Path), "a queued old callback preserves its successor's real terminal lease")
			return
		} else {
			AssertTrue(Result)
			if Mode != "inline-then-throw"
				Accepted := Scheduled[1].callback.Call()
			if Mode == "sync-refusal" {
				AssertFalse(Accepted)
				AssertEqual(Bundle, ConfigTransitionRetainedBarrier())
			} else {
				Pending := ReloadTerminalHandoffPending()
				AssertTrue(Pending is Map && Pending["bundle"] == Bundle, "the actual reload coordinator owns this exact restore bundle")
				AssertEqual(1, Launches)
				AssertFalse(Scheduled[1].callback.Call(), "the bound timer cannot launch twice")
				AssertEqual(1, Launches)
				if Mode == "async-refusal" {
					AssertTrue(ReloadTerminalHandoffRefuse(Pending, "controlled native successor refusal"))
					Port["probe"]["alive"] := false
					loop 4
						_RTP_RunArmed(Port)
					AssertFalse(_ReloadTerminalHandoffOwns(Pending))
					AssertEqual(Bundle, ConfigTransitionRetainedBarrier())
				} else
					return
			}
		}
		AssertEqual(1, _CRAW_NoticeCalls, "a refused restore reload reaches the existing localized notice exactly once")
		if Scheduled.Length
			AssertFalse(Scheduled[1].callback.Call(), "replaying a refused callback cannot notify again")
		AssertEqual(1, _CRAW_NoticeCalls)
		AssertEqual(0, _ConfigFullSaveRequest(true), "a surviving old runtime cannot enqueue a save over retained restored disk")
		Port["probe"]["alive"] := true
		BeforeManual := Launches
		AssertTrue(ReloadPreservingSuspend(), "the actual plain Reload reuses the retained owner and remains recoverable")
		Pending := ReloadTerminalHandoffPending()
		AssertTrue(Pending is Map && Pending["bundle"] == Bundle)
		AssertEqual(BeforeManual + 1, Launches)
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle))
		AssertEqual(Mode == "write-refusal" ? Current : Expected, FSReadUtf8Exact(Path), "the actual manual reload settlement cannot restore obsolete RAM")
	} finally {
		if NewBundle is Object
			_RTP_Cleanup(NewBundle)
		if Bundle is Object
			_RTP_Cleanup(Bundle)
		for Observer in [Eval, Scheduler, Launcher, PortOwner, _CRAW_NoticePort]
			if Observer.HasOwnProp("Call")
				Observer.DeleteProp("Call")
		_ConfigTransitionRetainedBarrier := SavedRetained
		LOGGER_MIN_LEVEL := SavedLevel, _ConfigDir := SavedDir
		_UserProgramGeneration := SavedProgramsGeneration, _UserProgramPaused := SavedProgramsPaused
	}
}
try {
	LoggerInit()
	Modes := ["missing", "write-refusal", "timer-throw", "timer-false", "sync-refusal", "async-refusal", "duplicate-timer", "stale-timer", "inline-then-throw", "reentrant-launch"]
	for CaseMode in Modes {
		CaseDir := _EDOS_Root . "\cases\" . CaseMode
		FSEnsureDirectoryStrict(CaseDir)
		ConfigurationFile := CaseDir . "\config.toml"
		_CRAW_Lifecycle(CaseMode, ConfigurationFile)
		FileAppend("RESTORE_LIFECYCLE_CASE_PASS=" . CaseMode . "`n", "*")
	}
	FileAppend("RESTORE_LIFECYCLE_ALL_PASS=" . Modes.Length . "`n", "*")
	ExitApp(0)
} catch as _CRAWC_StartupFailure {
	_CRAWC_Error(_CRAWC_StartupFailure, "")
}
