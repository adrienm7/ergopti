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

; Design: two-phase tap/hold, modifier never held during auto-repeat window.
;
; Phase 1 — KeyWait with timeout discriminates tap from hold:
;   tap=1 → Space released before threshold → send Space.
;   tap=0 → Space held past threshold → enter hold phase.
;
; Phase 2 (hold) — InputHook L1 captures the next key without any modifier
; active, so Space auto-repeat cannot produce Shift+Space or Ctrl+Space.
; After the IH resolves, HoldFn receives ih.Input (the captured char, or ""
; on pure hold/timeout) and is responsible for activating the modifier,
; injecting the char correctly, and releasing the modifier.
; KeyWait("SC039", "U") then waits for Space release (returns immediately
; if already released during the IH window).
;
; After sending Space on tap, HSE_FeedChar(" ") is called explicitly because
; SendInput bypasses the prefix-watcher InputHook.

SpaceTapHold(HoldFn) {
    TimeoutSec := TapHoldDuration(TapHold, "space")
    tap := KeyWait("SC039", "T" . TimeoutSec)
    if tap {
        _SpaceTap()
        return
    }
    ih := InputHook("L1 T3")
    ih.Start()
    ih.Wait()
    HoldFn.Call(ih.Input)
    KeyWait("SC039", "U T2")
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

_SpaceHoldCtrl(captured) {
    SendInput("{LCtrl Down}")
    ; Use ^ prefix so the key is sent as Ctrl+<key> regardless of layout.
    ; captured is already the translated char (e.g. 'a'), ^ applies Ctrl to it.
    if (captured != "" and captured != " ")
        SendInput("^" . captured)
    KeyWait("SC039", "U T2")
    SendInput("{LCtrl Up}")
}

_SpaceHoldShift(captured) {
    SendInput("{LShift Down}")
    ; captured is already layout-translated — re-sending it with + would
    ; double-translate (Shift applied to the already-shifted char). Drop it:
    ; the user holds Space+Shift to capitalise subsequent keys, not the one
    ; that triggered the hold detection.
    KeyWait("SC039", "U T2")
    SendInput("{LShift Up}")
}

_SpaceHoldLayer(captured) {
    ActivateLayer()
    if (captured != "" and captured != " ")
        SendInput("{Text}" . captured)
    KeyWait("SC039", "U T2")
    DisableLayer()
}

#HotIf TapHoldHoldModifier(TapHold, "space") == "ctrl" and not LayerEnabled
SC039:: SpaceTapHold(_SpaceHoldCtrl)
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
SC039:: SpaceTapHold(_SpaceHoldLayer)
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") == "shift" and not LayerEnabled
SC039:: SpaceTapHold(_SpaceHoldShift)
#HotIf
