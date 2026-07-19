; modules/tap_holds/backspace.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Backspace
; DESCRIPTION:
; Backspace tap-hold: any action from GESTURE_ACTIONS on tap (default:
; backspace), any hold modifier or nav layer on hold. Scancode SC00E.
;
; Two-phase design (mirrors space.ahk) to prevent auto-repeat during long hold:
; Phase 1 — KeyWait with timeout discriminates tap from hold.
; Phase 2 (modifier) — arm modifier, capture next key, release on key-up.
; Phase 2 (layer) — activate layer until key-up.
;
; Note: the physical Backspace key is also used by CapsLock and LAlt modules
; as their tap output — those are output actions, not remappings of the
; physical Backspace key. This module remaps the physical Backspace key itself.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; =============================
; ======= 10/ BACKSPACE =======
; =============================
; ==============================

; Helper predicates -------------------------------------------------------

_BackspaceHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "backspace"), "backspace")
}







; ======= 10.1) Hold-modifier variant =======

#HotIf TapHoldHoldModifier(TapHold, "backspace") != "" and not LayerEnabled
*$SC00E:: {
	tap := KeyWait("BackSpace", "T" . TapHoldDuration(TapHold, "backspace"))
	if tap {
		if (A_PriorKey == "BackSpace")
			_BackspaceDispatch()
		return
	}
	HoldGuardMs := TapHoldDuration(TapHold, "backspace") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("backspace", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "Backspace hold suppressed after long press because wheel activity was detected.")
		return
	}
	ModKey := _BackspaceHoldModKey()
	TapHoldSyntheticKeyDown(ModKey)
	try {
		KeyWait("BackSpace", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}
#HotIf







; ======= 10.2) Hold-layer variant =======

#HotIf TapHoldHoldLayer(TapHold, "backspace") != "" and TapHoldHoldModifier(TapHold, "backspace") == "" and not LayerEnabled
*$SC00E:: {
	tap := KeyWait("BackSpace", "T" . TapHoldDuration(TapHold, "backspace"))
	if tap {
		if (A_PriorKey == "BackSpace")
			_BackspaceDispatch()
		return
	}
	ActivateLayer()
	try {
		KeyWait("BackSpace", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		DisableLayer()
	}
}
#HotIf







; ======= 10.3) Tap-only (tap action set to something other than backspace) =======

; $ prevents re-entry. Fire immediately on key-down — no KeyWait or A_PriorKey
; guard needed since there is no hold behaviour. No ~ needed: the action replaces
; the native key entirely; ~ would send both BackSpace and the action.
#HotIf TapHoldTapAction(TapHold, "backspace") != "" and TapHoldTapAction(TapHold, "backspace") != "backspace" and TapHoldHoldModifier(TapHold, "backspace") == "" and TapHoldHoldLayer(TapHold, "backspace") == "" and not LayerEnabled
$SC00E:: _BackspaceDispatch()
#HotIf







; ======= 10.4) Tap dispatch =======

_BackspaceDispatch() {
	local action := TapHoldTapAction(TapHold, "backspace")
	; No tap configured or tap = backspace itself → native key behaviour.
	if (action == "" or action == "backspace") {
		TapHoldDispatchTap("backspace", TextPressKey.Bind("BackSpace", []))
		return
	}
	_TapHoldFireAction("backspace")
}
