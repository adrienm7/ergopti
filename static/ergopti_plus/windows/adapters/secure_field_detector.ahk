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
; All AHK control-inspection calls are wrapped in try/catch. A detector failure
; is treated as secure while privacy protection is enabled: sending unknown
; focused-field content to an LLM is irreversible, whereas one delayed
; prediction is recoverable. UIA confirmation runs from a deferred timer and
; is cached by focus HWND, never on the character hook.
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

; One focus-scoped triage cache. ``pending_hwnd`` prevents repeated calls while
; typing in an unknown browser/Electron control from queuing UIA work per key.
global SFD_FIELD_CACHE := Map(
	"hwnd", 0,
	"secure", true,
	"at", 0,
	"pending_hwnd", 0
)
global SFD_FIELD_CACHE_TTL_MS := 1000



; ======================================
; ======================================
; ======= 2/ Adapter Functions =======
; ======================================
; ======================================

; Returns true if the focused control is secure OR cannot yet be classified.
; The cheap native path is synchronous; an inconclusive browser/Electron/WPF
; control is denied once and confirmed with UIA on a deferred callback.
SFD_IsSecureField() {
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS
	Hwnd := SFD_FocusedHwnd()
	if !Hwnd
		return true
	if (SFD_FIELD_CACHE["hwnd"] = Hwnd) {
		if (((A_TickCount - SFD_FIELD_CACHE["at"]) & 0xFFFFFFFF) >= SFD_FIELD_CACHE_TTL_MS)
			SFD_ScheduleUiaProbe(Hwnd)
		return SFD_FIELD_CACHE["secure"]
	}

	Conclusive := false
	Secure := SFD_DetectNative(Hwnd, &Conclusive)
	if !Conclusive {
		; Unknown is fail-closed until the asynchronous UIA probe establishes a
		; normal field. This protects browser password boxes and UAC-restricted UI.
		Secure := true
		SFD_ScheduleUiaProbe(Hwnd)
	}
	SFD_CommitFieldVerdict(Hwnd, Secure)
	return Secure
}

SFD_FocusedHwnd() {
	try {
		Hwnd := ControlGetHwnd(ControlGetFocus("A"), "A")
		if Hwnd
			return Hwnd
	}
	try return WinGetID("A")
	return 0
}

SFD_DetectNative(Hwnd, &Conclusive) {
	Conclusive := false
	try {
		ClassName := WinGetClass("ahk_id " . Hwnd)
		if !RegExMatch(ClassName, "i)^(Edit|RichEdit)")
			return false
		Conclusive := true
		return (WinGetStyle("ahk_id " . Hwnd) & 0x20) ? true : false
	}
	return false
}

SFD_CommitFieldVerdict(Hwnd, Secure) {
	global SFD_FIELD_CACHE
	; Publish the key last so concurrent reader callbacks cannot pair a new HWND
	; with the previous control's verdict.
	SFD_FIELD_CACHE["secure"] := !!Secure
	SFD_FIELD_CACHE["at"] := A_TickCount
	SFD_FIELD_CACHE["hwnd"] := Hwnd
}

SFD_ScheduleUiaProbe(Hwnd) {
	global SFD_FIELD_CACHE
	if (SFD_FIELD_CACHE["pending_hwnd"] = Hwnd)
		return
	SFD_FIELD_CACHE["pending_hwnd"] := Hwnd
	try SetTimer(SFD_ProbeFocusedUia.Bind(Hwnd), -1)
	catch {
		if (SFD_FIELD_CACHE["pending_hwnd"] = Hwnd)
			SFD_FIELD_CACHE["pending_hwnd"] := 0
	}
}

SFD_ProbeFocusedUia(Hwnd) {
	global SFD_FIELD_CACHE
	if A_IsSuspended {
		if (SFD_FIELD_CACHE["pending_hwnd"] = Hwnd)
			SFD_FIELD_CACHE["pending_hwnd"] := 0
		return
	}
	; UIA may take milliseconds or fail for an elevated/closing target. Both cases
	; remain secure; this callback is deliberately outside the prediction/hook path.
	Secure := true
	try {
		if !IsSet(UIA)
			throw Error("UIA unavailable")
		Element := UIA.GetFocusedElement()
		if !IsObject(Element)
			throw Error("No focused UIA element")
		Secure := Element.GetCurrentPropertyValue(UIA.Property.IsPassword) ? true : false
	}
	SFD_CommitFieldVerdict(Hwnd, Secure)
	if (SFD_FIELD_CACHE["pending_hwnd"] = Hwnd)
		SFD_FIELD_CACHE["pending_hwnd"] := 0
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
