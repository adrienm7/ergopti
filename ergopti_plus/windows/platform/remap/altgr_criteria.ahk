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

; Whether a resolved hold (a key name or a combination) holds the layout's AltGr.
; @param ModKey {String|Array} Resolved hold modifier.
; @return {Boolean}
_AltGrHoldHoldsAltGr(ModKey) {
	for _, Name in _TH_SyntheticKeyList(ModKey) {
		if (Name == KS_AltGrKeyName())
			return true
	}
	return false
}

; Whether the AltGr key keeps its native function under its tap-hold: it holds
; the layout's own AltGr, or nothing (a tap-only key). Such a press passes
; through, as LShift held as Shift does, and only its tap is the driver's; any
; other hold (a modifier, a combination, a layer) is owned by the driver.
; On a standard AltGr layout a combination that holds AltGr (Shift+AltGr,
; Ctrl+AltGr, Alt+AltGr, AltGr+Win) passes through as well, and its owner
; presses only the other members: suppressing that press made AutoHotkey send
; a blocked RAlt-up, Windows answered with the fake LCtrl-up, which cleared the
; SC01D prefix, and every "SC138 & X" combination (the AltGr layer, the rolls,
; the script chords) was dead for the whole hold (see altgr.ahk). QWERTY has no
; fake LCtrl and a Kana AltGr is no RAlt, so their suppressing owner keeps
; those combinations live and presses the whole combination.
; @return {Boolean}
AltGrHoldIsNative() {
	if (TapHoldHoldLayer(TapHold, "alt_gr") != "")
		return false
	if (TapHoldHoldModifier(TapHold, "alt_gr") == "")
		return true
	ModKey := _AltGrHoldModKey()
	if !(ModKey is Array)
		return ModKey == KS_AltGrKeyName()
	return KS_AltGrAddsFakeLCtrl() and _AltGrHoldHoldsAltGr(ModKey)
}

; Whether the AltGr key acts as the layout's AltGr: it has no live tap-hold, or
; its tap-hold holds AltGr (alone or in a combination) or nothing. Held as
; another modifier or a layer, the key is that modifier or layer: AltGr+C held
; as Ctrl must be Ctrl+C, not the AltGr layer's character, so the AltGr
; combinations (IsRealAltGrPress) stand down.
; @return {Boolean}
AltGrKeyIsAltGr() {
	if !TapHoldIsActive(TapHold, "alt_gr")
		return true
	if AltGrHoldIsNative()
		return true
	return _AltGrHoldHoldsAltGr(_AltGrHoldModKey())
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
