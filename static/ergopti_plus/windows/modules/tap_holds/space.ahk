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
global _SpaceInputHook  := 0
global _SpaceIHActive   := False
global _SpaceTapSent    := False
global _SpaceHoldFired  := False
; Character captured by the InputHook when EndReason == "Max" (key typed while
; Space was held). HoldFn reads this and injects it with the modifier active.
global _SpaceHeldInput  := ""
; VK of the key captured during the hold window (set by OnKeyDown alongside
; _SpaceHeldInput). Used instead of ih.Input so HoldFn can replay the physical
; key with a modifier rather than re-sending the already-translated character —
; e.g. Space+a on a remapped layout produces ih.Input="-" but _SpaceHeldVK=30
; (VK for 'a'), and SendInput("{vk1e}") with Shift active yields "A" correctly.
global _SpaceHeldVK     := 0
; Guard against SC039 auto-repeat: set True from the moment SpaceTapHold starts
; until HoldFn returns, so repeated SC039 keydown events (OS key-repeat while
; Space is physically held) are silently dropped rather than launching a second
; SpaceTapHold invocation that would corrupt state and produce spurious output.
global _SpaceHoldActive := False

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
    global _SpaceInputHook, _SpaceIHActive, _SpaceTapSent, _SpaceHoldFired, _SpaceHeldInput, _SpaceHeldVK, _SpaceHoldActive
    ; SC039 auto-repeat while Space is physically held fires this hotkey again —
    ; drop silently to avoid a second SpaceTapHold invocation corrupting state.
    if (IsSet(_SpaceHoldActive) and _SpaceHoldActive)
        return
    _SpaceHoldActive := True
    _SpaceTapSent   := False
    _SpaceHoldFired := False
    _SpaceHeldInput := ""
    _SpaceHeldVK    := 0
    TimeoutSec := TapHoldDuration(TapHold, "space")
    ih := InputHook("L1 T" . TimeoutSec)
    ; Capture the physical VK alongside the translated character so HoldFn can
    ; replay the raw key with a modifier instead of re-sending ih.Input (which
    ; is already translated by the current layout and would double-translate).
    ih.OnKeyDown := _SpaceCaptureVK
    ih.Start()
    _SpaceInputHook := ih
    _SpaceIHActive  := True
    ih.Wait()
    _SpaceIHActive  := False
    _SpaceInputHook := 0
    ; "Stopped" = SC039 Up fired before any char or timeout → plain tap.
    ; "Timeout" = Space held past the threshold with no char → hold.
    ; "Max"     = a character arrived while Space was still held → hold:
    ;             the user wants the modifier + that character. Treating Max
    ;             as tap (the old behaviour) caused Space-hold+A to produce
    ;             "Space A" instead of Ctrl+A.
    if ih.EndReason == "Stopped" {
        _SpaceTapSent    := True
        _SpaceHoldActive := False
        TextPressKey("Space", "")
        ; TextPressKey uses SendInput which bypasses the prefix-watcher InputHook.
        ; Feed Space into HSE manually so end-char-gated hotstrings can fire,
        ; and reset the prefix watcher buffer (also bypassed by SendInput).
        global HSE_LastEndChar
        HSEMatch := HSE_FeedChar(" ")
        if (HSEMatch != "") {
            ; A hotstring fired on Space — dispatch handles the full send
            ; (backspaces + replacement + end-char re-emit).
            HSE_DispatchMatch(HSEMatch, HSE_LastEndChar)
            UpdateLastSentCharacter(" ")
            return False
        }
        ; No hotstring fired — still need to reset the prefix buffer so the
        ; next word starts fresh (SendInput bypasses the InputHook, so the
        ; watcher never sees this Space otherwise).
        if IsSet(_ResetPrefixBuffer)
            try _ResetPrefixBuffer()
        ; ih.Input holds any char that arrived in the capture window before
        ; SC039 Up stopped the hook — re-emit it so it is not silently dropped.
        if (ih.Input != "")
            TextSend(ih.Input, "", 0)
        UpdateLastSentCharacter(" ")
        return False
    }
    ; Timeout or Max → hold path. When EndReason is "Max" a character was
    ; captured while Space was held; pass it to HoldFn via _SpaceHeldInput
    ; so the hold action can inject it with the modifier active.
    ; Exception: if ih.Input is a Space (VK 32 auto-repeat of SC039 itself),
    ; treat it as a pure Timeout hold — _SpaceHeldVK was already zeroed by
    ; _SpaceCaptureVK so HoldFn will correctly skip the captured-char injection.
    _SpaceHoldFired  := True
    _SpaceHeldInput  := (ih.Input == " ") ? "" : ih.Input
    HoldFn()
    _SpaceHoldActive := False
    return True
}

; Each #HotIf block maps exactly one SC039 condition to one hold action.
; The SC039 Up companion signals a plain tap (press+release with no following
; character) by stopping the live InputHook when _SpaceIHActive is true —
; Stop() terminates ih.Wait() with EndReason "Stopped" (≠ "Timeout"), so
; SpaceTapHold takes the tap path and sends the Space itself. When the IH has
; already resolved (_SpaceIHActive false), the Up handler is a no-op because
; _SpaceTapSent or _SpaceHoldFired will be set.

_SpaceCaptureVK(ih, vk, sc) {
    global _SpaceHeldVK
    ; VK 32 is Space itself — auto-repeat of SC039 while held generates a Space
    ; keydown that the InputHook sees as a character. Ignore it so a pure hold
    ; (no other key typed) stays on the Timeout path rather than Max+Space.
    if (vk == 32)
        return
    _SpaceHeldVK := vk
}

_SpaceHoldCtrl() {
    global _SpaceHeldVK
    ; {LCtrl Down} physically holds Ctrl so any keys typed while Space is held
    ; arrive with Ctrl active. When EndReason was "Max" a key was already
    ; captured — replay its VK with Ctrl so Space+A → Ctrl+A regardless of layout.
    SendInput("{LCtrl Down}")
    if (_SpaceHeldVK != 0)
        SendInput("^{vk" . Format("{:x}", _SpaceHeldVK) . "}")
    KeyWait("SC039")
    SendInput("{LCtrl Up}")
}
_SpaceHoldLayer() {
    global _SpaceHeldInput
    ActivateLayer()
    ; Layer remaps keys via hotkeys, so the raw char from ih.Input is correct here —
    ; the layer mappings are not applied to ih.Input (IH runs before hotkeys).
    if (_SpaceHeldInput != "")
        SendInput("{Text}" . _SpaceHeldInput)
    KeyWait("SC039")
    DisableLayer()
}
_SpaceHoldShift() {
    global _SpaceHeldVK
    ; {LShift Down} physically holds Shift so any keys typed while Space is held
    ; arrive capitalised. When EndReason was "Max" a key was already captured —
    ; replay its physical VK with Shift so Space+A → A regardless of layout
    ; (avoids double-translation: ih.Input already reflects the remapped char).
    SendInput("{LShift Down}")
    if (_SpaceHeldVK != 0)
        SendInput("+{vk" . Format("{:x}", _SpaceHeldVK) . "}")
    KeyWait("SC039")
    SendInput("{LShift Up}")
}

#HotIf TapHoldHoldModifier(TapHold, "space") == "ctrl" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Ctrl on hold
SC039:: SpaceTapHold(_SpaceHoldCtrl)
SC039 Up:: {
    ; Only stop the InputHook when no character has been captured yet.
    ; If ih.Input != "" a char arrived while Space was held — Stop() here
    ; would flip EndReason to "Stopped" and lose the hold path entirely.
    ; Stop the IH when it is live and no real (non-Space) character has been
    ; captured yet. ih.Input == " " means only a Space auto-repeat was seen —
    ; treat that the same as empty so we still take the tap or pure-hold path.
    if (IsSet(_SpaceIHActive) and _SpaceIHActive
        and (_SpaceInputHook.Input == "" or _SpaceInputHook.Input == " ")) {
        _SpaceInputHook.Stop()
    }
}
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Layer on hold
SC039:: SpaceTapHold(_SpaceHoldLayer)
SC039 Up:: {
    ; Stop the IH when it is live and no real (non-Space) character has been
    ; captured yet. ih.Input == " " means only a Space auto-repeat was seen —
    ; treat that the same as empty so we still take the tap or pure-hold path.
    if (IsSet(_SpaceIHActive) and _SpaceIHActive
        and (_SpaceInputHook.Input == "" or _SpaceInputHook.Input == " ")) {
        _SpaceInputHook.Stop()
    }
}
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") == "shift" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Shift on hold
SC039:: SpaceTapHold(_SpaceHoldShift)
SC039 Up:: {
    ; Stop the IH when it is live and no real (non-Space) character has been
    ; captured yet. ih.Input == " " means only a Space auto-repeat was seen —
    ; treat that the same as empty so we still take the tap or pure-hold path.
    if (IsSet(_SpaceIHActive) and _SpaceIHActive
        and (_SpaceInputHook.Input == "" or _SpaceInputHook.Input == " ")) {
        _SpaceInputHook.Stop()
    }
}
#HotIf
