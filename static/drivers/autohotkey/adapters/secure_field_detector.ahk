﻿; adapters/secure_field_detector.ahk

; ==============================================================================
; MODULE: SecureFieldDetector Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the SecureFieldDetector port contract. Detects
; whether the currently focused control is a password/secure input field by
; inspecting the ES_PASSWORD window style (0x20), and whether the active
; application belongs to a hardcoded list of known password-manager processes.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   isSecureField() → SFD_IsSecureField()
;   isSecureApp()   → SFD_IsSecureApp(AppId)
;   refresh()       → SFD_Refresh()
;
; FAIL-SAFE:
; All AHK control-inspection calls are wrapped in try/catch. Any failure
; (UAC-elevated window, locked screen, restricted process) returns false rather
; than throwing, so callers never need to guard against exceptions.
; ==============================================================================



; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Known password-manager process names — expansion welcome, never shrink.
global SFD_SECURE_APPS := Map(
	1Password.exe,          1,
	KeePass.exe,            1,
	KeePassXC.exe,          1,
	Bitwarden.exe,          1,
	LastPass.exe,           1,
	Dashlane.exe,           1,
	RoboForm.exe,           1,
	Authy.exe,              1,
	keepass2.exe,           1,
	credential_guard,       1
)



; ======================================
; ======================================
; ======= 2/ Adapter Functions =======
; ======================================
; ======================================

; Returns true if the focused control carries the ES_PASSWORD style, false otherwise.
; Uses ControlGetStyle which inspects the Win32 ES_PASSWORD flag (0x20) — the
; most reliable heuristic without full UIAutomation COM registration.
; @return {Boolean} True on success, false on error.
SFD_IsSecureField() {
	try {
		local FocusedCtrl := ControlGetFocus(A)
		if FocusedCtrl =
			return false
		local Style := ControlGetStyle(FocusedCtrl, A)
		; ES_PASSWORD = 0x20 — password edit field marker set by CreateWindowEx
		return (Style & 0x20) ? true : false
	} catch {
		return false
	}
}

; Returns true if AppId matches any entry in the SFD_SECURE_APPS constant Map.
; An empty or missing AppId is treated as non-secure to avoid false positives.
; @param AppId {String} Process name of the active application (e.g. KeePass.exe).
; @return {Boolean} True on success, false on error.
SFD_IsSecureApp(AppId) {
	if AppId =
		return false
	try {
		return SFD_SECURE_APPS.Has(AppId) ? true : false
	} catch {
		return false
	}
}

; No-op on AHK — context is read live at call time, no cached state to refresh.
; Exists solely to satisfy the port contract interface.
SFD_Refresh() {
	; Live queries require no pre-fetch on Windows — nothing to do here
	return
}
; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_SECURE_FIELD_DETECTOR := Map(
    "isSecureField", Func("SFD_IsSecureField"),
    "isSecureApp",   Func("SFD_IsSecureApp"),
    "refresh",       Func("SFD_Refresh"),
)
