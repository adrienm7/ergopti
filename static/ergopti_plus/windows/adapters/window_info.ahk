; adapters/window_info.ahk

; ==============================================================================
; MODULE: WindowInfo Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the WindowInfo port contract defined in
; static/ergopti_plus/_shared/core/ports/WindowInfo.spec.js. Wraps AHK v2's
; WinGetTitle, WinGetProcessName, WinGetList, and WinGetID built-ins behind
; the two canonical functions (WIGetFocused, WIGetAll) so domain modules can
; query foreground-window identity without coupling to AHK-specific APIs.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   getFocused() → WIGetFocused()
;   getAll()     → WIGetAll()
;
; RETURN SHAPE:
; Both functions return Map objects with the four contract fields:
;   { "appId", "windowTitle", "bundleId", "executablePath" }
; bundleId is always "" on Windows (macOS-only concept).
; executablePath is the full path from WinGetProcessPath when available.
;
; FAIL-SAFE:
; All AHK window API calls are wrapped in try/catch. If the foreground window
; cannot be queried (locked screen, UAC elevation, restricted process),
; WIGetFocused returns an empty-field Map rather than throwing.
; ==============================================================================




; =======================================
; =======================================
; ======= 1/ Internal Helpers ===========
; =======================================
; =======================================

; Returns an empty WindowInfo Map with all four fields set to "".
_WIEmptyInfo() {
	return Map(
		"appId",          "",
		"windowTitle",    "",
		"bundleId",       "",
		"executablePath", ""
	)
}

; Builds a WindowInfo Map for a given window HWND.
; @param HWND {Integer} Window handle (0 = active window "A").
; @return {Map} WindowInfo Map.
_WIInfoFromHwnd(HWND) {
	local Info := _WIEmptyInfo()
	local WinSpec := HWND = 0 ? "A" : "ahk_id " . HWND
	try {
		local Title := WinGetTitle(WinSpec)
		if Title != ""
			Info["windowTitle"] := Title
	}
	try {
		local ProcName := WinGetProcessName(WinSpec)
		if ProcName != ""
			Info["appId"] := ProcName
	}
	try {
		local ProcPath := WinGetProcessPath(WinSpec)
		if ProcPath != ""
			Info["executablePath"] := ProcPath
	}
	return Info
}




; ===========================================
; ===========================================
; ======= 2/ Adapter Methods ================
; ===========================================
; ===========================================

; Returns the identity of the currently focused window.
; @return {Map} WindowInfo: { appId, windowTitle, bundleId, executablePath }
WIGetFocused() {
	try {
		return _WIInfoFromHwnd(0)
	} catch {
		return _WIEmptyInfo()
	}
}

; Returns an array of WindowInfo Maps for all visible windows.
; @return {Array} Array of WindowInfo Maps (may be empty).
WIGetAll() {
	local Results := []
	try {
		local HWNDs := WinGetList()
		for HWND in HWNDs {
			try {
				local Info := _WIInfoFromHwnd(HWND)
				; Skip windows with no process name (system internals, invisible windows)
				if Info["appId"] != ""
					Results.Push(Info)
			} catch as Err {
				; A window closing mid-enumeration (a routine race, not a bug)
				; throws TargetError on the next WinGet* call for that HWnd — skip
				; just this window instead of aborting the whole enumeration,
				; mirroring the identical TOCTOU guard already applied to
				; GestureGetCyclableWindows.
				try LoggerDebug("WindowInfo", "WIGetAll: skipped ahk_id {1}: {2}.", HWND, Err.Message)
				continue
			}
		}
	}
	return Results
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_WINDOW_INFO := Map(
    "getFocused", WIGetFocused,
    "getAll",     WIGetAll,
)
