; lib/window_utils.ahk

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
; 2. GetMonitorFromPoint: maps an (X, Y) screen coordinate to its AHK monitor
;    index (1-based), returning 0 when the point falls outside every monitor.
;    Extracted here so tests can call it without loading hotkey-registration
;    code from modules/.
; ==============================================================================





; ==========================================
; =========================================
; ======= 1/ Monitor geometry query =======
; =========================================
; ==========================================

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

; Activate the most-recently-used visible window on the monitor that currently
; contains the mouse cursor. Filters out minimised, undersized, untitled, and
; known system windows (taskbar, desktop, WorkerW) so the switch always lands
; on a real application window.
AltTabMonitor() {
	CoordMode("Mouse", "Screen")
	MouseGetPos(&MousePosX, &MousePosY)
	MonitorNum := GetMonitorFromPoint(MousePosX, MousePosY)
	if MonitorNum == 0 {
		return
	}

	CurrentWindowId := WinExist("A")
	AppWindowsOnMonitorFiltered := []

	for WindowId in WinGetList() {
		if WindowId == CurrentWindowId {
			continue
		}

		WinGetPos(&x, &y, &w, &h, WindowId)

		if (w < 100 || h < 100) {
			continue
		}

		CenterX := x + w // 2
		CenterY := y + h // 2
		if GetMonitorFromPoint(CenterX, CenterY) != MonitorNum {
			continue
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

		AppWindowsOnMonitorFiltered.Push(WindowId)
	}

	if AppWindowsOnMonitorFiltered.Length > 0 {
		WinActivate(AppWindowsOnMonitorFiltered[1])
	}
}
