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
; (platform/remap/lalt.ahk, platform/remap/tab.ahk) was misreported to
; the user as a driver crash via the full ErgoptiGlobalErrorHandler
; crash-report/toast pipeline. GestureGetCyclableWindows (the sibling in
; modules/gestures/window_cycle.ahk) was correctly hardened for the identical
; race (commit 7b701020d); this file was never touched by that campaign.
;
; SCOPE: source introspection of infra/window_utils.ahk. The cyclers themselves
; are not unit-testable without a live desktop (see tests/unit/test_window_utils.ahk).
;
; MOVED, NOT WEAKENED — 2026-08-03. The enumeration and its guards now live in
; _AltTabCycle, shared by AltTabMonitor (this display) and AltTabAll (anywhere),
; so the assertions below follow it there. That refactor is what makes the
; invariant hold by construction rather than by discipline: the failure this file
; exists to prevent is "the guard was applied per-site and one sibling was
; missed", and two cyclers sharing one guarded loop have no second site to miss.
; The last section pins exactly that — if either public cycler ever grows its own
; enumeration, this file fails, because that is the moment the sibling reappears.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================================================
; ===============================================================
; ======= 1/ Per-window try has a catch that continues =========
; ===============================================================
; ===============================================================

_ATMC_CheckCatchPresentAndContinues() {
	Body := _DriverFuncBody("_AltTabCycle")
	Assert(Body != "", "_AltTabCycle must exist in infra/window_utils.ahk — it carries the enumeration both public cyclers share")

	TryPos := InStr(Body, "try {")
	Assert(TryPos > 0, "_AltTabCycle must wrap the per-window enumeration body in a try")

	CatchPos := InStr(Body, "} catch", , TryPos)
	Assert(CatchPos > 0,
		"_AltTabCycle: the per-window try must have a catch clause — a bare try with no catch aborts the whole enumeration when one window throws, misreported as a driver crash at the tap-hold call sites (project-ahk-invariant-incomplete-application)")

	CatchBody := SubStr(Body, CatchPos, 300)
	Assert(InStr(CatchBody, "Logger") > 0,
		"_AltTabCycle: the catch clause must log the skipped window so a real regression is diagnosable, not silently invisible")
	Assert(InStr(CatchBody, "continue") > 0,
		"_AltTabCycle: the catch clause must continue the loop so one window's exception does not abort the whole per-monitor cycle")
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
	Body := _DriverFuncBody("_AltTabCycle")
	Assert(Body != "", "_AltTabCycle must exist in infra/window_utils.ahk — it carries the enumeration both public cyclers share")

	ActPos := InStr(Body, "WinActivate(")
	Assert(ActPos > 0, "_AltTabCycle must still activate a window")

	; Bounded look-back: only the statements immediately before the call can
	; establish that it sits inside a try.
	HeadStart := (ActPos > 200) ? ActPos - 200 : 1
	Head := SubStr(Body, HeadStart, ActPos - HeadStart)
	Assert(InStr(Head, "try {") > 0,
		"_AltTabCycle: WinActivate must sit inside a try — the activation target can die between enumeration and activation, exactly like the windows the loop above already guards")

	Tail := SubStr(Body, ActPos, 400)
	Assert(InStr(Tail, "catch as") > 0,
		"_AltTabCycle: the activation must have an explicit catch")
	Assert(InStr(Tail, "continue") > 0,
		"AltTabMonitor: a vanished activation target must fall through to the next candidate, not abort the cycle — the user's alt-tab should still do something useful")
}
Test("window_utils: AltTabMonitor guards the activation as well as the enumeration",
	_ATMC_ActivationIsGuardedToo)




; ==================================================================
; ==================================================================
; ======= 2/ Both cyclers go through the one guarded loop ==========
; ==================================================================
; ==================================================================

; The whole point of the shared loop. This file was written because a hardening
; campaign fixed GestureGetCyclableWindows and missed AltTabMonitor — the same
; invariant, applied per-site, one sibling forgotten. AltTabAll arrived in
; 2026-08-03 as a second per-monitor-less cycler; written as its own enumeration
; it would have been a third site to forget, and the obvious way to write it
; (copy the body, delete the monitor check) is exactly how that happens.
;
; So the guard is not "each cycler has a try/catch" but "there is only one
; cycler". A public cycler that calls WinGetList itself has stopped delegating,
; and that is the moment the sibling comes back.
_ATMC_PublicCyclersDelegate() {
	for _, Name in ["AltTabMonitor", "AltTabAll"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist in infra/window_utils.ahk")
		Assert(InStr(Body, "_AltTabCycle(") > 0,
			Name . " must delegate to _AltTabCycle — it is the only enumeration that carries the "
			. "mid-cycle-close guards, and a cycler with its own loop is the sibling this file exists to catch")
		Assert(InStr(Body, "WinGetList(") = 0,
			Name . " must not enumerate windows itself. Two enumerations mean two places to harden, and "
			. "the second one is the one that gets missed — which is how this test came to be written.")
	}
}
Test("window_utils: both public cyclers delegate to the single guarded enumeration",
	_ATMC_PublicCyclersDelegate)

; The monitor-scoped cycler must NOT quietly fall back to the unscoped one when
; the cursor sits on no monitor (a real state during a display change). Doing so
; would switch to a window on another screen — the user asked for this screen, so
; the fallback is a switch they then have to undo, which is worse than nothing.
_ATMC_MonitorCyclerDoesNotFallBack() {
	Body := _DriverFuncBody("AltTabMonitor")
	Assert(Body != "", "AltTabMonitor must exist in infra/window_utils.ahk")
	Assert(InStr(Body, "AltTabAll(") = 0,
		"AltTabMonitor must not call AltTabAll: with the cursor off every monitor, cycling anywhere "
		. "instead of nowhere focuses a window on the wrong screen, which the user has to undo")
	Assert(InStr(Body, "ALT_TAB_ANY_MONITOR") > 0,
		"AltTabMonitor must compare against the named sentinel rather than a bare 0, so the "
		. "'cursor is on no monitor' branch stays legible")
}
Test("window_utils: the per-monitor cycler does not fall back to cycling anywhere",
	_ATMC_MonitorCyclerDoesNotFallBack)
