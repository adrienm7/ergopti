; modules/shortcuts/capsword.ahk

; ==============================================================================
; MODULE: Shortcuts — CapsWord
; DESCRIPTION:
; CapsWord mode: auto-capitalises characters while the user types a word and
; deactivates as soon as Space, Enter, or a mouse click is detected.
; Reference: https://github.com/qmk/qmk_firmware/blob/master/users/drashna/keyrecords/capwords.md
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ===========================
; ======= 6/ CAPSWORD =======
; ===========================
; ==============================

ToggleCapsWord() {
    global CapsWordEnabled := not CapsWordEnabled
    UpdateCapsLockLED()
}

DisableCapsWord() {
    global CapsWordEnabled := False
    UpdateCapsLockLED()
}

UpdateCapsLockLED() {
    if CapsWordEnabled or LayerEnabled {
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
    DisableCapsWord()
}
#HotIf
