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
	"1Password.exe",        true,
	"KeePass.exe",          true,
	"KeePassXC.exe",        true,
	"Bitwarden.exe",        true,
	"LastPass.exe",         true,
	"Dashlane.exe",         true,
	"RoboForm.exe",         true,
	"Authy.exe",            true,
	"keepass2.exe",         true,
	"credential_guard",     true
)



; ======================================
; ======================================
; ======= 2/ Adapter Functions =======
; ======================================
; ======================================

; Returns true if the focused control carries the ES_PASSWORD style, false otherwise.
; Uses ControlGetStyle which inspects the Win32 ES_PASSWORD flag (0x20) — the
; most reliable heuristic without full UIAutomation COM registration.
; The ES_PASSWORD bit is only meaningful on Edit controls; checking it on other
; control classes (ComboBox, ListView, etc.) risks false positives because
; those classes may set the same bit for unrelated reasons.
; @return {Boolean} True on success, false on error.
SFD_IsSecureField() {
	try {
		local FocusedCtrl := ControlGetFocus("A")
		if FocusedCtrl = ""
			return false
		; Guard: ES_PASSWORD (0x20) is only defined for Edit controls; other
		; Win32 class families reuse the same bit position for different meanings.
		; ControlGetClassNN returns e.g. "Edit1", "RichEdit20W1" etc. — the name
		; always starts with the Win32 class prefix before the index digit.
		local ClassNN := ControlGetClassNN(FocusedCtrl, "A")
		if !RegExMatch(ClassNN, "i)^(Edit|RichEdit)")
			return false
		local Style := ControlGetStyle(FocusedCtrl, "A")
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
	if AppId = ""
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
    "isSecureField", SFD_IsSecureField,
    "isSecureApp",   SFD_IsSecureApp,
    "refresh",       SFD_Refresh,
)
