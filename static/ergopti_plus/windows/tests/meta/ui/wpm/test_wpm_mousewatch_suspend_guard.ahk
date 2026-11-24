; tests/meta/ui/wpm/test_wpm_mousewatch_suspend_guard.ahk

; ==============================================================================
; MODULE: WPMWidget MouseWatch Suspend Guard
; DESCRIPTION:
; Regression guard for AHK-33: WPMWidget_MouseWatch fired every 50 ms via
; SetTimer while the driver was paused. AHK native Suspend only disarms
; Hotkeys/Hotstrings; SetTimer callbacks keep firing. Its sibling
; WPMWidget_Tick had the A_IsSuspended guard, MouseWatch did not — the
; "one missed sibling" pattern documented in docs/memory.
;
; The cost was a MouseGetPos + Hide() call every MOUSE_WATCH_MS while paused.
; Hide() was a Win32 no-op because Tick had already hidden the surface, so
; there was no visible behavioural leak, but G1 (strict pause invariant) was
; violated.
;
; Fix (AHK-33): add `if A_IsSuspended return` immediately after the visibility
; check in WPMWidget_MouseWatch, mirroring WPMWidget_Tick (ui/wpm/init.ahk:749).
;
; This test drives the real WPMWidget_MouseWatch on a visible widget with no
; surface: paused, it must not even sample the cursor (its last position keeps
; an impossible sentinel); resumed, the same call samples it (positive control).
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================================
; ================================================================
; ======= 1/ WPMWidget_MouseWatch stays quiet while paused =======
; ================================================================
; ================================================================

_TWMSG_PausedWatchStaysQuiet() {
	; No cursor coordinate can reach this value, so any sample replaces it.
	Sentinel := -2147483000
	Saved := {Visible: WPMWidget.visible, X: WPMWidget._last_mouse_x, Y: WPMWidget._last_mouse_y,
		Gui: WPMWidget._gui, Graph: WPMWidget._graph_gui, Suspended: A_IsSuspended}
	try {
		; No surface exists, so the resumed control cannot hide a real window.
		WPMWidget._gui := false, WPMWidget._graph_gui := false
		WPMWidget.visible := true
		WPMWidget._last_mouse_x := Sentinel, WPMWidget._last_mouse_y := Sentinel
		Suspend(true)
		WPMWidget_MouseWatch()
		AssertEqual(Sentinel, WPMWidget._last_mouse_x,
			"AHK-33: the paused mouse watch must return before sampling the cursor, as WPMWidget_Tick does (metrics-timers-bypass-pause)")
		AssertEqual(Sentinel, WPMWidget._last_mouse_y, "the paused mouse watch keeps its last position untouched")
		Suspend(false)
		WPMWidget_MouseWatch()
		AssertTrue(WPMWidget._last_mouse_x != Sentinel && WPMWidget._last_mouse_y != Sentinel,
			"positive control: the running mouse watch samples the real cursor")
	} finally {
		WPMWidget.visible := Saved.Visible
		WPMWidget._last_mouse_x := Saved.X, WPMWidget._last_mouse_y := Saved.Y
		WPMWidget._gui := Saved.Gui, WPMWidget._graph_gui := Saved.Graph
		Suspend(Saved.Suspended)
	}
}


Test("meta ahk-33: WPMWidget_MouseWatch stays quiet while paused, like its sibling WPMWidget_Tick",
	_TWMSG_PausedWatchStaysQuiet)
