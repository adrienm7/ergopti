; tests/meta/test_alt_tab_monitor_catch.ahk

; ==============================================================================
; MODULE: AltTabMonitor Bare-Try Meta Test (Pattern 3 sibling)
; DESCRIPTION:
; Regression guard for the documented "bare try with no catch" anti-pattern
; (docs/PROJECT_MEMORY.md's project-ahk-invariant-incomplete-application).
; AltTabMonitor (infra/window_utils.ahk) enumerates every top-level window and
; calls several WinGet* functions per window with NO try/catch at all — a
; window closing mid-enumeration (a routine race, not a bug) threw
; TargetError uncaught, which for the two tap-hold hotkey call sites
; (modules/tap_holds/lalt.ahk, modules/tap_holds/tab.ahk) was misreported to
; the user as a driver crash via the full ErgoptiGlobalErrorHandler
; crash-report/toast pipeline. GestureGetCyclableWindows (the sibling in
; modules/gestures/window_cycle.ahk) was correctly hardened for the identical
; race (commit 7b701020d); this file was never touched by that campaign.
;
; SCOPE: source introspection of infra/window_utils.ahk. AltTabMonitor itself is
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
	Assert(Body != "", "AltTabMonitor must exist in infra/window_utils.ahk")

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

; The activation is the OTHER half of the same race. The enumeration above
; guards every WinGet* against a window closing mid-cycle, then the original
; code called WinActivate on the survivor one line OUTSIDE that guard — so the
; identical TOCTOU, landing on the one window that passed filtering, threw
; TargetError and aborted the alt-tab. Guarding only the enumeration is the
; documented "invariant applied per-site, one sibling missed" shape.
_ATMC_ActivationIsGuardedToo() {
	Body := _DriverFuncBody("AltTabMonitor")
	Assert(Body != "", "AltTabMonitor must exist in infra/window_utils.ahk")

	ActPos := InStr(Body, "WinActivate(")
	Assert(ActPos > 0, "AltTabMonitor must still activate a window")

	; Bounded look-back: only the statements immediately before the call can
	; establish that it sits inside a try.
	HeadStart := (ActPos > 200) ? ActPos - 200 : 1
	Head := SubStr(Body, HeadStart, ActPos - HeadStart)
	Assert(InStr(Head, "try {") > 0,
		"AltTabMonitor: WinActivate must sit inside a try — the activation target can die between enumeration and activation, exactly like the windows the loop above already guards")

	Tail := SubStr(Body, ActPos, 400)
	Assert(InStr(Tail, "catch as") > 0,
		"AltTabMonitor: the activation must have an explicit catch")
	Assert(InStr(Tail, "continue") > 0,
		"AltTabMonitor: a vanished activation target must fall through to the next candidate, not abort the cycle — the user's alt-tab should still do something useful")
}
Test("window_utils: AltTabMonitor guards the activation as well as the enumeration",
	_ATMC_ActivationIsGuardedToo)
