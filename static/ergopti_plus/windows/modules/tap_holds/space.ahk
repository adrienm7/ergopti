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

; _SpaceInputHook — the live InputHook object while SpaceTapHold is waiting,
;                   0 otherwise. SC039 Up calls Stop() on it to signal a plain
;                   tap (press+release with no following character) so the hook
;                   terminates immediately with EndReason "Stopped" rather than
;                   waiting for the full timeout and falling into the hold path.
; _SpaceIHActive  — companion flag: true while _SpaceInputHook is live.
;                   Lets SC039 Up distinguish "IH running → call Stop()" from
;                   "IH already resolved → check _SpaceTapSent / _SpaceHoldFired".
; _SpaceTapSent   — set before sending Space on the tap path so SC039 Up
;                   cannot race after ih.Wait() returns.
; _SpaceHoldFired — set on the hold path so SC039 Up never sends a trailing
;                   Space after a long press (A_TimeSinceThisHotkey is ~0 ms
;                   right after HoldFn returns, making the timing guard useless).
global _SpaceInputHook := 0
global _SpaceIHActive  := False
global _SpaceTapSent   := False
global _SpaceHoldFired := False

; Shared tap logic for all Space tap-hold variants. Reads the next character
; via InputHook; on tap it forwards the Space + next character (avoiding a
; double-space when the next key is also Space). On timeout it delegates to
; HoldFn, which is responsible for activating the held modifier and blocking
; until SC039 is released. Returns true when the timeout (hold) branch fired.
;
; After sending Space, HSE_FeedChar(" ") is called explicitly because
; TextPressKey uses SendInput which bypasses the prefix-watcher InputHook —
; without this call, end-char-gated hotstrings never fire on Space.
SpaceTapHold(HoldFn) {
    global _SpaceInputHook, _SpaceIHActive, _SpaceTapSent, _SpaceHoldFired
    _SpaceTapSent  := False
    _SpaceHoldFired := False
    TimeoutSec := TapHoldDuration(TapHold, "space")
    ih := InputHook("L1 T" . TimeoutSec)
    ih.Start()
    _SpaceInputHook := ih
    _SpaceIHActive  := True
    ih.Wait()
    _SpaceIHActive  := False
    _SpaceInputHook := 0
    if ih.EndReason != "Timeout" {
        ; Tap path: flag first so SC039 Up cannot race between the flag set
        ; and the actual send. TextSend uses SendText (raw mode) — {Space}
        ; must go through TextPressKey so AHK interprets the key name rather
        ; than typing the literal braces.
        _SpaceTapSent := True
        TextPressKey("Space", "")
        ; TextPressKey uses SendInput which bypasses the prefix-watcher InputHook.
        ; Feed Space into HSE manually so end-char-gated hotstrings can fire,
        ; and reset the prefix watcher buffer (also bypassed by SendInput).
        global HSE_LastEndChar
        HSEMatch := HSE_FeedChar(" ")
        if (HSEMatch != "") {
            ; A hotstring fired on Space — dispatch handles the full send
            ; (backspaces + replacement + end-char re-emit). Send ih.Input
            ; afterward so the character captured during the tap window is
            ; not silently dropped.
            HSE_DispatchMatch(HSEMatch, HSE_LastEndChar)
            UpdateLastSentCharacter(" ")
            if (ih.Input != "")
                TextSend(ih.Input, "", 0)
            return False
        }
        ; No hotstring fired — still need to reset the prefix buffer so the
        ; next word starts fresh (SendInput bypasses the InputHook, so the
        ; watcher never sees this Space otherwise).
        if IsSet(_ResetPrefixBuffer)
            try _ResetPrefixBuffer()
        if (ih.Input != "")
            TextSend(ih.Input, "", 0)
        UpdateLastSentCharacter(" ")
        return False
    }
    _SpaceHoldFired := True
    HoldFn()
    return True
}

; Each #HotIf block maps exactly one SC039 condition to one hold action.
; The SC039 Up companion signals a plain tap (press+release with no following
; character) by stopping the live InputHook when _SpaceIHActive is true —
; Stop() terminates ih.Wait() with EndReason "Stopped" (≠ "Timeout"), so
; SpaceTapHold takes the tap path and sends the Space itself. When the IH has
; already resolved (_SpaceIHActive false), the Up handler is a no-op because
; _SpaceTapSent or _SpaceHoldFired will be set.

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
    if _SpaceIHActive {
        _SpaceInputHook.Stop()
    }
}
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Layer on hold
SC039:: SpaceTapHold(_SpaceHoldLayer)
SC039 Up:: {
    if _SpaceIHActive {
        _SpaceInputHook.Stop()
    }
}
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") == "shift" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Shift on hold
SC039:: SpaceTapHold(_SpaceHoldShift)
SC039 Up:: {
    if _SpaceIHActive {
        _SpaceInputHook.Stop()
    }
}
#HotIf
