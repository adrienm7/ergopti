; tests/meta/modules/updater/test_updater_background_tick_suspend_guard.ahk

; ==============================================================================
; MODULE: Updater Background Tick Suspend-Guard Meta Test
; DESCRIPTION:
; Static source guard for the "no-suspend-guard-on-background-tick-and-focus-poll"
; finding.
;
; SetTimer callbacks are not gated by native Suspend. Updater_BackgroundTick
; dispatches a network check and can pop a TrayTip and rebuild the tray menu.
; It must re-arm its next tick (so the loop survives the pause) and then skip
; the dispatch while suspended.
;
; This stays a source scan: _Updater_BackgroundMayDispatch refuses a paused
; dispatch a second time, so removing the tick's own guard changes nothing a
; behaviour test could observe. The focus poll's guard of the same finding is
; observed under a real Suspend in
; tests/unit/core/process/test_lifecycle_app_events.ahk (a paused PLC_Poll
; re-baselines the process snapshot instead of replaying the pause).
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ Suspend-guard assertions =======
; ===========================================
; ===========================================

_UFPS_BackgroundTickHasSuspendGuard() {
	Seg := _DriverFuncBody("Updater_BackgroundTick")
	Assert(Seg != "", "Updater_BackgroundTick(*) declaration must exist in modules/updater")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"Updater_BackgroundTick must skip its network dispatch / TrayTip / menu rebuild on A_IsSuspended — otherwise update notifications keep popping while the driver is paused (no-suspend-guard-on-background-tick-and-focus-poll)")
}
Test("updater: Updater_BackgroundTick has an A_IsSuspended guard (no-suspend-guard-on-background-tick-and-focus-poll)", _UFPS_BackgroundTickHasSuspendGuard)
