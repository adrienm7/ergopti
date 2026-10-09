; tests/meta/test_keylogger_pause_guard.ahk

; ==============================================================================
; MODULE: Keylogger Pause-Guard Meta Test
; DESCRIPTION:
; Static source guard for the two critical "pause = tout eteint" findings
; (sensors-bypass-pause-suspend, keylogger-telemetry-ignores-suspend).
;
; keylogger.ahk registers an InputHook + ~10 SetTimer / OnClipboardChange
; telemetry sources, all of which bypass native Suspend. KL_AppendLog is the
; single chokepoint every telemetry entry funnels through, so it must early-
; return when A_IsSuspended — otherwise the keylogger keeps writing PII to
; today.log / data.sql while the driver is paused. The guard must EXEMPT
; type "system_event" so the pause/resume lifecycle markers still log.
;
; This is a meta-static test (scans source text) because keylogger.ahk
; registers top-level hooks/timers and cannot be #Included by the headless
; runner without blocking clean exit. If the guard is removed or stops
; exempting system_event, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_KLPG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ==================================================
; ==================================================
; ======= 2/ Chokepoint guard assertions ===========
; ==================================================
; ==================================================

_KLPG_AppendLogHasPauseGuard() {
	Src := _KLPG_ReadSource("modules/keylogger/keylogger.ahk")
	Seg := _DriverFuncBody("KL_AppendLog")
	Assert(Seg != "", "KL_AppendLog(entry) declaration must exist in keylogger.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"KL_AppendLog must early-return on A_IsSuspended — it is the telemetry chokepoint; without this the keylogger writes PII while paused")
}
Test("keylogger: KL_AppendLog has an A_IsSuspended pause guard (chokepoint)", _KLPG_AppendLogHasPauseGuard)

_KLPG_AppendLogExemptsSystemEvent() {
	Src := _KLPG_ReadSource("modules/keylogger/keylogger.ahk")
	Seg := _DriverFuncBody("KL_AppendLog")
	Assert(InStr(Seg, "system_event") > 0,
		"KL_AppendLog pause guard must exempt type system_event so the pause/resume lifecycle markers still log while suspended")
}
Test("keylogger: KL_AppendLog pause guard exempts system_event markers", _KLPG_AppendLogExemptsSystemEvent)
