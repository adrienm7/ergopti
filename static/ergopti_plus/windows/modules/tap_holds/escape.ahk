; modules/tap_holds/escape.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Escape
; DESCRIPTION:
; Escape tap-hold: any action from GESTURE_ACTIONS on tap (default: escape),
; any hold modifier or nav layer on hold. Scancode SC001.
;
; Two-phase design (mirrors space.ahk) to prevent auto-repeat during long hold:
; Phase 1 — KeyWait with timeout discriminates tap from hold.
; Phase 2 (modifier) — arm modifier, capture next key, release on key-up.
; Phase 2 (layer) — activate layer until key-up.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 11/ ESCAPE =======
; ==========================
; ==========================

; Helper predicates -------------------------------------------------------

_EscapeHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "escape"), "escape")
}







; ===========================================
; ===========================================
; ======= 11.1) Hold-modifier variant =======
; ===========================================
; ===========================================

#HotIf TapHoldHoldModifier(TapHold, "escape") != "" and not LayerEnabled
*$SC001:: {
	tap := KeyWait("Escape", "T" . TapHoldDuration(TapHold, "escape"))
	if tap {
		if (A_PriorKey == "Escape")
			_EscapeDispatch()
		return
	}
	HoldGuardMs := TapHoldDuration(TapHold, "escape") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("escape", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "Escape hold suppressed after long press because wheel activity was detected.")
		return
	}
	ModKey := _EscapeHoldModKey()
	TapHoldSyntheticKeyDown(ModKey)
	try {
		KeyWait("Escape", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}
#HotIf







; ========================================
; ========================================
; ======= 11.2) Hold-layer variant =======
; ========================================
; ========================================

#HotIf TapHoldHoldLayer(TapHold, "escape") != "" and TapHoldHoldModifier(TapHold, "escape") == "" and not LayerEnabled
*$SC001:: {
	tap := KeyWait("Escape", "T" . TapHoldDuration(TapHold, "escape"))
	if tap {
		if (A_PriorKey == "Escape")
			_EscapeDispatch()
		return
	}
	ActivateLayer()
	try {
		; The cap is a failsafe for waits that hold a SYNTHETIC modifier Down: those
		; must never latch it forever if the key-up event is lost. A hold LAYER holds no
		; synthetic key, so there is nothing to latch. Applied verbatim, the cap simply
		; dropped the layer out from under the user after five seconds of legitimate
		; navigation, and base-layer letters then landed in the document until it
		; re-armed. Re-arm the wait instead while the key is still physically down: every
		; iteration stays bounded, which is the property test_hold_layer_release_bounded
		; pins, and a timeout with the key already up means the key-up really was lost --
		; exactly the case the failsafe exists for.
		while !KeyWait("Escape", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
			if !GetKeyState("Escape", "P")
				break
		}
	} finally {
		DisableLayer()
	}
}
#HotIf







; ==============================================================================
; ==============================================================================
; ======= 11.3) Tap-only (tap action set to something other than escape) =======
; ==============================================================================
; ==============================================================================

; $ prevents re-entry. Fire immediately on key-down — no KeyWait or A_PriorKey
; guard needed since there is no hold behaviour. No ~ needed: the action replaces
; the native key entirely; ~ would send both Escape and the action.
#HotIf TapHoldTapAction(TapHold, "escape") != "" and TapHoldTapAction(TapHold, "escape") != "escape" and TapHoldHoldModifier(TapHold, "escape") == "" and TapHoldHoldLayer(TapHold, "escape") == "" and not LayerEnabled
$SC001:: _EscapeDispatch()
#HotIf







; ==================================
; ==================================
; ======= 11.4) Tap dispatch =======
; ==================================
; ==================================

_EscapeDispatch() {
	local action := TapHoldTapAction(TapHold, "escape")
	; No tap configured or tap = escape itself → native key behaviour.
	if (action == "" or action == "escape") {
		TapHoldDispatchTap("escape", TextPressKey.Bind("Escape", []))
		return
	}
	_TapHoldFireAction("escape")
}
