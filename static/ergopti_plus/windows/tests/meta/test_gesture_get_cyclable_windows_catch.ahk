; tests/meta/test_gesture_get_cyclable_windows_catch.ahk

; ==============================================================================
; MODULE: GestureGetCyclableWindows Bare-Try Meta Test (Pattern 3)
; DESCRIPTION:
; Regression guard for the documented "bare try with no catch"
; anti-pattern (docs/PROJECT_MEMORY.md's project-ahk-invariant-incomplete-
; application). GestureGetCyclableWindows enumerates every top-level window
; and calls several WinGet* functions per window; a window closing
; mid-enumeration (a routine race, not a bug) throws TargetError on the next
; WinGet* call for that HWnd. Without a catch, the whole enumeration aborts
; instead of just skipping that one window.
;
; SCOPE: source introspection of modules/gestures/window_cycle.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================================================
; ===============================================================
; ======= 1/ Per-window try has a catch that continues =========
; ===============================================================
; ===============================================================

_GGCWC_CheckCatchPresentAndContinues() {
	Body := _DriverFuncBody("GestureGetCyclableWindows")
	Assert(Body != "", "GestureGetCyclableWindows must exist in modules/gestures/window_cycle.ahk")

	TryPos := InStr(Body, "try {")
	Assert(TryPos > 0, "GestureGetCyclableWindows must wrap the per-window enumeration body in a try")

	CatchPos := InStr(Body, "} catch", , TryPos)
	Assert(CatchPos > 0,
		"GestureGetCyclableWindows: the per-window try must have a catch clause — a bare try with no catch aborts the whole enumeration when one window throws (project-ahk-invariant-incomplete-application)")

	; The catch must not silently swallow the failure — either log it or
	; explicitly continue past it (both are acceptable; total silence is not).
	CatchBody := SubStr(Body, CatchPos, 300)
	Assert(InStr(CatchBody, "Logger") > 0,
		"GestureGetCyclableWindows: the catch clause must log the skipped window so a real regression is diagnosable, not silently invisible")
	Assert(InStr(CatchBody, "continue") > 0,
		"GestureGetCyclableWindows: the catch clause must continue the loop so one window's exception does not abort the whole cyclable-windows list")
}
Test("gestures: GestureGetCyclableWindows's per-window try has a catch that logs and continues (bare-try-anti-pattern)",
	_GGCWC_CheckCatchPresentAndContinues)
