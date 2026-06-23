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
		for HWND in HWNDs
			Results.Push(HWND)
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
