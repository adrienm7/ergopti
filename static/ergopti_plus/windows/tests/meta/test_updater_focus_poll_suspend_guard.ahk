; tests/meta/test_updater_focus_poll_suspend_guard.ahk

; ==============================================================================
; MODULE: Updater + Focus-Poll Suspend-Guard Meta Test
; DESCRIPTION:
; Static source guard for the "no-suspend-guard-on-background-tick-and-focus-poll"
; finding.
;
; SetTimer callbacks are scheduled by the AHK timer subsystem and are NOT gated
; by native Suspend (A_IsSuspended). Two recurring callbacks therefore kept
; firing while the driver was paused, violating the documented "pause must
; silence ALL features" invariant:
;
;   1. PLC_Poll (adapters/process_lifecycle.ahk) fires every 250 ms, reading the
;      foreground window and fanning out to every focus callback (which downstream
;      feed keylogger app-switch events). It must early-return on A_IsSuspended.
;
;   2. Updater_BackgroundTick (modules/updater.ahk) dispatches a network check and can
;      pop a TrayTip + rebuild the tray menu. It must re-arm its next tick (so the
;      loop survives pause) but then skip the dispatch on A_IsSuspended.
;
; This is a meta-static test (scans source text) because both files register
; top-level timers/hooks and forcing A_IsSuspended in-process is not possible in
; the headless runner. If either guard is removed, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_UFPS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Suspend-guard assertions ==============
; ==================================================
; ==================================================

_UFPS_FocusPollHasSuspendGuard() {
	Src := _UFPS_ReadSource("adapters/process_lifecycle.ahk")
	Seg := _DriverFuncBody("PLC_Poll")
	Assert(Seg != "", "PLC_Poll() declaration must exist in process_lifecycle.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"PLC_Poll must early-return on A_IsSuspended — otherwise focus changes keep being observed and fanned out to callbacks while the driver is paused (no-suspend-guard-on-background-tick-and-focus-poll)")
}
Test("process_lifecycle: PLC_Poll has an A_IsSuspended guard (no-suspend-guard-on-background-tick-and-focus-poll)", _UFPS_FocusPollHasSuspendGuard)

_UFPS_BackgroundTickHasSuspendGuard() {
	Src := _UFPS_ReadSource("modules/updater.ahk")
	Seg := _DriverFuncBody("Updater_BackgroundTick")
	Assert(Seg != "", "Updater_BackgroundTick(*) declaration must exist in modules/updater.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"Updater_BackgroundTick must skip its network dispatch / TrayTip / menu rebuild on A_IsSuspended — otherwise update notifications keep popping while the driver is paused (no-suspend-guard-on-background-tick-and-focus-poll)")
}
Test("updater: Updater_BackgroundTick has an A_IsSuspended guard (no-suspend-guard-on-background-tick-and-focus-poll)", _UFPS_BackgroundTickHasSuspendGuard)
