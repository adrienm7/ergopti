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

; Design: two-phase tap/hold without holding a modifier during KeyWait.
;
; Phase 1 — tap/hold discrimination via KeyWait with timeout:
;   KeyWait returns 1 (key released before timeout) → TAP: send Space.
;   KeyWait returns 0 (timeout reached, Space still held) → HOLD.
;
; Phase 2 (hold only) — wait for the next keydown via InputHook (L1, no KeyOpt
; so keys are NOT suppressed and reach the application normally). The IH runs
; with {LShift Down} NOT active yet, so Space auto-repeat only produces spaces
; in the app (or nothing, since SC039 is intercepted). When a real key is
; detected (or the IH times out after a long wait), activate the modifier,
; inject the captured key if any, then wait for Space Up via a second KeyWait.
; Shift is active only for that brief window — no auto-repeat of Shift+Space.
;
; No SC039 Up hotkey — both KeyWaits see the Up event directly (no hotkey
; to steal it). This matches the pattern used by capslock.ahk and lalt.ahk.
;
; After sending Space, HSE_FeedChar(" ") is called explicitly because SendInput
; bypasses the prefix-watcher InputHook.

global _SpaceHeldVK := 0

_SpaceCaptureVK(ih, vk, sc) {
    global _SpaceHeldVK
    ; Ignore Space auto-repeat (VK 32) — only a real key ends the hold window.
    if (vk == 32)
        return
    _SpaceHeldVK := vk
    ih.Stop()
}

SpaceTapHold(ModDownFn, ModUpFn) {
    global _SpaceHeldVK
    TimeoutSec := TapHoldDuration(TapHold, "space")
    tap := KeyWait("SC039", "T" . TimeoutSec)
    if tap {
        ; Released before timeout → tap: send Space.
        _SpaceTap()
        return
    }
    ; Held past threshold → hold: wait for a real key via IH before activating
    ; the modifier. L1 without KeyOpt so keys pass through to the app normally.
    ; OnKeyDown fires only with +N, so use ih.Input (the captured char) to detect
    ; what was typed — but also track VK via OnKeyDown+KeyOpt for the modifier
    ; injection. Since we need both: use KeyOpt only for notification (not suppress),
    ; then re-send the captured VK with the modifier active.
    _SpaceHeldVK := 0
    ih := InputHook("L1 T3")
    ih.KeyOpt("{All}", "+N")
    ih.OnKeyDown := _SpaceCaptureVK
    ih.Start()
    ih.Wait()
    ; Activate modifier only now — modifier was not active during the IH window
    ; so Space auto-repeat could only produce unmodified spaces (or nothing).
    ModDownFn.Call()
    if (_SpaceHeldVK != 0)
        SendInput("{vk" . Format("{:x}", _SpaceHeldVK) . "}")
    ; "U" returns immediately if SC039 is already up (released during IH window).
    KeyWait("SC039", "U T2")
    ModUpFn.Call()
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
    () => SendInput("{LCtrl Up}")
)
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
SC039:: SpaceTapHold(ActivateLayer, DisableLayer)
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") == "shift" and not LayerEnabled
SC039:: SpaceTapHold(
    () => SendInput("{LShift Down}"),
    () => SendInput("{LShift Up}")
)
#HotIf
