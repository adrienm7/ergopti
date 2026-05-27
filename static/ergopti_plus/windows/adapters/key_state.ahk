; static/ergopti_plus/windows/adapters/key_state.ahk

; ==============================================================================
; MODULE: KeyState Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the KeyState port contract. Wraps the AHK v2
; built-in GetKeyState() behind two stable functions so tap-hold logic and
; modifier-detection routines can query physical key state without coupling
; to AHK-specific function syntax.
;
; NAMING CONVENTION:
; Port method  → AHK name mapping:
;   KS_IsDown(keyName) → KS_IsDown(KeyName)
;   KS_IsUp(keyName)   → KS_IsUp(KeyName)
;
; PHYSICAL MODE:
; Both functions use the "P" (physical) mode of GetKeyState exclusively.
; Logical/toggle state (CapsLock LED, NumLock) is out of scope for this adapter.
;
; FAIL-SAFE:
; GetKeyState is wrapped in try/catch. An unknown key name or any AHK error
; returns 0 (false) from KS_IsDown and 1 (true) from KS_IsUp — an absent key
; is treated as "not pressed".
; ==============================================================================



; ===========================================
; ===========================================
; ======= 1/ Adapter Functions ==============
; ===========================================
; ===========================================

; Returns 1 when the key is physically held down, 0 otherwise.
; An unknown key name or any GetKeyState error yields 0 (not pressed).
; @param KeyName {String} Platform key identifier (e.g. "SC038", "LShift").
; @return {Integer} 1 if the key is currently down, 0 otherwise.
KS_IsDown(KeyName) {
	try {
		return GetKeyState(KeyName, "P") ? 1 : 0
	} catch {
		return 0
	}
}

; Returns 1 when the key is not physically held down, 0 otherwise.
; Equivalent to !KS_IsDown(KeyName) — exists so call sites read naturally.
; @param KeyName {String} Platform key identifier (e.g. "SC038", "LShift").
; @return {Integer} 1 if the key is currently up, 0 if it is down.
KS_IsUp(KeyName) {
	try {
		return GetKeyState(KeyName, "P") ? 0 : 1
	} catch {
		return 1
	}
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_KEY_STATE := Map(
    "isDown", KS_IsDown,
    "isUp",   KS_IsUp,
)
