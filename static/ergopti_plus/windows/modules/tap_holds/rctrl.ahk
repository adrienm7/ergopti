; modules/tap_holds/rctrl.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — RCtrl
; DESCRIPTION:
; RCtrl tap-hold variants: BackSpace (with key-repeat), Tab+Ctrl, and
; OneShotShift.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ========================
; ======= 7/ RCTRL =======
; ========================
; ==============================

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "backspace" and not LayerEnabled
; RCtrl becomes BackSpace, and Delete on Shift
SC11D::
{
    if KS_IsDown("LShift") { ; LShift physically held
        TextPressKey("Delete", "")
    } else if TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift" and KS_IsDown("SC038") { ; LAlt physically held
        OneShotShiftFix()
        TextPressKey("Right", "")
        TextPressKey("BackSpace", "") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
    } else {
        TextPressKey("BackSpace", "") ; Event to be able to correct hotstrings and still trigger them afterwards
        Sleep(KEY_REPEAT_INITIAL_DELAY_MS)
        while KS_IsDown("SC11D") { ; RCtrl still physically held — key-repeat loop
            TextPressKey("BackSpace", "")
            Sleep(KEY_REPEAT_INTERVAL_MS)
        }
    }
}
#HotIf

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "tab" and not LayerEnabled
; Tap-hold on "RCtrl" : Tab on tap, Ctrl on hold
~SC11D:: {
    tap := KeyWait("RControl", "T" . TapHoldDuration(TapHold, "right_ctrl"))
    if (tap and A_PriorKey == "RControl") {
        TextPressKey("RCtrl", "Up")
        TextPressKey("Tab", "") ; To be able to trigger hotstrings with a Tab ending character
    }
}

+SC11D:: TextPressKey("Tab", "Shift")
^SC11D:: TextPressKey("Tab", "Ctrl")
^+SC11D:: TextPressKey("Tab", "Ctrl Shift")
#SC11D:: TextPressKey("Tab", "Win") ; TextPressKey must be used here — SendInput doesn't work in that case
#HotIf

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift" and not LayerEnabled
; Tap-hold on "RCtrl" : OneShotShift on tap, Shift on hold
SC11D:: {
    OneShotShift()
    TextPressKey("LShift", "Down")
    KeyWait("SC11D")
    TextPressKey("LShift", "Up")
}
#HotIf
