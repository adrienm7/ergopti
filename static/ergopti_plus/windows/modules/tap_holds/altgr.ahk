; modules/tap_holds/altgr.ahk
; Requires: TextSender

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
        case "alt_tab_monitor":
            UpdateLastSentCharacter("")
            AltTabMonitor()
        case "backspace":
            TextPressKey("BackSpace", "Blind")
            UpdateLastSentCharacter("BackSpace")
        case "caps_lock":
            ToggleCapsLock()
        case "caps_word":
            ToggleCapsWord()
        case "copy":
            TextPressKey("c", "Blind Ctrl")
            UpdateLastSentCharacter("")
        case "ctrl_backspace":
            TextPressKey("BackSpace", "Blind Ctrl")
            UpdateLastSentCharacter("")
        case "ctrl_delete":
            TextPressKey("Delete", "Blind Ctrl")
            UpdateLastSentCharacter("")
        case "cut":
            TextPressKey("x", "Blind Ctrl")
            UpdateLastSentCharacter("")
        case "delete":
            TextPressKey("Delete", "Blind")
            UpdateLastSentCharacter("Delete")
        case "enter":
            TextPressKey("Enter", "Blind")
            UpdateLastSentCharacter("Enter")
        case "escape":
            TextPressKey("Escape", "")
        case "find":
            TextPressKey("f", "Blind Ctrl")
            UpdateLastSentCharacter("")
        case "one_shot_shift":
            OneShotShift()
        case "paste":
            TextPressKey("v", "Blind Ctrl")
            UpdateLastSentCharacter("")
        case "paste_plain":
            GesturePastePlain()
        case "redo":
            TextPressKey("y", "Blind Ctrl")
            UpdateLastSentCharacter("")
        case "select_all":
            TextPressKey("a", "Blind Ctrl")
            UpdateLastSentCharacter("")
        case "space":
            TextPressKey("Space", "Blind")
            UpdateLastSentCharacter(" ")
        case "tab":
            TextPressKey("Tab", "Blind")
            UpdateLastSentCharacter("Tab")
        case "toggle_capslock":
            ToggleCapsLock()
        case "undo":
            TextPressKey("z", "Blind Ctrl")
            UpdateLastSentCharacter("")
    }
}
