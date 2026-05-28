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

; Design: pure KeyWait-based tap/hold, no InputHook.
;
; On Space down: activate modifier immediately (Down), then KeyWait with T timeout.
;   - KeyWait returns 1 (timeout not reached) → Space released within threshold → TAP:
;     release modifier, send Space tap action.
;   - KeyWait returns 0 (timeout reached) → Space held past threshold → HOLD:
;     modifier stays active, second KeyWait waits for Space release, then release modifier.
;
; No SC039 Up hotkey — KeyWait sees the Up event directly. This matches the
; pattern used by capslock.ahk and lalt.ahk which work reliably for the same reason.
;
; After sending Space, HSE_FeedChar(" ") is called explicitly because SendInput
; bypasses the prefix-watcher InputHook.

SpaceTapHold(DownFn, TapFn, UpFn) {
    TimeoutSec := TapHoldDuration(TapHold, "space")
    DownFn.Call()
    tap := KeyWait("SC039", "T" . TimeoutSec)
    if tap {
        ; Released before timeout — tap path: undo the modifier and send Space.
        UpFn.Call()
        TapFn.Call()
    } else {
        ; Held past threshold — hold path: wait for release then undo modifier.
        KeyWait("SC039")
        UpFn.Call()
    }
}

_SpaceTap() {
    TextPressKey("Space", "")
    global HSE_LastEndChar
    HSEMatch := HSE_FeedChar(" ")
    if (HSEMatch != "") {
        HSE_DispatchMatch(HSEMatch, HSE_LastEndChar)
        UpdateLastSentCharacter(" ")
        return
    }
    if IsSet(_ResetPrefixBuffer)
        try _ResetPrefixBuffer()
    UpdateLastSentCharacter(" ")
}

#HotIf TapHoldHoldModifier(TapHold, "space") == "ctrl" and not LayerEnabled
SC039:: SpaceTapHold(
    () => SendInput("{LCtrl Down}"),
    _SpaceTap,
    () => SendInput("{LCtrl Up}")
)
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
SC039:: SpaceTapHold(
    ActivateLayer,
    _SpaceTap,
    DisableLayer
)
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") == "shift" and not LayerEnabled
SC039:: SpaceTapHold(
    () => SendInput("{LShift Down}"),
    _SpaceTap,
    () => SendInput("{LShift Up}")
)
#HotIf
