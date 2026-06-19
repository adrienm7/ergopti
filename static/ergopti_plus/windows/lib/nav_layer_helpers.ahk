; drivers/autohotkey/lib/nav_layer_helpers.ahk

; ==============================================================================
; MODULE: Navigation Layer Helpers
; DESCRIPTION:
; Pure state-management functions for the navigation layer. Extracted here
; from modules/tap_holds/nav_layer.ahk so the logic is testable without
; loading hotkey-registration code.
;
; FEATURES & RATIONALE:
; 1. ActivateLayer / DisableLayer: toggle the LayerEnabled global and update
;    the CapsLock LED indicator to reflect the active state visually.
; 2. SetNumberOfRepetitions / ResetNumberOfRepetitions: manage the numeric
;    multiplier read by ActionLayer to repeat navigation keystrokes.
; 3. ActionLayer: fire a SendInput payload then reset the repetition counter,
;    so every navigation keystroke is self-contained.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Layer state helpers =======
; ======================================
; ======================================

; Default A_MaxHotkeysPerInterval as shipped by AHK v2 — restored on
; ActivateLayer to undo the elevated limit that DisableLayer sets.
global _NAV_DEFAULT_MAX_HOTKEYS := 70

ActivateLayer() {
	global LayerEnabled := True
	; Restore the standard rate limit — DisableLayer raised it to let the
	; nav layer send many synthetic keys; once the layer is off the elevated
	; limit is no longer needed and must be reset to avoid masking accidental
	; hotkey storms in the normal typing path.
	A_MaxHotkeysPerInterval := _NAV_DEFAULT_MAX_HOTKEYS
	ResetNumberOfRepetitions()
	UpdateCapsLockLED()
}

DisableLayer() {
	global LayerEnabled := False
	; Raise the per-interval cap while the nav layer is active so rapid
	; navigation bursts (e.g. Ctrl+Shift+Right held down) do not trigger
	; AHK's "too many hotkeys" warning.
	A_MaxHotkeysPerInterval := 150
	UpdateCapsLockLED()
}

ResetNumberOfRepetitions() {
	SetNumberOfRepetitions(1)
}

SetNumberOfRepetitions(NewNumber) {
	global NumberOfRepetitions := NewNumber
}

; Wrapper used by nav_layer.ahk hotkeys to read the repetition counter without
; coupling hotkey code to the global variable name directly.
AppState_GetNumberOfRepetitions() {
	global NumberOfRepetitions
	return NumberOfRepetitions
}

; Wrapper used by layout.ahk / nav_layer_helpers to update the repetition
; counter through a single named write path.
AppState_SetNumberOfRepetitions(N) {
	global NumberOfRepetitions := N
}

ActionLayer(action) {
	SendInput(action)
	ResetNumberOfRepetitions()
}
