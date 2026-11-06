; modules/keystats/keystats_virtual_desktop.ahk

; ==============================================================================
; MODULE: Virtual Desktop Changes
; DESCRIPTION:
; Counts real virtual-desktop changes as the `space_change` system event macOS
; emits from its spaces watcher, so the shared space-change KPI
; (agg_system_day.space_switches) has a Windows producer.
;
; FEATURES & RATIONALE:
; 1. The source is the id Explorer publishes for the current desktop, not a
;    guess: Windows 11 keeps it under ...\Explorer\VirtualDesktops and Windows
;    10 under the session's ...\Explorer\SessionInfo\<id>\VirtualDesktops,
;    value CurrentVirtualDesktop. Linux reads the EWMH current desktop the same
;    way, on a poll. The window-topology heuristic (virtual_desktop_switch, a
;    focus-change guess) stays a raw topology event and never feeds this KPI.
; 2. The first reading is a baseline, never a change, and a paused, filtered or
;    unreadable tick drops the baseline: a change that happened while
;    collection was off is not credited when it resumes.
; 3. The observation is pure over its ports (reading, log, clock), so the
;    unit suite drives it without a desktop.
; ==============================================================================

#Requires AutoHotkey v2.0

class KLDesktop {
	; Last observed desktop id; "" when there is no baseline.
	static current := ""
}

/**
 * Reads the id of the current virtual desktop.
 * @returns {String} Its hexadecimal id, or "" when Explorer publishes none.
 */
KL_Desktop_ReadCurrent() {
	try return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops",
		"CurrentVirtualDesktop")
	; An unreported session leaves no per-session key to read.
	try SessionId := SystemControl().SessionId()
	catch
		return ""
	try return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\"
		. SessionId . "\VirtualDesktops", "CurrentVirtualDesktop")
	return ""
}

/**
 * Records one reading and logs a space_change when the desktop differs from the baseline.
 * @param Current The id read this tick, "" when unreadable.
 * @param LogFn Receives the system_event entry (KL_AppendLog in production).
 * @param TimestampFn Returns the event timestamp.
 * @returns {Integer} True when a change was logged.
 */
KL_Desktop_Observe(Current, LogFn, TimestampFn) {
	Previous := KLDesktop.current
	KLDesktop.current := Current
	if (Previous = "" || Current = "" || Previous == Current)
		return false
	LogFn.Call(Map("type", "system_event", "action", "space_change",
		"timestamp", TimestampFn.Call(), "space_id", Current))
	return true
}

/** Drops the baseline: the next reading starts over. */
KL_Desktop_Reset() {
	KLDesktop.current := ""
}
