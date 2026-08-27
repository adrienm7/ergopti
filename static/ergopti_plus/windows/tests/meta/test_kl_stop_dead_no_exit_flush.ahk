; tests/meta/test_kl_stop_dead_no_exit_flush.ahk

; ==============================================================================
; MODULE: Keylogger Event-Id Collision Guard Meta Test
; DESCRIPTION:
; Static source guard for the "kl-stop-dead-no-exit-flush" finding.
;
; A Reload mid-burst can lose the final flush window, leaving the persisted
; next_event_id in state.json LAGGING the true max id already written to
; data.sql. On the next launch KL_AllocEventId would re-mint ids that already
; exist; the schema's INSERT OR IGNORE INTO events_* (device_id, id, ...) then
; SILENTLY DROPS the colliding rows - permanent, invisible data loss.
;
; The OnExit(Ergopti_OnShutdown) -> KL_Stop flush seam (the other half of this
; finding) is guarded by meta/test_no_onexit_keylogger_flush.ahk. THIS test
; guards the id-reuse defence: KL_Init must NOT trust state.json alone - it must
; scan data.sql for the highest id already persisted for this device and resolve
; next_event_id to one past it. The fix adds the pure helpers KL_ScanMaxEventId
; and KL_ResolveStartId and wires them into KL_Init after KL_LoadState.
;
; Meta-static because keylogger.ahk registers top-level hooks/timers and cannot
; be #Included by the headless runner without blocking clean exit. If the
; hardening is removed or stops being wired into KL_Init, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_KLSD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ====================================================
; ====================================================
; ======= 2/ Id-collision hardening assertions =======
; ====================================================
; ====================================================

_KLSD_HardeningHelpersExist() {
	ScanBody := _DriverFuncBody("KL_ScanMaxEventId")
	ResolveBody := _DriverFuncBody("KL_ResolveStartId")
	Assert(ScanBody != "",
		"KL_ScanMaxEventId must exist in the driver source and scan the durable ledger tail")
	Assert(ResolveBody != "",
		"KL_ResolveStartId must exist in the driver source and keep event identifiers monotonic")
}
Test("keylogger: id-collision hardening helpers exist (kl-stop-dead-no-exit-flush)", _KLSD_HardeningHelpersExist)

_KLSD_InitWiresHardening() {
	Src := _KLSD_ReadSource("modules/keylogger/keylogger.ahk")
	Seg := _DriverFuncBody("KL_Init")
	Assert(Seg != "", "KL_Init(metrics_dir) declaration must exist in keylogger.ahk")
	Assert(InStr(Seg, "KL_ResolveStartId(") > 0,
		"KL_Init must call KL_ResolveStartId to correct next_event_id after KL_LoadState - trusting state.json alone re-mints ids that INSERT OR IGNORE silently drops")
	Assert(InStr(Seg, "KL_ScanMaxEventId(") > 0,
		"KL_Init must scan data.sql via KL_ScanMaxEventId so the resolved start id is one past the highest id already on disk for this device")
}
Test("keylogger: KL_Init resolves next_event_id against data.sql (kl-stop-dead-no-exit-flush)", _KLSD_InitWiresHardening)


_KLSD_LifecycleFailsClosedAndLogsCentrally() {
	InitBody := _DriverFuncBody("KL_Init")
	StopBody := _DriverFuncBody("KL_Stop")
	Main := _KLSD_ReadSource("ErgoptiPlus.ahk")
	Lifecycle := _KLSD_ReadSource("infra/lifecycle.ahk")
	Module := _KLSD_ReadSource("modules/keylogger/keylogger.ahk")
	BootstrapAt := InStr(InitBody, "KL_BootstrapDataSql()")
	PublishAt := InStr(InitBody, "Keylogger.initialized := true")
	Assert(BootstrapAt > 0 and PublishAt > BootstrapAt,
		"KL_Init must prove the ledger before publishing initialized state")
	Assert(InStr(Main, "KeyloggerReady := KL_Init(") > 0
		and InStr(Main, "if !KeyloggerReady") > 0,
		"startup must consume KL_Init failure before starting keylogger producers")
	JournalAt := InStr(StopBody, "_KL_JournalPendingEntries()")
	StoppedAt := InStr(StopBody, "Keylogger.initialized := false")
	Assert(JournalAt > 0 and StoppedAt > JournalAt
		and InStr(SubStr(StopBody, JournalAt, StoppedAt - JournalAt),
			'if !FlushComplete or !JournalResult["ok"]') > 0,
		"KL_Stop must retain initialized state when the final journal handoff fails")
	Assert(InStr(Lifecycle, "KeyloggerStopped := KL_Stop()") > 0
		and InStr(Lifecycle, "if !KeyloggerStopped") > 0,
		"OnExit must consume terminal keylogger persistence failure")
	Assert(InStr(Module, "Keylogger.log", true) = 0
		and InStr(Module, 'HasProp("log")', true) = 0,
		"persistence diagnostics must use the initialized central logger, never a dead optional sink")
}
Test("keylogger lifecycle: init and stop fail closed (keylogger-lifecycle-fail-closed)",
	_KLSD_LifecycleFailsClosedAndLogsCentrally)
