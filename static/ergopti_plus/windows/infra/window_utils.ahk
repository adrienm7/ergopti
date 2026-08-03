; infra/window_utils.ahk

; ==============================================================================
; MODULE: Window Utilities
; DESCRIPTION:
; Pure window and monitor helpers shared between tap-hold dispatch and any
; other module that needs to query the screen geometry.
;
; FEATURES & RATIONALE:
; 1. AltTabMonitor: cycles to the most-recently-used visible window on the
;    monitor that currently contains the mouse cursor, providing per-monitor
;    Alt+Tab behaviour without relying on the OS compositor.
; 2. AltTabAll: the same cycle with no monitor constraint. Both behaviours are
;    wanted and neither replaces the other — per-monitor keeps a multi-screen
;    workspace from collapsing into one list, unscoped is what a single-screen
;    user means by Alt+Tab. They share one filter, because the value of this
;    module is the filter: a cycle that lands on the taskbar, a tooltip or a
;    drag proxy is worse than no cycle at all, and that list of exclusions was
;    learned the hard way once.
; 3. GetMonitorFromPoint: maps an (X, Y) screen coordinate to its AHK monitor
;    index (1-based), returning 0 when the point falls outside every monitor.
;    Extracted here so tests can call it without loading hotkey-registration
;    code from modules/.
; ==============================================================================


; Sentinel for "no monitor constraint" in _AltTabCycle. 0 is safe as a sentinel
; because AHK monitor indices are 1-based and GetMonitorFromPoint already
; answers 0 for a point that lies outside every monitor.
ALT_TAB_ANY_MONITOR := 0

; Windows narrower or shorter than this are overlays, splash screens and drag
; proxies rather than application windows the user means to switch to.
ALT_TAB_MIN_WINDOW_PX := 100





; =========================================
; =========================================
; ======= 1/ Monitor geometry query =======
; =========================================
; =========================================

; Return the AHK monitor index (1-based) that contains the point (X, Y) in
; screen coordinates, or 0 when the point falls outside every monitor.
GetMonitorFromPoint(X, Y) {
	MonitorCount := MonitorGetCount()

	loop MonitorCount {
		MonitorGet(A_Index, &MonitorLeft, &MonitorTop, &MonitorRight, &MonitorBottom)

		if (X >= MonitorLeft && X < MonitorRight && Y >= MonitorTop && Y < MonitorBottom) {
			return A_Index
		}
	}

	return 0
}





; ============================================
; ============================================
; ======= 2/ Per-monitor window cycler =======
; ============================================
; ============================================

; Activate the most-recently-used visible window, optionally restricted to one
; monitor. Filters out minimised, undersized, untitled, and known system windows
; (taskbar, desktop, WorkerW) so the switch always lands on a real application
; window.
;
; MonitorNum is an AHK monitor index, or ALT_TAB_ANY_MONITOR for no constraint.
; The two public cyclers differ ONLY in that argument: keeping one filter means
; a window class that has to be excluded is excluded from both, which is not
; true of two implementations that merely look alike.
_AltTabCycle(MonitorNum, Label) {
	CurrentWindowId := WinExist("A")
	Candidates := []

	for WindowId in WinGetList() {
		try {
			if WindowId == CurrentWindowId {
				continue
			}

			WinGetPos(&x, &y, &w, &h, WindowId)

			if (w < ALT_TAB_MIN_WINDOW_PX || h < ALT_TAB_MIN_WINDOW_PX) {
				continue
			}

			if (MonitorNum != ALT_TAB_ANY_MONITOR) {
				CenterX := x + w // 2
				CenterY := y + h // 2
				if GetMonitorFromPoint(CenterX, CenterY) != MonitorNum {
					continue
				}
			}

			; Skip windows with no title — often tooltips, overlays, or hidden UI
			; elements, windows shown during drag operations, and file-operation dialogs
			; Cache the title once to avoid a TOCTOU race if the window title changes between calls
			WindowTitle := WinGetTitle(WindowId)
			if WindowTitle == "" or WindowTitle == "Drag" or WinGetClass(WindowId) == "OperationStatusWindow" {
				continue
			}

			; Exclude known system window classes:
			; - Shell_TrayWnd: Windows taskbar
			; - Progman: desktop background
			; - WorkerW: hidden background windows
			WindowClass := WinGetClass(WindowId)
			if (WindowClass == "Shell_TrayWnd" || WindowClass == "Progman" || WindowClass == "WorkerW") {
				continue
			}

			Candidates.Push(WindowId)
		} catch as Err {
			; A window closing mid-enumeration (a routine race, not a bug) throws
			; TargetError on the next WinGet* call for that HWnd — skip just this
			; window instead of aborting the whole cycle, mirroring
			; GestureGetCyclableWindows's identical TOCTOU guard.
			LoggerDebug("WindowUtils", "{1}: skipped ahk_id {2}: {3}.", Label, WindowId, Err.Message)
			continue
		}
	}

	; The enumeration above guards every WinGet* against a window closing
	; mid-cycle, then this activation used the result one line outside that
	; guard — so the same routine race, hitting the single window that survived
	; filtering, threw TargetError and aborted the alt-tab instead of skipping.
	; Skip-and-continue rather than a bare try: falling through to the next
	; candidate means the user's alt-tab still does something useful.
	for WindowId in Candidates {
		try {
			WinActivate(WindowId)
			return true
		} catch as Err {
			LoggerDebug("WindowUtils", "{1}: activation target ahk_id {2} vanished: {3}.", Label, WindowId, Err.Message)
			continue
		}
	}
	return false
}

; Activate the most-recently-used visible window on the monitor that currently
; contains the mouse cursor. Per-monitor Alt+Tab, without relying on the OS
; compositor.
AltTabMonitor() {
	CoordMode("Mouse", "Screen")
	MouseGetPos(&MousePosX, &MousePosY)
	MonitorNum := GetMonitorFromPoint(MousePosX, MousePosY)
	if MonitorNum == ALT_TAB_ANY_MONITOR {
		; The cursor is off every monitor — a real state during a display change.
		; Falling back to the unscoped cycle here would be worse than doing
		; nothing: the user asked for THIS screen, and silently switching to a
		; window on another one is the failure they would have to undo.
		LoggerDebug("WindowUtils", "AltTabMonitor: the cursor is on no monitor — nothing to cycle.")
		return
	}
	_AltTabCycle(MonitorNum, "AltTabMonitor")
}

; Activate the most-recently-used visible window anywhere, ignoring monitors.
; This is what a single-screen user means by Alt+Tab, and what a multi-screen
; user wants when the window they are after is on the other display.
AltTabAll() {
	_AltTabCycle(ALT_TAB_ANY_MONITOR, "AltTabAll")
}
