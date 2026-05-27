; modules/tap_holds/capslock.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — CapsLock
; DESCRIPTION:
; Handles CapsLock tap-hold variants: plain backspace, Ctrl-on-hold variants
; (v1 *Ctrl keys), and the LAlt+CapsLock shortcut integration.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ===========================
; ======= 2/ CAPSLOCK =======
; ===========================
; ==============================

; Fix for using the LAltCapsLockShortcut with LAlt remapped to OneShotShift and CapsLock not remapped
#HotIf (
    TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift"
    and not _CapsLockIsPlainBackspace()
    and not CapsLockRemappedCondition()
    and not LayerEnabled
)
SC03A:: {
    if (GetKeyState("SC038", "P")) { ; TODO(2.1.3): route through KeyState port
        LAltCapsLockShortcut()
        return
    }
    ToggleCapsLock()
}
#HotIf

#HotIf _CapsLockIsPlainBackspace() and not LayerEnabled
*SC03A:: {
    if (GetKeyState("SC038", "P")) { ; TODO(2.1.3): route through KeyState port
        LAltCapsLockShortcut()
        return
    }

    TextPressKey("BackSpace", "Blind")
}
#HotIf

; "BackSpace" variant: tap_action="backspace" without any hold modifier
; (the v1 *SC03A handler is a plain BackSpace, no Ctrl-on-hold dance).
_CapsLockIsPlainBackspace() {
    return TapHoldTapAction(TapHold, "caps_lock") == "backspace"
        and TapHoldHoldModifier(TapHold, "caps_lock") == ""
}

; Returns true when the CapsLock tap-hold has Ctrl on hold -- i.e. one of
; the v1 *Ctrl variants (BackSpaceCtrl, CapsLockCtrl, EnterCtrl, ...) is
; active. Drives the *SC03A handler that pre-arms LCtrl Down on press.
CapsLockRemappedCondition() {
    return TapHoldHoldModifier(TapHold, "caps_lock") == "ctrl"
}

#HotIf CapsLockRemappedCondition() and not LayerEnabled
*SC03A:: {
    CtrlActivated := False
    if (GetKeyState("SC01D", "P")) { ; TODO(2.1.3): route through KeyState port
        CtrlActivated := True
    }

    if (GetKeyState("SC038", "P")) { ; TODO(2.1.3): route through KeyState port
        ; Fix for using the LAltCapsLockShortcut with LAlt remapped to OneShotShift and CapsLock remapped
        LAltCapsLockShortcut()
        return
    }

    TextPressKey("LCtrl", "Down")
    tap := KeyWait("CapsLock", "T" . TapHoldDuration(TapHold, "caps_lock"))
    if (tap and A_PriorKey == "LControl") {
        TextPressKey("LCtrl", "Up")
        CapsLockShortcut(CtrlActivated)
    }
    TextPressKey("LCtrl", "Up")
}
#HotIf

CapsLockShortcut(CtrlActivated) {
    if CtrlActivated {
        TextPressKey("LCtrl", "Down")
    }

    ; Dispatch on the v2 tap_action -- only reachable when hold_modifier
    ; is "ctrl" (otherwise CapsLockRemappedCondition gates us out before
    ; we get here).
    switch TapHoldTapAction(TapHold, "caps_lock") {
        case "backspace":
            TextPressKey("BackSpace", "Blind")
        case "caps_lock":
            ToggleCapsLock()
        case "caps_word":
            ToggleCapsWord()
        case "ctrl_backspace":
            TextPressKey("BackSpace", "Ctrl")
        case "ctrl_delete":
            TextPressKey("Delete", "Ctrl")
        case "delete":
            TextPressKey("Delete", "Blind")
        case "enter":
            TextPressKey("Enter", "Blind")
            DisableCapsWord()
        case "escape":
            TextPressKey("Escape", "Blind")
        case "one_shot_shift":
            OneShotShift()
        case "tab":
            TextPressKey("Tab", "Blind")
    }

    TextPressKey("LCtrl", "Up")
}
