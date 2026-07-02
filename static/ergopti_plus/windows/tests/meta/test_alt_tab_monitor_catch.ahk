; tests/meta/test_alt_tab_monitor_catch.ahk

; ==============================================================================
; MODULE: AltTabMonitor Bare-Try Meta Test (Pattern 3 sibling)
; DESCRIPTION:
; Regression guard for the documented "bare try with no catch" anti-pattern
; (docs/PROJECT_MEMORY.md's project-ahk-invariant-incomplete-application).
; AltTabMonitor (lib/window_utils.ahk) enumerates every top-level window and
; calls several WinGet* functions per window with NO try/catch at all — a
; window closing mid-enumeration (a routine race, not a bug) threw
; TargetError uncaught, which for the two tap-hold hotkey call sites
; (modules/tap_holds/lalt.ahk, modules/tap_holds/tab.ahk) was misreported to
; the user as a driver crash via the full ErgoptiGlobalErrorHandler
; crash-report/toast pipeline. GestureGetCyclableWindows (the sibling in
; modules/gestures/window_cycle.ahk) was correctly hardened for the identical
; race (commit 7b701020d); this file was never touched by that campaign.
;
; SCOPE: source introspection of lib/window_utils.ahk. AltTabMonitor itself is
; not unit-testable without a live desktop (see tests/unit/test_window_utils.ahk).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================================================
; ===============================================================
; ======= 1/ Per-window try has a catch that continues =========
; ===============================================================
; ===============================================================

_ATMC_CheckCatchPresentAndContinues() {
	Body := _DriverFuncBody("AltTabMonitor")
	Assert(Body != "", "AltTabMonitor must exist in lib/window_utils.ahk")

	TryPos := InStr(Body, "try {")
	Assert(TryPos > 0, "AltTabMonitor must wrap the per-window enumeration body in a try")

	CatchPos := InStr(Body, "} catch", , TryPos)
	Assert(CatchPos > 0,
		"AltTabMonitor: the per-window try must have a catch clause — a bare try with no catch aborts the whole enumeration when one window throws, misreported as a driver crash at the tap-hold call sites (project-ahk-invariant-incomplete-application)")

	CatchBody := SubStr(Body, CatchPos, 300)
	Assert(InStr(CatchBody, "Logger") > 0,
		"AltTabMonitor: the catch clause must log the skipped window so a real regression is diagnosable, not silently invisible")
	Assert(InStr(CatchBody, "continue") > 0,
		"AltTabMonitor: the catch clause must continue the loop so one window's exception does not abort the whole per-monitor cycle")
}
Test("window_utils: AltTabMonitor's per-window try has a catch that logs and continues (bare-try-anti-pattern)",
	_ATMC_CheckCatchPresentAndContinues)
