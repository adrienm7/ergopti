; tests/meta/suite/test_live_right_click_menu.ahk

; ==============================================================================
; MODULE: Live Right Click Menu
; DESCRIPTION: A native context menu runs its own message loop on the driver's
; only thread, so a live command sent after a right click was never answered: on
; a quiet desktop nothing closes the menu, and the check reported « no answer »
; after 180 s (live-right-click-menu). Another program taking the foreground
; closed it, which is why the check passed on a loaded machine. The check itself
; shows the real menu; this test keeps the cancel in the only place that clicks.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRC_RightClickClosesItsMenu() {
	Source := _DriverDirConcat("tests/live")
	Definition := _DriverFindFunctionDefinition(&Source, "TypistMouse")
	AssertTrue(IsObject(Definition), "The typist's pointer action must be readable for this test.")
	AssertContains(_DriverExtractDefinedBody(&Source, Definition), "TypistCloseMenu()",
		"A right click must cancel the menu it opens.")
}
Test("live typist: a right click cancels its native menu (live-right-click-menu)", _LRC_RightClickClosesItsMenu)
