; platform/remap/altgr_criteria.ahk

; ==============================================================================
; MODULE: Tap-Holds — AltGr ownership criteria
; DESCRIPTION:
; The #HotIf criteria of the standalone AltGr hotkeys in altgr.ahk, as named
; functions. That file registers hotkeys when it loads, so the headless unit
; suite cannot include it; these criteria register nothing and are evaluated
; there for every layout family and configuration. One physical AltGr press
; must reach exactly one owner: on a standard AltGr layout it arrives as the
; layout's fake LCtrl then RAlt ("SC01D & SC138"), on QWERTY as RAlt alone and
; on a Kana-style layout as SC138 on another virtual key ("*SC138").
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ AltGr tap-hold owner criteria =====
; ==============================================
; ==============================================

; The alt_gr tap-hold's hold modifier, resolved: KS_AltGrKeyName() for
; "alt_gr", an Array for a combination, "" for none.
_AltGrHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "alt_gr"), "alt_gr")
}

; Whether the alt_gr tap-hold owns the AltGr key right now: configured and
; enabled, the navigation layer off (its Escape owns the key then), and the
; first-run wizard closed (its fields get the host layout's native AltGr).
_AltGrTapHoldIsLive() {
	return not LayerEnabled and not IsOnboardingActive() and TapHoldIsActive(TapHold, "alt_gr")
}

; Whether the AltGr key keeps its native function under its tap-hold: it holds
; the layout's own AltGr, or nothing (a tap-only key). Such a press passes
; through, as LShift held as Shift does, and only its tap is the driver's; any
; other hold (a modifier, a combination, a layer) is owned by the driver.
; @return {Boolean}
AltGrHoldIsNative() {
	if (TapHoldHoldLayer(TapHold, "alt_gr") != "")
		return false
	return TapHoldHoldModifier(TapHold, "alt_gr") == "" or _AltGrHoldModKey() == KS_AltGrKeyName()
}

; #HotIf of the pass-through AltGr owner on one layout family.
; @param Kana {Boolean} True for the Kana-style variants, false for the
;        standard AltGr and QWERTY ones.
; @return {Boolean}
AltGrOwnerPassesThrough(Kana) {
	return _ALTGR_KANA_FIXUP == Kana and _AltGrTapHoldIsLive() and AltGrHoldIsNative()
}

; #HotIf of the suppressing AltGr owner, which holds a modifier or a layer the
; driver presses, on one layout family.
; @param Kana {Boolean} As for AltGrOwnerPassesThrough.
; @return {Boolean}
AltGrOwnerHolds(Kana) {
	return _ALTGR_KANA_FIXUP == Kana and _AltGrTapHoldIsLive() and !AltGrHoldIsNative()
}
