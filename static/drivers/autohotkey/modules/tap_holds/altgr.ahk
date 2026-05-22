; modules/tap_holds/altgr.ahk

; ==============================================================================
; MODULE: Tap-Holds — AltGr
; DESCRIPTION:
; AltGr tap-hold: gated on not IsOnboardingActive() so the wizard's Edit
; fields receive native AltGr characters. AltGrTapHoldDispatchV2() maps the
; single configured tap_action to the corresponding key event.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ========================
; ======= 6/ ALTGR =======
; ========================
; ==============================

; The standalone ``RAlt::`` hotkey below consumes every AltGr/Kana press while
; it is active, breaking native AltGr typing in any context where the user
; expects their Windows layout to handle the key. We therefore gate it on
; ``not IsOnboardingActive()`` so the wizard's Edit fields (and anything else
; the user types while the first-run wizard is up) receive AltGr characters
; from the OS instead of the tap-hold consuming them.
#HotIf not LayerEnabled and not IsOnboardingActive() and TapHoldIsConfigured(TapHold, "alt_gr")
; Tap-hold on "AltGr"
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
RAlt:: ; Necessary to work on layouts like QWERTY
{
    tap := KeyWait("RAlt", "T" . TapHoldDuration(TapHold, "alt_gr"))
    if (tap and (A_PriorKey == "RAlt" or A_PriorKey == "^")) {
        DisableCapsWord()
        AltGrTapHoldDispatchV2()
    }
}

SC01D & ~SC138 Up::
RAlt Up:: {
    UpdateLastSentCharacter("")
}
#HotIf

; Dispatch the single v2 tap_action configured for "alt_gr". Each AltGr
; variant carries the still-held AltGr modifier on its Send (``{Blind}``
; prefix) and pairs the keystroke with an explicit UpdateLastSentCharacter
; so the deadkey / hotstring chain downstream sees the correct previous
; character marker.
AltGrTapHoldDispatchV2() {
    switch TapHoldTapAction(TapHold, "alt_gr") {
        case "backspace":
            SendEvent("{Blind}{BackSpace}")
            UpdateLastSentCharacter("BackSpace")
        case "caps_lock":
            ToggleCapsLock()
        case "caps_word":
            ToggleCapsWord()
        case "ctrl_backspace":
            SendEvent("{Blind}^{BackSpace}")
            UpdateLastSentCharacter("")
        case "ctrl_delete":
            SendEvent("{Blind}^{Delete}")
            UpdateLastSentCharacter("")
        case "delete":
            SendEvent("{Blind}{Delete}")
            UpdateLastSentCharacter("Delete")
        case "enter":
            SendEvent("{Blind}{Enter}")
            UpdateLastSentCharacter("Enter")
        case "escape":
            SendEvent("{Escape}")
        case "one_shot_shift":
            OneShotShift()
        case "tab":
            SendEvent("{Blind}{Tab}")
            UpdateLastSentCharacter("Tab")
    }
}
