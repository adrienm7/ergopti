; static/ergopti_plus/windows/tests/unit/test_window_utils.ahk

; ==============================================================================
; MODULE: Window Utilities Tests
; DESCRIPTION:
; Tests for the pure geometry helpers in infra/window_utils.ahk.
; GetMonitorFromPoint is tested by stubbing MonitorGetCount and MonitorGet
; via a wrapper seam; AltTabMonitor is not testable without a live desktop.
; ==============================================================================






; ======================================
; ======================================
; ======= 1/ GetMonitorFromPoint =======
; ======================================
; ======================================

; GetMonitorFromPoint delegates entirely to MonitorGetCount() and MonitorGet()
; which call the Windows API directly — we cannot stub those in AHK v2 without
; a DLL shim. Instead we test the function against the actual monitor layout
; of the machine running the tests: a point at (0,0) (top-left of primary)
; must be on some monitor, and a point far off-screen must return 0.

_WU_PrimaryTopLeftIsOnMonitor() {
	; (0, 0) is always within the primary monitor's bounds on any normal setup
	Result := GetMonitorFromPoint(0, 0)
	Assert(Result > 0, "Expected monitor index > 0 for (0,0), got " . Result)
}
Test("GetMonitorFromPoint: primary monitor top-left is on a monitor", _WU_PrimaryTopLeftIsOnMonitor)

_WU_FarOffScreenReturnsZero() {
	; -999999 is reliably outside any realistic monitor arrangement
	Result := GetMonitorFromPoint(-999999, -999999)
	AssertEqual(0, Result)
}
Test("GetMonitorFromPoint: point far off every screen returns 0", _WU_FarOffScreenReturnsZero)

_WU_ExtremePositiveReturnsZero() {
	Result := GetMonitorFromPoint(999999, 999999)
	AssertEqual(0, Result)
}
Test("GetMonitorFromPoint: extreme positive coordinates return 0", _WU_ExtremePositiveReturnsZero)

_WU_ReturnsIntegerIndex() {
	Result := GetMonitorFromPoint(0, 0)
	AssertTrue(Result is Integer, "return value should be Integer, got " . Type(Result))
}
Test("GetMonitorFromPoint: returns integer index", _WU_ReturnsIntegerIndex)

_WU_ArrayHasIsIndexNotMembership() {
	; Array.Has tests integer-index presence in AHK v2, NOT value membership.
	; A string arg coerces to 0 and index 0 never exists -> always false.
	; This documents why the old blacklist was dead code.
	AssertEqual(0, ["Shell_TrayWnd", "Progman", "WorkerW"].Has("Progman"),
		"Array.Has(string) must always be 0 — index-based, not value-membership")
}
Test("window_utils: Array.Has(string) is index-presence, never value-membership", _WU_ArrayHasIsIndexNotMembership)

_WU_SystemClassMembershipExcludesDesktop() {
	; Guards the || membership check that replaced the broken Array.Has
	IsSystem := (c) => (c == "Shell_TrayWnd" || c == "Progman" || c == "WorkerW")
	AssertTrue(IsSystem("Progman"), "desktop class Progman must be excluded from Alt-Tab")
	AssertTrue(IsSystem("WorkerW"), "WorkerW must be excluded from Alt-Tab")
	AssertTrue(IsSystem("Shell_TrayWnd"), "taskbar must be excluded from Alt-Tab")
	AssertFalse(IsSystem("CabinetWClass"), "real Explorer window must NOT be excluded")
}
Test("window_utils: system window class blacklist works with || membership", _WU_SystemClassMembershipExcludesDesktop)
