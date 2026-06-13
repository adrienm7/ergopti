; tests/meta/test_boot_deferred_tasks.ahk

; ==============================================================================
; MODULE: Boot Deferred-Tasks Ordering Test
; DESCRIPTION:
; Guards the rule that every HEAVY off-critical-path boot task is armed only
; AFTER the driver reports "Driver fully initialised" — never mid-boot.
;
; WHY THIS MATTERS (the regression this encodes):
;   AHK runs startup as one interruptible auto-execute thread. A SetTimer armed
;   mid-boot (e.g. in the metrics block) fires roughly its-delay later, WHILE the
;   ~5400-hotstring registration is still running, and AHK preempts that thread
;   to run the timer. Two concrete failures were observed when WPMWidget_Show was
;   armed mid-boot:
;     1. WebView2's ~3 s cold-start was dragged back into contention with the
;        registration, re-inflating time-to-ready by ~2.5 s.
;     2. The interruption pumped the message queue, so a tray click the user had
;        queued during startup was painted against a half-built menu (the
;        "menu shows only the first items" bug).
;   Arming after "ready" means the countdowns start once the critical path is
;   done, so the tasks fire on the idle message loop with the menu fully built.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckBootDeferredTasks() {
	; Locate ErgoptiPlus.ahk relative to the tests/ directory.
	SplitPath(A_ScriptDir, , &WindowsDir)
	BootFile := WindowsDir . "\ErgoptiPlus.ahk"

	Body := ""
	try Body := FileRead(BootFile)
	Assert(Body != "", "ErgoptiPlus.ahk must be readable for the deferred-tasks meta-test")

	; ASCII substring of the ready marker (avoids the em-dash in the real log line).
	ReadyPos := InStr(Body, "Driver fully initialised")
	Assert(ReadyPos > 0,
		"ErgoptiPlus.ahk must log the 'Driver fully initialised' ready marker")

	; Every heavy deferred task must be armed strictly AFTER the ready marker.
	; InStr returns the FIRST occurrence, so Pos > ReadyPos proves NO occurrence
	; sits before "ready" — exactly the regression we must prevent.
	for _, Probe in [
		"SetTimer(WPMWidget_Show",
		"SetTimer(RegisterTextExpansionDeferred",
		"SetTimer(RegisterEmojisSymbolsDeferred",
		"SetTimer(LLM_Tray_Build" ] {
		Pos := InStr(Body, Probe)
		Assert(Pos > 0, "ErgoptiPlus.ahk must arm '" . Probe . "...' at boot")
		Assert(Pos > ReadyPos,
			"'" . Probe . "...' must be armed AFTER 'Driver fully initialised' "
			. "(arm at offset " . Pos . ", ready at " . ReadyPos . ") so the deferred "
			. "task never preempts the still-running hotstring registration")
	}
}

Test("meta boot: heavy deferred timers armed after 'ready'", _MetaCheckBootDeferredTasks)
