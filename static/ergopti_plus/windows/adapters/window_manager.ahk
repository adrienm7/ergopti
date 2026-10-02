; adapters/window_manager.ahk

; ==============================================================================
; MODULE: WindowManager Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the WindowManager port contract defined in
; static/ergopti_plus/_shared/core/ports/WindowManager.spec.js. Wraps AHK v2's
; WinActivate, WinExist, WinKill, WinGetList, WinGetTitle, and related
; built-ins behind the six canonical functions so domain modules can manage
; application windows without coupling to AHK-specific windowing APIs.
;
; NAMING CONVENTION:
; Port method     → AHK function name
;   activate()    → WMActivate(HwndOrSpec)
;   exists()      → WMExists(Spec)
;   kill()        → WMKill(Spec)
;   getList()     → WMGetList()
;   getTitle()    → WMGetTitle(HwndOrSpec)
;   getFocused()  → WMGetFocused()
;
; RETURN SHAPES:
; WMGetFocused() returns a Map: { "hwnd", "title", "process" }
; WMGetList()    returns an Array of HWND integers.
;
; FAIL-SAFE:
; All AHK window API calls are wrapped in try/catch. If a window cannot be
; reached (elevation mismatch, UAC prompt, locked screen), functions return
; their typed default (false / "" / 0 / empty collection) rather than throwing.
; ==============================================================================




; ==========================================
; ==========================================
; ======= 1/ Internal Helpers ==============
; ==========================================
; ==========================================

; Returns an empty focused-window Map with all fields at their zero values.
_WMEmptyFocused() {
	return Map(
		"hwnd",    0,
		"title",   "",
		"process", ""
	)
}

; Resolves HwndOrSpec to an AHK WinTitle string understood by built-ins.
; @param HwndOrSpec {Integer|String} Raw HWND or spec string.
; @return {String} AHK WinTitle expression.
_WMResolveSpec(HwndOrSpec) {
	if IsInteger(HwndOrSpec)
		return "ahk_id " . HwndOrSpec
	return HwndOrSpec
}




; ========================================
; ========================================
; ======= 2/ Adapter Methods =============
; ========================================
; ========================================

; Brings the specified window to the foreground and gives it focus.
; @param HwndOrSpec {Integer|String} HWND integer or AHK WinTitle spec.
; @return {Boolean} True on success, false on error.
WMActivate(HwndOrSpec) {
	local Spec := _WMResolveSpec(HwndOrSpec)
	try {
		WinActivate(Spec)
		return true
	} catch {
		return false
	}
}

; Checks whether at least one window matching Spec currently exists.
; @param Spec {String} AHK WinTitle spec (e.g. "ahk_exe notepad.exe").
; @return {Boolean} True on success, false on error.
WMExists(Spec) {
	try {
		return WinExist(Spec) ? true : false
	} catch {
		return false
	}
}

/** Checks an owned HWND even while hidden, independently of thread search settings. */
WMHandleExists(HWnd) {
	return _WMForegroundNative.IsWindow(HWnd)
}

/** Creates an invisible real HWND whose controller can retain the shared browser. */
WMBrowserWarmHost() {
	Host := Gui_Create("+ToolWindow")
	Control := Host.Add("Text", "x0 y0 w600 h400", "")
	Host.Show("Hide w600 h400")
	return {Hwnd: Control.Hwnd, Destroy: (*) => Host.Destroy()}
}

; Forcefully terminates all windows matching Spec.
; @param Spec {String} AHK WinTitle spec.
; @return {Boolean} True on success, false on error.
WMKill(Spec) {
	try {
		WinKill(Spec)
		return true
	} catch {
		return false
	}
}

; Returns an Array of HWND integers for all currently visible windows.
; @return {Array} Array of HWND integers (may be empty).
WMGetList() {
	local Results := []
	try {
		local HWNDs := WinGetList()
		for HWND in HWNDs {
			try {
				Results.Push(HWND)
			} catch as Err {
				; A window closing mid-enumeration (a routine race, not a bug) can
				; invalidate the HWND before it is captured — skip just this window
				; instead of aborting the whole list, mirroring the identical TOCTOU
				; guard already applied to GestureGetCyclableWindows.
				try LoggerDebug("WindowManager", "WMGetList: skipped a window during enumeration: {1}.", Err.Message)
				continue
			}
		}
	}
	return Results
}

; Returns the title bar text of the specified window.
; @param HwndOrSpec {Integer|String} HWND integer or AHK WinTitle spec.
; @return {String} Window title, or "" if the window is not found.
WMGetTitle(HwndOrSpec) {
	local Spec := _WMResolveSpec(HwndOrSpec)
	try {
		return WinGetTitle(Spec)
	} catch {
		return ""
	}
}

; Returns the identity of the currently focused window.
; @return {Map} { "hwnd": Integer, "title": String, "process": String }
WMGetFocused() {
	local Info := _WMEmptyFocused()
	try {
		local HWND := WinGetID("A")
		Info["hwnd"] := HWND
		try {
			Info["title"] := WinGetTitle("ahk_id " . HWND)
		}
		try {
			Info["process"] := WinGetProcessName("ahk_id " . HWND)
		}
	} catch {
		; Active window unavailable — return zero-value Map
	}
	return Info
}

; Domain modules occasionally need a small amount of Win32-only behaviour that
; has no cross-driver port equivalent. Keep it inside this adapter so gesture
; code does not directly couple itself to DWM and foreground-thread APIs.
WMIsCloaked(HWnd) {
	try {
		Cloaked := 0
		DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", HWnd, "UInt", 14,
			"Int*", &Cloaked, "UInt", 4)
		return Cloaked != 0
	} catch {
		return false
	}
}

WMUnhookWinEvent(HookHandle) {
	if !HookHandle
		return true
	try return DllCall("UnhookWinEvent", "Ptr", HookHandle) != 0
	catch
		return false
}

; Injectable Win32 boundary for foreground activation. Keeping the native calls
; behind typed Boolean methods lets the adapter contract exercise OS refusal
; returns without focusing a real window in the headless test runner.
class _WMForegroundNative {
	static IsWindow(HWnd) {
		return DllCall("IsWindow", "Ptr", HWnd, "Int") != 0
	}

	static GetForegroundWindow() {
		return DllCall("GetForegroundWindow", "Ptr")
	}

	static GetWindowThreadProcessId(HWnd) {
		return DllCall("GetWindowThreadProcessId", "Ptr", HWnd, "Ptr", 0, "UInt")
	}

	static AttachThreadInput(ForeThread, TargThread, Attach) {
		return DllCall("AttachThreadInput", "UInt", ForeThread, "UInt", TargThread,
			"Int", Attach ? true : false) != 0
	}

	static BringWindowToTop(HWnd) {
		return DllCall("BringWindowToTop", "Ptr", HWnd, "Int") != 0
	}

	static SetForegroundWindow(HWnd) {
		return DllCall("SetForegroundWindow", "Ptr", HWnd, "Int") != 0
	}

	static Activate(HWnd) {
		return WMActivate(HWnd)
	}

	static IsIconic(HWnd) {
		return DllCall("IsIconic", "Ptr", HWnd, "Int") != 0
	}

	static IsWindowVisible(HWnd) {
		return DllCall("IsWindowVisible", "Ptr", HWnd, "Int") != 0
	}

	; ShowWindow returns the previous visibility, not a success flag.
	static Restore(HWnd) {
		DllCall("ShowWindow", "Ptr", HWnd, "Int", 9, "Int")
	}

	static Show(HWnd) {
		DllCall("ShowWindow", "Ptr", HWnd, "Int", 5, "Int")
	}
}

; Bypasses foreground-stealing protection before focusing an HWND. Success is
; reported only when every native request accepted the operation and Windows
; exposes HWnd as the foreground postcondition. The thread attachment is always
; released, including on Boolean refusal and exceptions.
WMForceForeground(HWnd, Native := _WMForegroundNative) {
	ForeThread := 0
	TargThread := 0
	Attached := false
	Success := false
	try {
		if !Native.IsWindow(HWnd)
			return false
		ForeHwnd := Native.GetForegroundWindow()
		ForeThread := ForeHwnd ? Native.GetWindowThreadProcessId(ForeHwnd) : 0
		TargThread := Native.GetWindowThreadProcessId(HWnd)
		if !TargThread
			return false
		if (ForeThread && ForeThread != TargThread) {
			Attached := Native.AttachThreadInput(ForeThread, TargThread, true)
			if !Attached
				return false
		}
		if !Native.BringWindowToTop(HWnd)
			return false
		if !Native.SetForegroundWindow(HWnd)
			return false
		if !Native.Activate(HWnd)
			return false
		Success := Native.GetForegroundWindow() = HWnd
	} catch {
		Success := false
	} finally {
		if Attached {
			try {
				if !Native.AttachThreadInput(ForeThread, TargThread, false)
					Success := false
			} catch {
				Success := false
			}
		}
	}
	return Success
}

; The driver's one "present window" step for an ErgoptiPlus window requested
; again while it is open (a first open is Gui.Show, which activates the new
; window): restores it when minimized, shows it when hidden, then raises it and
; gives it the keyboard through WMForceForeground. It never touches the topmost
; flag: a window is focused, never kept above the windows the user opens
; afterwards (maintainer rule 2026-09-29). A refusal is logged; the window then
; only flashes in the taskbar.
; @param Window {Gui|Integer} The window, or its handle. A Gui is read here so
;   a window destroyed behind its owner's back is reported, not thrown.
; @param Native {Object} Injectable Win32 boundary (tests).
; @return {Boolean} True when the window became the foreground window.
WMPresentWindow(Window, Native := _WMForegroundNative) {
	HWnd := 0
	try {
		HWnd := IsObject(Window) ? Window.Hwnd : Window
		if !HWnd || !Native.IsWindow(HWnd) {
			LoggerWarn("WindowManager", "Window {1} no longer exists and cannot be presented.", HWnd)
			return false
		}
		if Native.IsIconic(HWnd)
			Native.Restore(HWnd)
		else if !Native.IsWindowVisible(HWnd)
			Native.Show(HWnd)
	} catch as Err {
		LoggerWarn("WindowManager", "Window {1} could not be prepared for presenting: {2}.", HWnd, Err.Message)
		return false
	}
	if WMForceForeground(HWnd, Native)
		return true
	LoggerWarn("WindowManager", "Window {1} was refused the foreground; it only flashes in the taskbar.", HWnd)
	return false
}

; Port dispatch map (ADAPTER_WINDOW_MANAGER) — the single-source-of-truth contract
; surface, verified against _shared/core/ports/contracts.json by
; tools/test/test-port-compliance.cjs.
global ADAPTER_WINDOW_MANAGER := Map(
    "activate", WMActivate,
    "exists", WMExists,
    "getFocused", WMGetFocused,
    "getList", WMGetList,
    "getTitle", WMGetTitle,
    "kill", WMKill
)
