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

ActivateLayer() {
	global LayerEnabled := True
	ResetNumberOfRepetitions()
	UpdateCapsLockLED()
}

DisableLayer() {
	global LayerEnabled := False
	A_MaxHotkeysPerInterval := 150
	UpdateCapsLockLED()
}

ResetNumberOfRepetitions() {
	SetNumberOfRepetitions(1)
}

SetNumberOfRepetitions(NewNumber) {
	global NumberOfRepetitions := NewNumber
}

ActionLayer(action) {
	SendInput(action)
	ResetNumberOfRepetitions()
}
