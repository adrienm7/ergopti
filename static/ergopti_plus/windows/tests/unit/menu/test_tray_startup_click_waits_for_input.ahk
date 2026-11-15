; tests/unit/menu/test_tray_startup_click_waits_for_input.ahk

; ==============================================================================
; MODULE: Early Tray Click Waits For Input Tests
; DESCRIPTION:
; An open native menu stops the auto-execute thread, so a tray clicked during
; boot is queued and opened once input is ready, not once the root publishes
; (maintainer decision, 3 November 2026).
; ==============================================================================

#Requires AutoHotkey v2.0

_TSCW_ReadinessNeedsBoth() {
	AssertFalse(TrayStartupClickReady(false, true), "nothing is ready before the root and the keyboard")
	AssertFalse(TrayStartupClickReady(true, true), "a published root alone must not open the queued menu")
	AssertFalse(TrayStartupClickReady(false, false), "ready input without a root has nothing to open")
	AssertTrue(TrayStartupClickReady(true, false), "the queued menu opens once both are ready")
}
Test("tray startup: the queued menu needs the root and ready input (tray-click-waits-for-input-2026-11-03)",
	_TSCW_ReadinessNeedsBoth)

_TSCW_ClickQueuedUntilInputReady() {
	State := Map("menu", false, "pending_input", true, "shown", 0, "scheduled", [])
	Gate := TrayStartupClick(() => TrayStartupClickReady(State["menu"], State["pending_input"]),
		() => State["shown"] += 1,
		(Fn, Delay) => State["scheduled"].Push(Fn), (*) => 0)
	AssertEqual(0, Gate.OnTrayMessage(0, 0x205, 0x404, 0), "an early click is consumed, never shown at once")
	State["menu"] := true
	AssertEqual(0, Gate.OnTrayMessage(0, 0x205, 0x404, 0),
		"a click after the root publishes but before input is ready is still queued")
	AssertTrue(Gate.Pending)
	AssertEqual(0, State["shown"], "no menu may open while the keyboard is still registering")
	AssertThrows(() => Gate.NotifyReady(), "the queue cannot be released before input is ready")
	AssertEqual(0, State["scheduled"].Length)
	State["pending_input"] := false
	AssertTrue(Gate.NotifyReady())
	AssertEqual(1, State["scheduled"].Length, "both queued clicks open one menu")
	State["scheduled"][1].Call()
	AssertEqual(1, State["shown"], "the queued menu opens once input is ready")
	AssertEqual("", Gate.OnTrayMessage(0, 0x205, 0x404, 0), "after readiness a click is the native menu's own")
}
Test("tray startup: a click during boot opens only once input is ready (tray-click-waits-for-input-2026-11-03)",
	_TSCW_ClickQueuedUntilInputReady)

; The production order the two tests above rely on: the boot builds the root
; after the keyboard, and releases the queued click only once input is ready.
_TSCW_BootWiresTheOrder() {
	Source := FSReadUtf8Exact(A_ScriptDir . "\..\ErgoptiPlus.ahk")
	AssertTrue(Source is String && Source != "", "the driver entry must be readable")
	Ready := InStr(Source, "TrayStartupClick(`n`tTrayStartupClickReadyNow,")
	Watcher := InStr(Source, 'BootProfile_Mark("Prefix watcher index complete")')
	Build := InStr(Source, "if !BuildTrayMenuDeferred()")
	InputReady := InStr(Source, "_DriverInputInitPending := false")
	Release := InStr(Source, "_TrayStartupClick.NotifyReady()", , InputReady > 0 ? InputReady : 1)
	AssertTrue(Ready > 0, "the early-click owner must wait for the root and ready input")
	AssertTrue(Watcher > 0 && Build > Watcher, "the configured root must be built after the keyboard is registered")
	AssertTrue(InputReady > Build && Release > InputReady, "the queued click must be released once input is ready")
}
Test("tray startup: the boot builds the root after the keyboard and releases the click at input readiness (tray-click-waits-for-input-2026-11-03)",
	_TSCW_BootWiresTheOrder)
