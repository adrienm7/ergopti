; tests/meta/test_layout_poll_suspend_guard.ahk

; ==============================================================================
; MODULE: Layout Poll Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the layout-poll-reload-unpauses finding.
;
; CheckKeyboardLayoutChange() is a recurring SetTimer callback that calls
; Reload() when the foreground keyboard layout changes. Reload() restarts the
; driver from scratch — always in the unpaused state. Without a suspend guard,
; any keyboard layout switch while the driver is paused would silently clear
; the user's pause state and restart the driver as active.
;
; The fix adds `if A_IsSuspended return` at the top of the function so the
; poll tick is a no-op while paused. The layout change will be handled at
; the next natural restart or when the user manually unpauses.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helper =====================
; ===================================================
; ===================================================

_LPSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Guard assertion ========================
; ===================================================
; ===================================================

_LPSG_LayoutPollHasSuspendGuard() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("CheckKeyboardLayoutChange")
	Assert(Seg != "", "CheckKeyboardLayoutChange must exist in ErgoptiPlus.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"CheckKeyboardLayoutChange must check A_IsSuspended — Reload() clears pause state; a layout switch while paused would silently unpause the driver")
}
Test("ErgoptiPlus: CheckKeyboardLayoutChange has A_IsSuspended guard (layout-poll-reload-unpauses)", _LPSG_LayoutPollHasSuspendGuard)
