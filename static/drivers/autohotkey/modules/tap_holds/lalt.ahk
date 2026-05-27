; modules/tap_holds/lalt.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — LAlt
; DESCRIPTION:
; LAlt tap-hold variants: OneShotShift, Tab+Layer, AltTabMonitor, BackSpace,
; and BackSpace+Layer. The BackSpace variants include key-repeat and
; Shift/Ctrl modifier logic shared via BackSpaceLogic().
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; =======================
; ======= 4/ LALT =======
; =======================
; ==============================

; LAlt v2 variants share two tap-actions and a hold-layer slot:
;   OneShotShift  -> tap=one_shot_shift, hold_mod=alt
;   TabLayer      -> tap=tab,            hold_layer=nav
;   AltTabMonitor -> tap=alt_tab_monitor, hold_mod=alt
;   BackSpace     -> tap=backspace       (key-repeat, no hold)
;   BackSpaceLayer-> tap=backspace,      hold_layer=nav
; The two backspace variants are distinguished by hold_layer presence.
_LAltIsPlainBackspace() {
    return TapHoldTapAction(TapHold, "left_alt") == "backspace"
        and TapHoldHoldLayer(TapHold, "left_alt") == ""
}
_LAltIsBackspaceLayer() {
    return TapHoldTapAction(TapHold, "left_alt") == "backspace"
        and TapHoldHoldLayer(TapHold, "left_alt") == "nav"
}

#HotIf TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift" and not LayerEnabled
; Tap-hold on "LAlt" : OneShotShift on tap, Shift on hold
SC038:: {
    if (
        GetKeyState("SC11D", "P") ; TODO(2.1.3): route through KeyState port
        or GetKeyState("SC03A", "P") ; TODO(2.1.3): route through KeyState port
        or GetKeyState("LShift", "P") ; TODO(2.1.3): route through KeyState port
        or GetKeyState("LCtrl", "P") ; TODO(2.1.3): route through KeyState port
    ) {
        ; Solves a problem where shorcuts consisting of another key (pressed first) + SC038 (pressed second) triggers the shortcut, but also OneShotShift()
        return
    }

    TextPressKey("LAlt", "Up")
    OneShotShift()
    TextPressKey("LShift", "Down")
    KeyWait("SC038")
    TextPressKey("LShift", "Up")
}
#HotIf

#HotIf TapHoldTapAction(TapHold, "left_alt") == "tab" and not LayerEnabled
; Tap-hold on "LAlt" : Tab on tap, Layer on hold
SC038::
{
    UpdateLastSentCharacter("LAlt")

    ActivateLayer()
    KeyWait("SC038")
    DisableLayer()

    Now := A_TickCount
    CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
    tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "left_alt") * 1000)
    if tap {
        TextPressKey("Tab", "")
    }
}

SC02A & SC038:: TextPressKey("Tab", "Shift") ; On "LShift"
if TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift" {
    SC11D & SC038:: {
        OneShotShiftFix()
        TextPressKey("Tab", "Shift")
    }
}
#SC038:: TextPressKey("Tab", "Win") ; Doesn't fire when SendInput is used
!SC038:: TextPressKey("Tab", "Alt")
#HotIf

#HotIf TapHoldTapAction(TapHold, "left_alt") == "alt_tab_monitor" and not LayerEnabled
; Tap-hold on "LAlt" : AltTabMonitor on tap, Alt on hold
SC038::
{
    TextPressKey("LAlt", "Down")
    tap := KeyWait("SC038", "T" . TapHoldDuration(TapHold, "left_alt"))
    if tap {
        TextPressKey("LAlt", "Up")
        AltTabMonitor()
    } else {
        KeyWait("SC038")
        TextPressKey("LAlt", "Up")
    }
}
#HotIf

#HotIf _LAltIsPlainBackspace() and not LayerEnabled
; "LAlt" becomes BackSpace, and Delete on Shift
*SC038::
{
    BackSpaceActionWithModifiers := BackSpaceLogic()
    if not BackSpaceActionWithModifiers {
        ; If no modifier was pressed
        TextPressKey("BackSpace", "") ; Event to be able to correct hotstrings and still trigger them afterwards
        Sleep(KEY_REPEAT_INITIAL_DELAY_MS)
        while GetKeyState("SC038", "P") { ; TODO(2.1.3): route through KeyState port
            TextPressKey("BackSpace", "")
            Sleep(KEY_REPEAT_INTERVAL_MS)
        }
    }
}
#HotIf

#HotIf _LAltIsBackspaceLayer() and not LayerEnabled
; Tap-hold on "LAlt" : BackSpace on tap, Layer on hold
*SC038::
{
    UpdateLastSentCharacter("LAlt")

    ActivateLayer()
    KeyWait("SC038")
    DisableLayer()

    Now := A_TickCount
    CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
    tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "left_alt") * 1000)

    if (
        tap
        and A_PriorKey == "LAlt" ; Prevents triggering BackSpace when the layer is quickly used and then released
        and not GetKeyState("SC03A", "P") ; TODO(2.1.3): route through KeyState port — Fix a sent BackSpace when triggering quickly "LAlt" + "CapsLock"
    ) {
        BackSpaceActionWithModifiers := BackSpaceLogic()
        if not BackSpaceActionWithModifiers {
            ; If no modifier was pressed
            TextPressKey("BackSpace", "")
        }
    }
}
#HotIf

BackSpaceLogic() {
    RCtrlIsOneShotShift := TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift"

    if (
        GetKeyState("SC01D", "P") ; TODO(2.1.3): route through KeyState port
        and GetKeyState("Shift", "P") ; TODO(2.1.3): route through KeyState port
    ) {
        ; "LCtrl" and Shift
        TextPressKey("Delete", "Ctrl")
        return True
    } else if (
        GetKeyState("SC11D", "P") ; TODO(2.1.3): route through KeyState port
        and not RCtrlIsOneShotShift
        and GetKeyState("Shift", "P") ; TODO(2.1.3): route through KeyState port
    ) {
        ; "RCtrl" when it stays RCtrl and Shift
        TextPressKey("Delete", "Ctrl")
        return True
    } else if (
        GetKeyState("SC01D", "P") ; TODO(2.1.3): route through KeyState port
        and RCtrlIsOneShotShift
        and GetKeyState("SC11D", "P") ; TODO(2.1.3): route through KeyState port
    ) {
        ; "LCtrl" and Shift on "RCtrl"
        OneShotShiftFix()
        TextPressKey("Right", "Ctrl")
        TextPressKey("BackSpace", "Ctrl") ; = ^Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
        return True
    } else if (
        RCtrlIsOneShotShift
        and GetKeyState("SC11D", "P") ; TODO(2.1.3): route through KeyState port
    ) {
        ; Shift on "RCtrl"
        OneShotShiftFix()
        TextPressKey("Right", "")
        TextPressKey("BackSpace", "") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
        return True
    } else if GetKeyState("Shift", "P") { ; TODO(2.1.3): route through KeyState port
        ; Shift
        TextPressKey("Delete", "")
        return True
    } else if GetKeyState("SC01D", "P") { ; TODO(2.1.3): route through KeyState port
        ; "LCtrl"
        TextPressKey("BackSpace", "Ctrl")
        return True
    } else if (
        not RCtrlIsOneShotShift
        and GetKeyState("SC11D", "P") ; TODO(2.1.3): route through KeyState port
    ) {
        ; "RCtrl" when it stays RCtrl
        TextPressKey("BackSpace", "Ctrl")
        return True
    }
    return False
}
