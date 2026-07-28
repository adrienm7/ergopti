; modules/tap_holds/delete.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Delete (Suppr)
; DESCRIPTION:
; Delete tap-hold: any action from GESTURE_ACTIONS on tap (default: delete),
; any hold modifier or nav layer on hold. Scancode SC053.
;
; Two-phase design (mirrors space.ahk) to prevent auto-repeat during long hold:
; Phase 1 — KeyWait with timeout discriminates tap from hold.
; Phase 2 (modifier) — arm modifier, capture next key, release on key-up.
; Phase 2 (layer) — activate layer until key-up.
;
; Note: this remaps the physical Delete/Suppr key (SC053). The LAlt and RCtrl
; modules emit Delete as an *output* action — that is unrelated to this module.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ==========================
; ======= 13/ DELETE =======
; ==========================
; ==============================

; Helper predicates -------------------------------------------------------

_DeleteHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "delete"), "delete")
}







; ======= 13.1) Hold-modifier variant =======

#HotIf TapHoldHoldModifier(TapHold, "delete") != "" and not LayerEnabled
*$SC053:: {
	tap := KeyWait("Delete", "T" . TapHoldDuration(TapHold, "delete"))
	if tap {
		if (A_PriorKey == "Delete")
			_DeleteDispatch()
		return
	}
	HoldGuardMs := TapHoldDuration(TapHold, "delete") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("delete", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "Delete hold suppressed after long press because wheel activity was detected.")
		return
	}
	ModKey := _DeleteHoldModKey()
	TapHoldSyntheticKeyDown(ModKey)
	try {
		KeyWait("Delete", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}
#HotIf







; ======= 13.2) Hold-layer variant =======

#HotIf TapHoldHoldLayer(TapHold, "delete") != "" and TapHoldHoldModifier(TapHold, "delete") == "" and not LayerEnabled
*$SC053:: {
	tap := KeyWait("Delete", "T" . TapHoldDuration(TapHold, "delete"))
	if tap {
		if (A_PriorKey == "Delete")
			_DeleteDispatch()
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
		while !KeyWait("Delete", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
			if !GetKeyState("Delete", "P")
				break
		}
	} finally {
		DisableLayer()
	}
}
#HotIf







; ======= 13.3) Tap-only (tap action set to something other than delete) =======

; $ prevents re-entry. Fire immediately on key-down — no KeyWait or A_PriorKey
; guard needed since there is no hold behaviour. No ~ needed: the action replaces
; the native key entirely; ~ would send both Delete and the action.
#HotIf TapHoldTapAction(TapHold, "delete") != "" and TapHoldTapAction(TapHold, "delete") != "delete" and TapHoldHoldModifier(TapHold, "delete") == "" and TapHoldHoldLayer(TapHold, "delete") == "" and not LayerEnabled
$SC053:: _DeleteDispatch()
#HotIf







; ======= 13.4) Tap dispatch =======

_DeleteDispatch() {
	local action := TapHoldTapAction(TapHold, "delete")
	; No tap configured or tap = delete itself → native key behaviour.
	if (action == "" or action == "delete") {
		TapHoldDispatchTap("delete", TextPressKey.Bind("Delete", []))
		return
	}
	_TapHoldFireAction("delete")
}
