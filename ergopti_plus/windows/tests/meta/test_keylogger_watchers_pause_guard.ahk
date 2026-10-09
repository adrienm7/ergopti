; tests/meta/test_keylogger_watchers_pause_guard.ahk

; ==============================================================================
; MODULE: Keylogger Watchers Pause-Guard Meta Test
; DESCRIPTION:
; Static source guard for the "keylogger-watchers-bypass-pause" finding.
; Keylogger idle/session/power timers and OnMessage handlers must not write
; to disk while the driver is paused.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLLG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_KLLG_IdleTickHasPauseGuard() {
	Src := _KLLG_ReadSource("modules/keylogger/keylogger_watchers.ahk")
	Seg := _DriverFuncBody("KL_Watchers_IdleTick")
	Assert(Seg != "", "KL_Watchers_IdleTick declaration must exist")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"KL_Watchers_IdleTick must early-return on A_IsSuspended (keylogger-watchers-bypass-pause)")
}
Test("keylogger_watchers: KL_Watchers_IdleTick has an A_IsSuspended pause guard", _KLLG_IdleTickHasPauseGuard)

_KLLG_OnSessionChangeHasPauseGuard() {
	Src := _KLLG_ReadSource("modules/keylogger/keylogger_watchers.ahk")
	Seg := _DriverFuncBody("KL_Watchers_OnSessionChange")
	Assert(Seg != "", "KL_Watchers_OnSessionChange declaration must exist")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"KL_Watchers_OnSessionChange must early-return on A_IsSuspended (keylogger-watchers-bypass-pause)")
}
Test("keylogger_watchers: KL_Watchers_OnSessionChange has an A_IsSuspended pause guard", _KLLG_OnSessionChangeHasPauseGuard)

_KLLG_OnPowerBroadcastHasPauseGuard() {
	Src := _KLLG_ReadSource("modules/keylogger/keylogger_watchers.ahk")
	Seg := _DriverFuncBody("KL_Watchers_OnPowerBroadcast")
	Assert(Seg != "", "KL_Watchers_OnPowerBroadcast declaration must exist")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"KL_Watchers_OnPowerBroadcast must early-return on A_IsSuspended (keylogger-watchers-bypass-pause)")
}
Test("keylogger_watchers: KL_Watchers_OnPowerBroadcast has an A_IsSuspended pause guard", _KLLG_OnPowerBroadcastHasPauseGuard)
