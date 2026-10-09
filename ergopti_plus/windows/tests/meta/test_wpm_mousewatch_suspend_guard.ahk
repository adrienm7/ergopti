; tests/meta/test_wpm_mousewatch_suspend_guard.ahk

; ==============================================================================
; MODULE: WPMWidget MouseWatch Suspend Guard
; DESCRIPTION:
; Regression guard for AHK-33: WPMWidget_MouseWatch fired every 50 ms via
; SetTimer while the driver was paused. AHK native Suspend only disarms
; Hotkeys/Hotstrings; SetTimer callbacks keep firing. Its sibling
; WPMWidget_Tick had the A_IsSuspended guard, MouseWatch did not — the
; "one missed sibling" pattern documented in PROJECT_MEMORY.
;
; The cost was a MouseGetPos + Hide() call every MOUSE_WATCH_MS while paused.
; Hide() was a Win32 no-op because Tick had already hidden the surface, so
; there was no visible behavioural leak, but G1 (strict pause invariant) was
; violated.
;
; Fix (AHK-33): add `if A_IsSuspended return` immediately after the visibility
; check in WPMWidget_MouseWatch, mirroring WPMWidget_Tick (ui/wpm/init.ahk:749).
;
; This test asserts (source introspection on ui/wpm/init.ahk):
;   WPMWidget_MouseWatch body must contain A_IsSuspended so the fast
;   cursor-watch goes fully quiet while the driver is paused.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================================
; ==============================================================
; ======= 1/ WPMWidget_MouseWatch gates on A_IsSuspended =======
; ==============================================================
; ==============================================================

_TWMSG_CheckSuspendGuard() {
	Body := _DriverFuncBody("WPMWidget_MouseWatch")
	Assert(Body != "", "WPMWidget_MouseWatch() must exist in ui/wpm/init.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"AHK-33: WPMWidget_MouseWatch must early-return on A_IsSuspended so the fast cursor-watch goes quiet while paused — its sibling WPMWidget_Tick already has this guard (metrics-timers-bypass-pause)")
}


Test("meta ahk-33: WPMWidget_MouseWatch gates on A_IsSuspended to mirror its sibling WPMWidget_Tick",
	_TWMSG_CheckSuspendGuard)
