; modules/tap_holds/space.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Space
; DESCRIPTION:
; Space tap-hold variants: Ctrl on hold, navigation Layer on hold, Shift on
; hold. SpaceTapHold() is the shared tap/hold dispatcher; each variant below
; hooks it to the appropriate hold-action function.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ========================
; ======= 5/ SPACE =======
; ========================
; ==============================

; Shared tap logic for all Space tap-hold variants. Reads the next character
; via InputHook; on tap it forwards the Space + next character (avoiding a
; double-space when the next key is also Space). On timeout it delegates to
; HoldFn, which is responsible for activating the held modifier and blocking
; until SC039 is released. Returns true when the timeout (hold) branch fired.
SpaceTapHold(HoldFn) {
    TimeoutSec := TapHoldDuration(TapHold, "space")
    ih := InputHook("L1 T" . TimeoutSec)
    ih.Start()
    ih.Wait()
    if ih.EndReason != "Timeout" {
        ; Tap path: send the Space that was intercepted, then the captured character
        ; (omit it when it is itself a Space to avoid a double-space).
        Text := (ih.Input == " ") ? "" : ih.Input
        TextSend("{Space}" Text, "", 0)
        UpdateLastSentCharacter(" ")
        return False
    }
    HoldFn()
    return True
}

; Each #HotIf block maps exactly one SC039 condition to one hold action.
; The SC039 Up companion sends a trailing Space when the key was released
; before the InputHook timeout elapsed and no tap was already sent.

_SpaceHoldCtrl() {
    TextPressKey("LCtrl", "Down")
    KeyWait("SC039")
    TextPressKey("LCtrl", "Up")
}
_SpaceHoldLayer() {
    ActivateLayer()
    KeyWait("SC039")
    DisableLayer()
}
_SpaceHoldShift() {
    TextPressKey("LShift", "Down")
    KeyWait("SC039")
    TextPressKey("LShift", "Up")
}

#HotIf TapHoldHoldModifier(TapHold, "space") == "ctrl" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Ctrl on hold
SC039:: SpaceTapHold(_SpaceHoldCtrl)
SC039 Up:: {
    if (
        A_PriorHotkey == "SC039"
        and not CapsWordEnabled
        and A_TimeSinceThisHotkey <= TapHoldDuration(TapHold, "space")
    ) {
        TextPressKey("Space", "")
    }
}
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Layer on hold
SC039:: SpaceTapHold(_SpaceHoldLayer)
SC039 Up:: {
    if (
        A_PriorHotkey == "SC039"
        and not CapsWordEnabled
        and A_TimeSinceThisHotkey <= TapHoldDuration(TapHold, "space")
    ) {
        TextPressKey("Space", "")
        UpdateLastSentCharacter(" ")
    }
}
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") == "shift" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Shift on hold
SC039:: SpaceTapHold(_SpaceHoldShift)
SC039 Up:: {
    if (
        A_PriorHotkey == "SC039"
        and not CapsWordEnabled
        and A_TimeSinceThisHotkey <= TapHoldDuration(TapHold, "space")
    ) {
        TextPressKey("Space", "")
    }
}
#HotIf
