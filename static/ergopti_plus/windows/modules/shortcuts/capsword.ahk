; modules/shortcuts/capsword.ahk

; ==============================================================================
; MODULE: Shortcuts — CapsWord
; DESCRIPTION:
; CapsWord mode: auto-capitalises characters while the user types a word and
; deactivates on what [shortcuts.caps_word] names (a delay, a delimiter, a
; pointer kind), through capsword_auto_off.ahk.
; Reference: https://github.com/qmk/qmk_firmware/blob/master/users/drashna/keyrecords/capwords.md
;
; FEATURES & RATIONALE:
; 1. The state machine (toggle, deactivation, the LED, the end callback) lives
;    in infra/capsword_state.ahk, where the unit suite drives it. This module
;    keeps the entry points the rest of the driver calls and the two native
;    delimiter hotkeys, the only parts that cannot run in the suite.
; 2. The user's genuine CapsLock intent is flipped only by ToggleCapsLock and is
;    never re-derived from GetKeyState("CapsLock", "T"): that bit is the one the
;    LED write sets, so reading it back made the function's own output an input
;    and CapsLock survived CapsWord. It is seeded from the real toggle once by
;    the entry pre-pump owner; this module must not re-seed it after an early
;    user toggle.
; ==============================================================================

#Requires AutoHotkey v2.0




ToggleCapsWord() {
	CapsWordActivationToggle()
}

DisableCapsWord() {
	CapsWordDeactivate()
}

UpdateCapsLockLED() {
	CapsWordSyncLed()
}

; Space and Enter send their key themselves, at level 0, which the auto-off
; InputHook does not see: while their delimiter is checked they end CapsWord
; here. Unchecked, the criterion fails and the key stays native.
#HotIf CapsWordEnabled and CapsWordAutoOffEndsOnNativeKey("space")
SC039:: CapsWordAutoOffNativeKey("Space")

; Big Enter key
#HotIf CapsWordEnabled and CapsWordAutoOffEndsOnNativeKey("enter")
SC01C:: CapsWordAutoOffNativeKey("Enter")
#HotIf
