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

; Bypasses foreground-stealing protection before focusing an HWND. The thread
; attachment is always released, including when an intermediate Win32 call
; raises, so it cannot leak input attachment into subsequent UI interactions.
WMForceForeground(HWnd) {
	ForeThread := 0
	TargThread := 0
	Attached := false
	try {
		ForeHwnd := DllCall("GetForegroundWindow", "Ptr")
		ForeThread := DllCall("GetWindowThreadProcessId", "Ptr", ForeHwnd, "Ptr", 0, "UInt")
		TargThread := DllCall("GetWindowThreadProcessId", "Ptr", HWnd, "Ptr", 0, "UInt")
		if (ForeThread && TargThread && ForeThread != TargThread)
			Attached := DllCall("AttachThreadInput", "UInt", ForeThread, "UInt", TargThread, "Int", true)
		DllCall("BringWindowToTop", "Ptr", HWnd)
		DllCall("SetForegroundWindow", "Ptr", HWnd)
		WMActivate(HWnd)
		return true
	} catch {
		return false
	} finally {
		if Attached
			try DllCall("AttachThreadInput", "UInt", ForeThread, "UInt", TargThread, "Int", false)
	}
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
