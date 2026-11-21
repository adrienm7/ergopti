; tests/unit/menu/test_tray_primary_click_opens_menu.ahk

; ==============================================================================
; MODULE: Tray Primary Click Opens The Menu Tests
; DESCRIPTION:
; A left click on the tray icon opens the same menu as a right click, as on
; macOS and Linux (maintainer decision TRAY-02, 21 November 2026). AutoHotkey
; opens its menu on the right button only, so the driver owns WM_LBUTTONUP.
; ==============================================================================

#Requires AutoHotkey v2.0

_TPCO_ReadyPrimaryClickShowsTheMenu() {
	State := Map("shown", 0)
	Gate := TrayStartupClick(() => true, () => State["shown"] += 1, (*) => 0, (*) => 0)
	AssertEqual(0, Gate.OnTrayMessage(0, 0x202, 0x404, 0),
		"a ready left click is consumed by the driver's own menu presentation")
	AssertEqual(1, State["shown"], "a ready left click opens the tray menu")
	AssertEqual("", Gate.OnTrayMessage(0, 0x205, 0x404, 0), "a ready right click stays the native menu's own")
	AssertEqual(1, State["shown"], "the right click is not presented twice")
	AssertEqual("", Gate.OnTrayMessage(0, 0x201, 0x404, 0), "a button press is left to the native owner")
	AssertEqual("", Gate.OnTrayMessage(0, 0x405, 0x404, 0), "a balloon click stays the updater's")
	AssertEqual(1, State["shown"])
}
Test("tray: a ready left click opens the same menu as the right click (tray-02-2026-11-21)",
	_TPCO_ReadyPrimaryClickShowsTheMenu)

_TPCO_EarlyPrimaryClickIsQueued() {
	State := Map("ready", false, "shown", 0, "scheduled", [])
	Gate := TrayStartupClick(() => State["ready"], () => State["shown"] += 1,
		(Fn, Delay) => State["scheduled"].Push(Fn), (*) => 0)
	AssertEqual(0, Gate.OnTrayMessage(0, 0x202, 0x404, 0), "an early left click is queued like a right click")
	AssertTrue(Gate.Pending)
	AssertEqual(0, State["shown"])
	State["ready"] := true
	AssertTrue(Gate.NotifyReady())
	State["scheduled"][1].Call()
	AssertEqual(1, State["shown"], "the queued left click opens the menu once input is ready")
}
Test("tray: a left click during boot is queued until input is ready (tray-02-2026-11-21)",
	_TPCO_EarlyPrimaryClickIsQueued)
