; modules/tap_holds/altgr.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — AltGr
; DESCRIPTION:
; AltGr tap-hold: gated on not IsOnboardingActive() so the wizard's Edit
; fields receive native AltGr characters. AltGrTapHoldDispatchV2() maps the
; single configured tap_action to the corresponding key event.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ========================
; ======= 6/ ALTGR =======
; ========================
; ==============================

; The standalone ``RAlt::`` hotkey below consumes every AltGr/Kana press while
; it is active, breaking native AltGr typing in any context where the user
; expects their Windows layout to handle the key. We therefore gate it on
; ``not IsOnboardingActive()`` so the wizard's Edit fields (and anything else
; the user types while the first-run wizard is up) receive AltGr characters
; from the OS instead of the tap-hold consuming them.
#HotIf not LayerEnabled and not IsOnboardingActive() and TapHoldIsConfigured(TapHold, "alt_gr")
; Tap-hold on "AltGr"
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
RAlt:: ; Necessary to work on layouts like QWERTY
{
    ; On Kana/IME layouts the physical AltGr key is SC138. AHK can still
    ; surface a virtual RAlt event for it, so leave ownership to the explicit
    ; SC138 handler below instead of dispatching the same tap twice.
    if (_ALTGR_KANA_FIXUP && GetKeyState("SC138", "P"))
        return
    tap := KeyWait("RAlt", "T" . TapHoldDuration(TapHold, "alt_gr"))
    if (tap and (A_PriorKey == "RAlt" or A_PriorKey == "^")) {
        DisableCapsWord()
        AltGrTapHoldDispatchV2()
    }
}

SC01D & ~SC138 Up::
RAlt Up:: {
    UpdateLastSentCharacter("")
}
#HotIf

; Kana/IME physical AltGr is scan code 138, not the RAlt scan code used by
; the standard layout handlers. Register it as a standalone tap-hold key and
; keep it mutually exclusive with the virtual-RAlt path above.
#HotIf _ALTGR_KANA_FIXUP and not LayerEnabled and not IsOnboardingActive() and TapHoldIsConfigured(TapHold, "alt_gr")
SC138:: {
    tap := KeyWait("SC138", "T" . TapHoldDuration(TapHold, "alt_gr"))
    if (tap and A_PriorKey == "SC138") {
        DisableCapsWord()
        AltGrTapHoldDispatchV2()
    }
}

SC138 Up:: {
    UpdateLastSentCharacter("")
}
#HotIf

; Dispatch the configured tap action for "alt_gr".
; AltGr is already released when this fires (tap=true means key-up occurred),
; so no Blind prefix is needed — actions run clean without AltGr held.
AltGrTapHoldDispatchV2() {
    _TapHoldFireAction("alt_gr")
}
