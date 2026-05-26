; adapters/secure_field_detector.ahk

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
; (UAC-elevated window, locked screen, restricted process) returns 0 rather
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

; Returns 1 if the focused control carries the ES_PASSWORD style, 0 otherwise.
; Uses ControlGetStyle which inspects the Win32 ES_PASSWORD flag (0x20) — the
; most reliable heuristic without full UIAutomation COM registration.
; @return {Integer} 1 = secure field, 0 = normal field or query failed.
SFD_IsSecureField() {
	try {
		local FocusedCtrl := ControlGetFocus(A)
		if FocusedCtrl = 
			return 0
		local Style := ControlGetStyle(FocusedCtrl, A)
		; ES_PASSWORD = 0x20 — password edit field marker set by CreateWindowEx
		return (Style & 0x20) ? 1 : 0
	} catch {
		return 0
	}
}

; Returns 1 if AppId matches any entry in the SFD_SECURE_APPS constant Map.
; An empty or missing AppId is treated as non-secure to avoid false positives.
; @param AppId {String} Process name of the active application (e.g. KeePass.exe).
; @return {Integer} 1 = known password-manager app, 0 = unknown or empty AppId.
SFD_IsSecureApp(AppId) {
	if AppId = 
		return 0
	try {
		return SFD_SECURE_APPS.Has(AppId) ? 1 : 0
	} catch {
		return 0
	}
}

; No-op on AHK — context is read live at call time, no cached state to refresh.
; Exists solely to satisfy the port contract interface.
SFD_Refresh() {
	; Live queries require no pre-fetch on Windows — nothing to do here
	return
}