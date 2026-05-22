; static/drivers/autohotkey/tests/test_window_utils.ahk

; ==============================================================================
; MODULE: Window Utilities Tests
; DESCRIPTION:
; Tests for the pure geometry helpers in lib/window_utils.ahk.
; GetMonitorFromPoint is tested by stubbing MonitorGetCount and MonitorGet
; via a wrapper seam; AltTabMonitor is not testable without a live desktop.
; ==============================================================================






; =========================================
; ======================================
; ======= 1/ GetMonitorFromPoint =======
; ======================================
; =========================================

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
