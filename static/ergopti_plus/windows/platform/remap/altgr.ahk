; platform/remap/altgr.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — AltGr
; DESCRIPTION:
; AltGr tap-hold: gated on not IsOnboardingActive() so the wizard's Edit
; fields receive native AltGr characters. AltGrTapHoldDispatchV2() maps the
; single configured tap_action to the corresponding key event.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================
; ========================
; ======= 6/ ALTGR =======
; ========================
; ========================

_AltGrHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "alt_gr"), "alt_gr")
}

; Every standalone AltGr hotkey below is declared by its scan code, SC138, and
; never by the modifier name RAlt. AutoHotkey hooks "RAlt::" on the same scan
; code as a separate hotkey, and when none of its variants is eligible it does
; not fall back to the SC138 hotkeys: on a Kana-style layout, where only the
; SC138 variants are eligible, nothing fired at all. With one identity, AHK
; picks the eligible variant, so the standard and Kana criteria below only need
; to be mutually exclusive.

#HotIf not _ALTGR_KANA_FIXUP and not LayerEnabled and not IsOnboardingActive() and TapHoldHoldModifier(TapHold, "alt_gr") != ""
SC01D & SC138:: ; AltGr on an AltGr layout arrives as LControl & RAlt
SC138:: { ; RAlt alone, e.g. on QWERTY
	Result := TapHoldOwnImmediateModifier("alt_gr", "SC138",
		_AltGrHoldModKey(), TapHoldDuration(TapHold, "alt_gr"))
	if (Result["tap"] and TapHoldPriorKeyIsSelf("alt_gr")) {
		DisableCapsWord()
		AltGrTapHoldDispatchV2()
	}
}
#HotIf

; On a Kana-style layout the AltGr key held as AltGr is its own modifier, like
; LShift held as Shift: the physical key passes through (~) and nothing is
; injected, so the layout's AltGr and the driver's AltGr-layer combinations keep
; working during the hold. The ~ also makes AHK fire this standalone on the
; press although SC138 prefixes those combinations, so the tap is timed from the
; real press. Any other hold keeps the suppressing variant and owns its modifier.
_AltGrKanaHandleHold(PhysicalModifierPassthrough) {
	Result := TapHoldOwnImmediateModifier("alt_gr", "SC138",
		_AltGrHoldModKey(), TapHoldDuration(TapHold, "alt_gr"),
		,,,,,, PhysicalModifierPassthrough)
	if (Result["tap"] and TapHoldPriorKeyIsSelf("alt_gr")) {
		DisableCapsWord()
		AltGrTapHoldDispatchV2()
	}
}

#HotIf _ALTGR_KANA_FIXUP and not LayerEnabled and not IsOnboardingActive() and _AltGrHoldModKey() == KS_AltGrKeyName()
~*$SC138:: _AltGrKanaHandleHold(true)
#HotIf _ALTGR_KANA_FIXUP and not LayerEnabled and not IsOnboardingActive() and TapHoldHoldModifier(TapHold, "alt_gr") != "" and _AltGrHoldModKey() != KS_AltGrKeyName()
*$SC138:: _AltGrKanaHandleHold(false)
#HotIf

; A standalone AltGr hotkey consumes every AltGr press while it is active,
; breaking native AltGr typing wherever the user expects the Windows layout to
; handle the key. It is therefore gated on ``not IsOnboardingActive()`` so the
; wizard's Edit fields (and anything else typed while the first-run wizard is
; up) receive AltGr characters from the OS instead of the tap-hold consuming them.
#HotIf not _ALTGR_KANA_FIXUP and not LayerEnabled and not IsOnboardingActive() and TapHoldIsActive(TapHold, "alt_gr") and TapHoldHoldModifier(TapHold, "alt_gr") == "" and TapHoldHoldLayer(TapHold, "alt_gr") == ""
; Tap-hold on "AltGr"
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
SC138:: ; RAlt alone, e.g. on QWERTY
{
		tap := KeyWait("SC138", "T" . TapHoldDuration(TapHold, "alt_gr"))
		if (tap and TapHoldPriorKeyIsSelf("alt_gr")) {
				DisableCapsWord()
				AltGrTapHoldDispatchV2()
		}
}

SC01D & ~SC138 Up::
SC138 Up:: {
		UpdateLastSentCharacter("")
}
#HotIf

; Kana-style layouts: the physical AltGr key is SC138 with no LControl, so the
; plain SC138 variant alone owns the tap there.
#HotIf _ALTGR_KANA_FIXUP and not LayerEnabled and not IsOnboardingActive() and TapHoldIsActive(TapHold, "alt_gr") and TapHoldHoldModifier(TapHold, "alt_gr") == "" and TapHoldHoldLayer(TapHold, "alt_gr") == ""
SC138:: {
		tap := KeyWait("SC138", "T" . TapHoldDuration(TapHold, "alt_gr"))
		if (tap and TapHoldPriorKeyIsSelf("alt_gr")) {
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
