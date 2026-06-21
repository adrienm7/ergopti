; tests/meta/test_timer_scheduler_pause_guard.ahk

; ==============================================================================
; MODULE: TimerScheduler Pause-Guard Meta Test
; DESCRIPTION:
; Static source guard for the "timer-scheduler-no-pause-guard" finding.
; TimerScheduler repeating/one-shot callbacks must not fire while the driver
; is paused.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSPG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TSPG_RepeatingHasPauseGuard() {
	Src := _TSPG_ReadSource("adapters/timer_scheduler.ahk")
	Seg := _DriverFuncBody("_Repeating")
	Assert(Seg != "", "_Repeating declaration must exist")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_Repeating must early-return on A_IsSuspended (timer-scheduler-no-pause-guard)")
}
Test("TimerScheduler: _Repeating has an A_IsSuspended pause guard", _TSPG_RepeatingHasPauseGuard)

_TSPG_OneShotHasPauseGuard() {
	Src := _TSPG_ReadSource("adapters/timer_scheduler.ahk")
	Seg := _DriverFuncBody("_OneShot")
	Assert(Seg != "", "_OneShot declaration must exist")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_OneShot must early-return on A_IsSuspended (timer-scheduler-no-pause-guard)")
}
Test("TimerScheduler: _OneShot has an A_IsSuspended pause guard", _TSPG_OneShotHasPauseGuard)

_TSPG_UsesLoggerError() {
	Src := _TSPG_ReadSource("adapters/timer_scheduler.ahk")
	Assert(InStr(Src, "LoggerError") > 0,
		"TimerScheduler must use LoggerError instead of OutputDebug (timer-callback-errors-to-outputdebug)")
}
Test("TimerScheduler: error logging uses LoggerError", _TSPG_UsesLoggerError)
