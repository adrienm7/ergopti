; modules/shortcuts/base_modifier.ahk

; ==============================================================================
; MODULE: Shortcuts — Base Modifier Combos
; DESCRIPTION:
; Implements the LAlt+CapsLock combo that dispatches one of the ten configurable
; actions. The hotkey is only armed when LAlt is not claimed by a tap-hold
; variant (tap-hold intercepts SC038 and would swallow the chord).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================
; ===============================
; ======= 2/ BASE MODIFIER =======
; ===============================
; ===============================

; LAlt v2 tap-hold variants intercept SC038, so the bare SC038 & SC03A
; combo can only fire when LAlt remains a plain modifier (no tap-hold
; configured for left_alt or only the OneShotShift variant which we
; explicitly exclude here).
_LAltKeepsBareModifierForCapsLockCombo() {
    TapAct := TapHoldTapAction(TapHold, "left_alt")
    if (TapAct == "")
        return true  ; LAlt not configured for tap-hold -> bare modifier
    ; Block all configured tap-holds (each intercepts SC038 and would
    ; eat the combo before AHK could test the LAlt+CapsLock chord).
    return false
}

#HotIf _LAltKeepsBareModifierForCapsLockCombo()
SC038 & SC03A:: LAltCapsLockShortcut()
#HotIf

LAltCapsLockShortcut() {
    ; All ten possible actions are simple, no Shift inversion or modifier
    ; bracketing needed -- inline v2 if/else cascade (action table is the
    ; SIMPLE_ACTIONS Map that used to live in lib/dispatchers.ahk).
    if Features["shortcuts"]["lalt_caps_lock"]["backspace"] {
        SendEvent("{BackSpace}")
    } else if Features["shortcuts"]["lalt_caps_lock"]["caps_lock"] {
        ToggleCapsLock()
    } else if Features["shortcuts"]["lalt_caps_lock"]["caps_word"] {
        ToggleCapsWord()
    } else if Features["shortcuts"]["lalt_caps_lock"]["ctrl_backspace"] {
        SendInput("^{BackSpace}")
    } else if Features["shortcuts"]["lalt_caps_lock"]["ctrl_delete"] {
        SendInput("^{Delete}")
    } else if Features["shortcuts"]["lalt_caps_lock"]["delete"] {
        SendInput("{Delete}")
    } else if Features["shortcuts"]["lalt_caps_lock"]["enter"] {
        SendInput("{Enter}")
    } else if Features["shortcuts"]["lalt_caps_lock"]["escape"] {
        SendInput("{Escape}")
    } else if Features["shortcuts"]["lalt_caps_lock"]["one_shot_shift"] {
        OneShotShift()
    } else if Features["shortcuts"]["lalt_caps_lock"]["tab"] {
        SendInput("{Tab}")
    }
}
