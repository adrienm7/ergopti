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

; _SpaceInputHook  — live InputHook object while SpaceTapHold is waiting, 0 otherwise.
; _SpaceIHActive   — True while the InputHook is live.
; _SpaceTapSent    — set before sending Space on tap so SC039 Up cannot race.
; _SpaceHoldFired  — set on hold path so SC039 Up never sends a trailing Space.
; _SpaceHeldVK     — VK of the key captured during the hold window via OnKeyDown.
;                    0 means no key was typed while Space was held (pure hold).
; _SpaceHoldActive — True from SpaceTapHold entry until SC039 Up teardown fires,
;                    blocks SC039 auto-repeat from launching a second invocation.
; _SpaceHoldTeardown — function called by SC039 Up to release the held modifier.
;                      Set by HoldFn before returning; SC039 Up calls and clears it.
global _SpaceInputHook   := 0
global _SpaceIHActive    := False
global _SpaceTapSent     := False
global _SpaceHoldFired   := False
global _SpaceHeldVK      := 0
global _SpaceHoldActive  := False
global _SpaceHoldTeardown := 0

; Shared tap/hold dispatcher. Uses an InputHook with L0+KeyOpt to detect whether
; a real key was pressed while Space was held, without capturing characters (which
; would cause Space auto-repeat to register as Shift+Space on some layouts).
;
; Hold path: HoldFn activates the modifier and injects the captured key if any,
; then returns immediately. SC039 Up is responsible for releasing the modifier
; via _SpaceHoldTeardown — this avoids KeyWait(SC039) which is unreliable when
; the SC039 Up event is consumed by the hotkey before KeyWait sees it.
SpaceTapHold(HoldFn) {
    global _SpaceInputHook, _SpaceIHActive, _SpaceTapSent, _SpaceHoldFired
    global _SpaceHeldVK, _SpaceHoldActive, _SpaceHoldTeardown
    if (IsSet(_SpaceHoldActive) and _SpaceHoldActive)
        return
    _SpaceHoldActive  := True
    _SpaceTapSent     := False
    _SpaceHoldFired   := False
    _SpaceHeldVK      := 0
    _SpaceHoldTeardown := 0
    TimeoutSec := TapHoldDuration(TapHold, "space")
    ih := InputHook("L0 T" . TimeoutSec)
    ; KeyOpt +N is required for OnKeyDown to fire on every key with L0.
    ih.KeyOpt("{All}", "+N")
    ih.OnKeyDown := _SpaceCaptureVK
    ih.Start()
    _SpaceInputHook := ih
    _SpaceIHActive  := True
    ih.Wait()
    _SpaceIHActive  := False
    _SpaceInputHook := 0
    if (ih.EndReason == "Stopped" and _SpaceHeldVK == 0) {
        ; Plain tap — Space Up fired before timeout and no other key was captured.
        _SpaceTapSent    := True
        _SpaceHoldActive := False
        TextPressKey("Space", "")
        global HSE_LastEndChar
        HSEMatch := HSE_FeedChar(" ")
        if (HSEMatch != "") {
            HSE_DispatchMatch(HSEMatch, HSE_LastEndChar)
            UpdateLastSentCharacter(" ")
            return False
        }
        if IsSet(_ResetPrefixBuffer)
            try _ResetPrefixBuffer()
        UpdateLastSentCharacter(" ")
        return False
    }
    ; Timeout or Stopped-with-VK → hold path.
    ; HoldFn must set _SpaceHoldTeardown before returning so SC039 Up can
    ; release the modifier. _SpaceHoldActive stays True until that Up fires.
    _SpaceHoldFired := True
    HoldFn()
    return True
}

_SpaceCaptureVK(ih, vk, sc) {
    global _SpaceHeldVK
    ; Ignore VK 32 (Space auto-repeat) — only real keys end the hold window.
    if (vk == 32)
        return
    _SpaceHeldVK := vk
    ih.Stop()
}

; SC039 Up teardown helper — called by every SC039 Up handler after the IH
; has resolved. Calls _SpaceHoldTeardown (set by HoldFn) to release the
; modifier, then resets _SpaceHoldActive so the next press is accepted.
_SpaceRelease() {
    global _SpaceHoldActive, _SpaceHoldTeardown
    if (_SpaceHoldTeardown != 0) {
        _SpaceHoldTeardown.Call()
        _SpaceHoldTeardown := 0
    }
    _SpaceHoldActive := False
}

_SpaceHoldCtrl() {
    global _SpaceHeldVK, _SpaceHoldTeardown
    SendInput("{LCtrl Down}")
    if (_SpaceHeldVK != 0)
        SendInput("^{vk" . Format("{:x}", _SpaceHeldVK) . "}")
    ; SC039 Up will call this to release Ctrl.
    _SpaceHoldTeardown := () => SendInput("{LCtrl Up}")
}
_SpaceHoldLayer() {
    global _SpaceHeldVK, _SpaceHoldTeardown
    ActivateLayer()
    if (_SpaceHeldVK != 0)
        SendInput("{vk" . Format("{:x}", _SpaceHeldVK) . "}")
    _SpaceHoldTeardown := () => DisableLayer()
}
_SpaceHoldShift() {
    global _SpaceHeldVK, _SpaceHoldTeardown
    SendInput("{LShift Down}")
    if (_SpaceHeldVK != 0)
        SendInput("+{vk" . Format("{:x}", _SpaceHeldVK) . "}")
    ; SC039 Up will call this to release Shift.
    _SpaceHoldTeardown := () => SendInput("{LShift Up}")
}

#HotIf TapHoldHoldModifier(TapHold, "space") == "ctrl" and not LayerEnabled
SC039:: SpaceTapHold(_SpaceHoldCtrl)
SC039 Up:: {
    if (IsSet(_SpaceIHActive) and _SpaceIHActive)
        _SpaceInputHook.Stop()
    else if (IsSet(_SpaceHoldFired) and _SpaceHoldFired)
        _SpaceRelease()
}
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
SC039:: SpaceTapHold(_SpaceHoldLayer)
SC039 Up:: {
    if (IsSet(_SpaceIHActive) and _SpaceIHActive)
        _SpaceInputHook.Stop()
    else if (IsSet(_SpaceHoldFired) and _SpaceHoldFired)
        _SpaceRelease()
}
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") == "shift" and not LayerEnabled
SC039:: SpaceTapHold(_SpaceHoldShift)
SC039 Up:: {
    if (IsSet(_SpaceIHActive) and _SpaceIHActive)
        _SpaceInputHook.Stop()
    else if (IsSet(_SpaceHoldFired) and _SpaceHoldFired)
        _SpaceRelease()
}
#HotIf
