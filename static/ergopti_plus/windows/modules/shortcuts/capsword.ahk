; modules/shortcuts/capsword.ahk

; ==============================================================================
; MODULE: Shortcuts — CapsWord
; DESCRIPTION:
; CapsWord mode: auto-capitalises characters while the user types a word and
; deactivates as soon as Space, Enter, or a mouse click is detected.
; Reference: https://github.com/qmk/qmk_firmware/blob/master/users/drashna/keyrecords/capwords.md
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================
; ===========================
; ======= 6/ CAPSWORD =======
; ===========================
; ===========================

ToggleCapsWord() {
    global CapsWordEnabled := not CapsWordEnabled
    UpdateCapsLockLED()
}

DisableCapsWord() {
    global CapsWordEnabled := False
    UpdateCapsLockLED()
}

; UpdateCapsLockLED is the SINGLE owner of the physical CapsLock LED. Three
; logical states can independently want the LED lit: CapsWord, the nav layer,
; and a real hardware CapsLock toggle (AltGr+CapsLock). Computing the LED from
; the OR of all three — instead of letting each state drive SetCapsLockState
; on its own — keeps the LED a reliable indicator no matter how the three are
; interleaved. ToggleCapsLock flips the hardware toggle then routes through
; here so the LED can never disagree with the union of the logical states.
UpdateCapsLockLED() {
    if CapsWordEnabled or LayerEnabled or GetKeyState("CapsLock", "T") {
        SetCapsLockState("On")
    } else {
        SetCapsLockState("Off")
    }
}

; Defines what deactivates the CapsLock triggered by CapsWord
#HotIf CapsWordEnabled
SC039::
{
    TextPressKey("Space", [])
    Keywait("SC039") ; Solves bug of 2 sent Spaces when exiting CapsWord with a Space
    DisableCapsWord()
}

; Big Enter key
SC01C::
{
    TextPressKey("Enter", [])
    DisableCapsWord()
}

; Mouse click
~LButton::
~RButton::
{
    if (GestureLeftClickHeld) {
        GestureReleaseLeftClick()
    }
    if (GestureRightClickHeld) {
        GestureReleaseRightClick()
    }
    DisableCapsWord()
}
#HotIf
