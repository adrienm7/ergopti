; modules/tap_holds/rctrl.ahk

; ==============================================================================
; MODULE: Tap-Holds — RCtrl
; DESCRIPTION:
; RCtrl tap-hold variants: BackSpace (with key-repeat), Tab+Ctrl, and
; OneShotShift.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; ==============================
; ======= 7/ RCTRL =======
; ==============================
; ==============================

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "backspace" and not LayerEnabled
; RCtrl becomes BackSpace, and Delete on Shift
SC11D::
{
    if GetKeyState("LShift", "P") {
        SendInput("{Delete}")
    } else if TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift" and GetKeyState("SC038", "P") {
        OneShotShiftFix()
        SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
    } else {
        SendEvent("{BackSpace}") ; Event to be able to correct hostrings and still trigger them afterwards
        Sleep(KEY_REPEAT_INITIAL_DELAY_MS)
        while GetKeyState("SC11D", "P") {
            SendEvent("{BackSpace}")
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
        SendEvent("{RCtrl Up}")
        SendEvent("{Tab}") ; To be able to trigger hotstrings with a Tab ending character
    }
}

+SC11D:: SendInput("+{Tab}")
^SC11D:: SendInput("^{Tab}")
^+SC11D:: SendInput("^+{Tab}")
#SC11D:: SendEvent("#{Tab}") ; SendInput doesn't work in that case
#HotIf

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift" and not LayerEnabled
; Tap-hold on "RCtrl" : OneShotShift on tap, Shift on hold
SC11D:: {
    OneShotShift()
    SendEvent("{LShift Down}")
    KeyWait("SC11D")
    SendEvent("{LShift Up}")
}
#HotIf
