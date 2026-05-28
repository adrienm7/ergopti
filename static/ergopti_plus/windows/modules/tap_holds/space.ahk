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
; Phase 2 (hold, modifier variants) — InputHook L1 captures the next key
; without any modifier active, so Space auto-repeat cannot produce
; Shift+Space or Ctrl+Space. After the IH resolves, HoldFn receives
; ih.Input (the translated char) and emits the correct modified keystroke.
;
; Phase 2 (hold, layer variant) — mirrors LAlt: the layer is activated
; immediately at hold-threshold so physical keys land directly on the
; #HotIf LayerEnabled hotkeys. No InputHook is used; nav_layer.ahk
; already has SC039::return to silence Space auto-repeat while the layer
; is active.
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

SpaceTapHoldLayer() {
    ; Mirror the LAlt layer pattern exactly: activate the layer at keydown so
    ; every subsequent physical key lands on #HotIf LayerEnabled hotkeys.
    ; After Space is released, check whether it was a quick tap (no layer key
    ; was used) and send Space retroactively if so.
    UpdateLastSentCharacter("Space")
    ActivateLayer()
    KeyWait("SC039", "U")
    DisableLayer()

    Now := A_TickCount
    CharacterSentTime := LastSentCharacterKeyTime.Has("Space") ? LastSentCharacterKeyTime["Space"] : Now
    tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "space") * 1000)
    ; Only send Space on tap when no layer key was consumed — A_PriorKey stays
    ; "Space" (SC039) when the user releases without pressing anything else.
    if (tap and A_PriorKey == "Space") {
        _SpaceTap()
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

#HotIf TapHoldHoldModifier(TapHold, "space") == "ctrl" and not LayerEnabled
SC039:: SpaceTapHold(_SpaceHoldCtrl)
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
SC039:: SpaceTapHoldLayer()
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") == "shift" and not LayerEnabled
SC039:: SpaceTapHold(_SpaceHoldShift)
#HotIf
