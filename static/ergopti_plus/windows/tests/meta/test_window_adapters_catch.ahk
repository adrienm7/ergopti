; tests/meta/test_window_adapters_catch.ahk

; ==============================================================================
; MODULE: WMGetList/WIGetAll Bare-Try Meta Test (Pattern 3 sibling)
; DESCRIPTION:
; Regression guard for the documented "bare try with no catch" anti-pattern
; (docs/PROJECT_MEMORY.md's project-ahk-invariant-incomplete-application).
; GestureGetCyclableWindows (modules/gestures/window_cycle.ahk) was correctly
; hardened (commit 7b701020d) with a per-window try/catch for the routine
; race where a window closes between WinGetList() and the next WinGet* call
; on its HWND. The two adapter siblings that enumerate the exact same window
; list — WMGetList (adapters/window_manager.ahk) and WIGetAll
; (adapters/window_info.ahk) — were never touched by that campaign.
;
; SCOPE: source introspection of adapters/window_manager.ahk and
; adapters/window_info.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================================================
; ===============================================================
; ======= 1/ WMGetList's per-window try has a catch =============
; ===============================================================
; ===============================================================

_TWAC_WMGetListHasCatchAndContinues() {
	Body := _DriverFuncBody("WMGetList")
	Assert(Body != "", "WMGetList must exist in adapters/window_manager.ahk")

	ForPos := InStr(Body, "for HWND in HWNDs")
	Assert(ForPos > 0, "WMGetList must enumerate HWNDs with a for loop")

	TryPos := InStr(Body, "try {", , ForPos)
	Assert(TryPos > 0, "WMGetList must wrap the per-window enumeration body in a try")

	CatchPos := InStr(Body, "} catch", , TryPos)
	Assert(CatchPos > 0,
		"WMGetList: the per-window try must have a catch clause — a bare try with no catch aborts the whole enumeration when one window throws (project-ahk-invariant-incomplete-application)")

	CatchBody := SubStr(Body, CatchPos, 300)
	Assert(InStr(CatchBody, "Logger") > 0,
		"WMGetList: the catch clause must log the skipped window so a real regression is diagnosable, not silently invisible")
	Assert(InStr(CatchBody, "continue") > 0,
		"WMGetList: the catch clause must continue the loop so one window's exception does not abort the whole list")
}
Test("window_manager: WMGetList's per-window try has a catch that logs and continues (bare-try-anti-pattern)",
	_TWAC_WMGetListHasCatchAndContinues)




; ===============================================================
; ===============================================================
; ======= 2/ WIGetAll's per-window try has a catch ===============
; ===============================================================
; ===============================================================

_TWAC_WIGetAllHasCatchAndContinues() {
	Body := _DriverFuncBody("WIGetAll")
	Assert(Body != "", "WIGetAll must exist in adapters/window_info.ahk")

	ForPos := InStr(Body, "for HWND in HWNDs")
	Assert(ForPos > 0, "WIGetAll must enumerate HWNDs with a for loop")

	TryPos := InStr(Body, "try {", , ForPos)
	Assert(TryPos > 0, "WIGetAll must wrap the per-window enumeration body in a try")

	CatchPos := InStr(Body, "} catch", , TryPos)
	Assert(CatchPos > 0,
		"WIGetAll: the per-window try must have a catch clause — a bare try with no catch aborts the whole enumeration when one window throws (project-ahk-invariant-incomplete-application)")

	CatchBody := SubStr(Body, CatchPos, 300)
	Assert(InStr(CatchBody, "Logger") > 0,
		"WIGetAll: the catch clause must log the skipped window so a real regression is diagnosable, not silently invisible")
	Assert(InStr(CatchBody, "continue") > 0,
		"WIGetAll: the catch clause must continue the loop so one window's exception does not abort the whole enumeration")
}
Test("window_info: WIGetAll's per-window try has a catch that logs and continues (bare-try-anti-pattern)",
	_TWAC_WIGetAllHasCatchAndContinues)
