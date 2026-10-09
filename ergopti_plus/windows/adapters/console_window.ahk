; adapters/console_window.ahk

; ==============================================================================
; MODULE: Native Debug Console Adapter
; DESCRIPTION:
; Both debug views share the script's main window. Native operations always use
; that exact handle, never the focused application or a translated window title.
; ==============================================================================

#Requires AutoHotkey v2.0

class ConsoleWindowNative {
	; Opens one of the script's built-in debug views.
	; @param {String} Kind The validated view identifier.
	; @returns {Boolean}
	static Open(Kind) {
		if (Kind == "list_vars")
			ListVars()
		else
			KeyHistory()
		return true
	}

	; Reads the owned window rectangle in screen coordinates.
	; @param {Integer} Hwnd The script window handle.
	; @returns {Object}
	static Frame(Hwnd) {
		WinGetPos(&X, &Y, &Width, &Height, "ahk_id " . Hwnd)
		return {x: X, y: Y, w: Width, h: Height}
	}

	; Reads the primary monitor's usable area, excluding taskbars.
	; @returns {Object}
	static Screen() {
		MonitorGetWorkArea(MonitorGetPrimary(), &Left, &Top, &Right, &Bottom)
		return {x: Left, y: Top, w: Right - Left, h: Bottom - Top}
	}

	; Places the owned window; native refusal propagates to the owner.
	; @param {Integer} Hwnd The script window handle.
	; @param {Object} Rect Target rectangle.
	; @returns {Boolean}
	static Move(Hwnd, Rect) {
		WinMove(Rect.x, Rect.y, Rect.w, Rect.h, "ahk_id " . Hwnd)
		return true
	}

	; Brings the owned window forward.
	; @param {Integer} Hwnd The script window handle.
	; @returns {Boolean}
	static Activate(Hwnd) {
		WinActivate("ahk_id " . Hwnd)
		return true
	}
}
